#!/usr/bin/env bash
# Assemble and stage the lap's new bank manifest from worker reports.
#   ci/cas-bank-banker.sh <reports_dir>
# Env: CAS_LINEAGE, GITHUB_RUN_ID, GH_TOKEN, GITHUB_REPOSITORY.
# reports_dir: merged download of every cas-report-<run>-* artifact
# (subdirs cas-seg-*/ with meta.json + blobs.txt.zst; container.txt
# files may appear at any level - containers are read from metas).
# Stages bank-manifest-out/{manifest.json,blobs.txt.zst} for upload.
# The manifest only references segments whose container artifact
# VERIFIABLY exists - a worker that died mid-upload contributes
# nothing rather than a lie.
set -euo pipefail
REPORTS=$(cd "$1" && pwd)
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}"
BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
mkdir -p "$BANK_WORK"
RUN="${GITHUB_RUN_ID:-local}"

# Previous HEAD (provenance-checked, same rules as restore). A restore
# with an empty range fetches no segments but leaves bank-manifest.json
# + bank-blobs.txt when a manifest exists; exit 3 = cold bank.
head_dir="-"
rc=0
ci/cas-bank-restore.sh "$(mktemp -d)" "" || rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || exit "$rc"
if [ -f "$BANK_WORK/bank-manifest.json" ]; then
  mkdir -p "$BANK_WORK/.head"
  cp "$BANK_WORK/bank-manifest.json" "$BANK_WORK/.head"/manifest.json
  zstd -q -f "$BANK_WORK/bank-blobs.txt" -o "$BANK_WORK/.head"/blobs.txt.zst
  head_dir="$BANK_WORK/.head"
fi

# Verify each report's container exists as an artifact of THIS run,
# then admit its segments.
mkdir -p "$BANK_WORK/.verified"
admitted=0 dropped=0
for meta in "$REPORTS"/cas-seg-*/meta.json; do
  [ -f "$meta" ] || continue
  seg=$(basename "$(dirname "$meta")")
  container=$(jq -r .artifact "$meta")
  ok=$(gh api \
    "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$container&per_page=5" \
    --jq "[.artifacts[] | select(.workflow_run.id == $RUN)] | length" \
    2>/dev/null || echo 0)
  if [ "${ok:-0}" -ge 1 ]; then
    mkdir -p "$BANK_WORK/.verified/$seg"
    cp "$meta" "$(dirname "$meta")/blobs.txt.zst" "$BANK_WORK/.verified/$seg/"
    admitted=$((admitted + 1))
  else
    echo "[banker] DROP $seg - container $container not found this run"
    dropped=$((dropped + 1))
  fi
done
echo "[banker] segments admitted=$admitted dropped=$dropped"

if [ "$head_dir" = "-" ]; then
  prev_gen="-"
else
  prev_gen=$(jq -r .generation "$head_dir/manifest.json")
fi
ci/cas-bank.sh write_manifest "$CAS_LINEAGE" "$RUN-1" - "$prev_gen" \
  "$RUN" "$head_dir" "$BANK_WORK/.verified" "$BANK_WORK/bank-manifest-out"
echo "[banker] staged generation $RUN-1:" \
  "$(jq '.segments|length' "$BANK_WORK/bank-manifest-out/manifest.json") segments," \
  "$(zstd -dq -c "$BANK_WORK/bank-manifest-out/blobs.txt.zst" | wc -l | tr -d ' ') blobs"
