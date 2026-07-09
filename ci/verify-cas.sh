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

# One hasher invocation per batch, not per file: 26k per-file process
# spawns cost ~100s/lap; batched xargs hashes the same store in seconds.
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
done < <(find "$store/cas" -type f -print0 | xargs -0 -r $HASHER)

echo "verify-cas: $ok verified, $bad rejected"
[ "$bad" -eq 0 ] || echo "verify-cas: WARNING - rejected blobs suggest a poisoned or corrupt shard artifact" >&2
