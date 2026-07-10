#!/usr/bin/env bash
# verify-cas.sh <store-dir>
# CAS blobs are self-certifying: the filename IS the sha256 of the
# content. Shard artifacts cross GitHub's branch-scoping wall (any run,
# any branch, including fork PRs, shares the artifact namespace), so
# every imported blob must prove itself - a planted file with a
# legitimate digest name and poisoned bytes is deleted, degrading the
# attack to a cold shard instead of code execution.
set -euo pipefail

store="${1:?store dir required}"
[ -d "$store/cas" ] || { echo "verify-cas: no cas/ - nothing to verify"; exit 0; }

if command -v sha256sum >/dev/null 2>&1; then
  HASHER=sha256sum
else
  HASHER="shasum -a 256" # macOS
fi

# Parallel batched hashing: per-file spawns cost ~100s/26k blobs, and a
# single sequential hasher took 31 MINUTES over 95k blobs on a windows
# runner (msys per-file open overhead) - which delayed that worker's
# mesh join past the legs' opening validation storm and made its whole
# shard range read as unservable. 8 hashers x 256-file batches.
ok=0 bad=0
# shellcheck disable=SC2086 # HASHER intentionally word-splits (shasum -a 256)
while IFS= read -r line; do
  hash=${line%% *}
  f=${line#* }; f=${f# } # hasher pads with two spaces
  if [ "$(basename "$f")" = "$hash" ]; then
    ok=$((ok + 1))
  else
    echo "verify-cas: DIGEST MISMATCH - deleting $(basename "$f")" >&2
    rm -f "$f"
    bad=$((bad + 1))
  fi
done < <(find "$store/cas" -type f -print0 | xargs -0 -r -P 8 -n 256 $HASHER)

echo "verify-cas: $ok verified, $bad rejected"
[ "$bad" -eq 0 ] || echo "verify-cas: WARNING - rejected blobs suggest a poisoned or corrupt shard artifact" >&2
