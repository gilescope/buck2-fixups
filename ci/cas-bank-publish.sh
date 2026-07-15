#!/usr/bin/env bash
# Prepare this node's new blobs for banking.
#   ci/cas-bank-publish.sh <store_dir> <role>
# Env: CAS_LINEAGE (required), GITHUB_RUN_ID, SEG_MAX_MB.
# Produces (in $BANK_WORK):
#   "$BANK_WORK/bank-container"/   bulk tars, one subdir per segment  -> uploaded as
#                     artifact "cas-segs-<lineage>-<run>-<role>"
#   "$BANK_WORK/bank-report"/      per-segment meta.json (artifact-tagged) +
#                     blobs.txt.zst + container.txt      -> uploaded as
#                     artifact "cas-report-<run>-<role>"
# Outputs "have=1" to $GITHUB_OUTPUT when there is anything to publish.
# Diffs against bank-blobs.txt if the restore step produced one.
set -euo pipefail
mkdir -p "$1"
STORE_DIR=$(cd "$1" && pwd); ROLE="$2"
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}"
BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
mkdir -p "$BANK_WORK"
CONTAINER="cas-segs-$CAS_LINEAGE-${GITHUB_RUN_ID:-local}-$ROLE"

bank_list="$BANK_WORK/bank-blobs.txt"
[ -f "$bank_list" ] || bank_list=/dev/null

rm -rf "$BANK_WORK/bank-segs" "$BANK_WORK/bank-container" "$BANK_WORK/bank-report"
ci/cas-bank.sh pack_segments "$STORE_DIR" "$bank_list" "$BANK_WORK/bank-segs" \
  > "$BANK_WORK/bank-segs.names" || true
if ! [ -s "$BANK_WORK/bank-segs.names" ]; then
  echo "[bank] nothing new to publish for $ROLE"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "have=0" >> "$GITHUB_OUTPUT"
  exit 0
fi

mkdir -p "$BANK_WORK/bank-container" "$BANK_WORK/bank-report"
while IFS= read -r seg; do
  mkdir -p "$BANK_WORK/bank-container/$seg" "$BANK_WORK/bank-report/$seg"
  mv "$BANK_WORK/bank-segs/$seg/bulk.tar.zst" \
     "$BANK_WORK/bank-container/$seg/"
  jq -c --arg artifact "$CONTAINER" '. + {artifact: $artifact}' \
    "$BANK_WORK/bank-segs/$seg/meta.json" \
    > "$BANK_WORK/bank-report/$seg/meta.json"
  mv "$BANK_WORK/bank-segs/$seg/blobs.txt.zst" "$BANK_WORK/bank-report/$seg/"
done < "$BANK_WORK/bank-segs.names"
echo "$CONTAINER" > "$BANK_WORK/bank-report"/container.txt
rm -rf "$BANK_WORK/bank-segs"

echo "[bank] $ROLE: $(wc -l < "$BANK_WORK/bank-segs.names" | tr -d ' ') segments," \
  "$(du -sh "$BANK_WORK/bank-container" | cut -f1) in container $CONTAINER"
rm -f "$BANK_WORK/bank-segs.names"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "have=1" >> "$GITHUB_OUTPUT"
exit 0
