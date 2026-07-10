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

# Prefer the engine's native verifier: portable, fast (a shell hasher
# took 31min/95k blobs on windows) and immune to the parallel-pipe
# interleave that made concurrent shell hashers delete good files.
if command -v rebuck2 >/dev/null 2>&1; then
  exec rebuck2 verify-store --store "$store"
fi

if command -v sha256sum >/dev/null 2>&1; then
  HASHER=sha256sum
else
  HASHER="shasum -a 256" # macOS
fi

# Fallback path (no engine on PATH): sequential batched hashing. NEVER
# parallelize hashers onto one pipe - concurrent writers interleave
# beyond PIPE_BUF and the parser deleted GOOD files as mismatches
# (run 29082052036 killed a whole mac fleet that way).
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
done < <(find "$store/cas" -type f -print0 | xargs -0 -r -n 256 $HASHER)

echo "verify-cas: $ok verified, $bad rejected"
[ "$bad" -eq 0 ] || echo "verify-cas: WARNING - rejected blobs suggest a poisoned or corrupt shard artifact" >&2
