#!/usr/bin/env bash
# Prepare this node's new blobs for the federated bank.
#   ci/cas-bank-publish.sh <store_dir> <role> <shard|->
# shard: the range this node is PRIMARY for (owns hex prefixes
# 2n,2n+1); '-' = spill-only (secondaries, driver, co-worker).
# Env: CAS_LINEAGE (required), GITHUB_RUN_ID, SEG_MAX_MB.
# Produces (in $BANK_WORK):
#   bank-container/     own-range segments -> artifact
#                       "cas-segs-<lineage>-<run>-<role>"
#   bank-manifest-out/  the range's NEW manifest (head from restore's
#                       own-range/ + these segments) -> artifact
#                       "cas-manifest-<lineage>-r<shard>". The caller
#                       uploads the container FIRST and gates this on
#                       that step succeeding: self-verification by
#                       step order - no banker, no reports.
#   bank-spill/         out-of-range new segments -> artifact
#                       "cas-spill-<lineage>-<run>-<role>", absorbed
#                       by range owners on later restores.
# GITHUB_OUTPUT: have=1 (container), manifest=1, spill=1.
# Diffs against bank-blobs.txt if the restore step produced one.
set -euo pipefail
mkdir -p "$1"
STORE_DIR=$(cd "$1" && pwd); ROLE="$2"; SHARD="$3"
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}"
BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
mkdir -p "$BANK_WORK"
RUN="${GITHUB_RUN_ID:-local}"
CONTAINER="cas-segs-$CAS_LINEAGE-$RUN-$ROLE"

bank_list="$BANK_WORK/bank-blobs.txt"
[ -f "$bank_list" ] || bank_list=/dev/null

rm -rf "$BANK_WORK/bank-segs" "$BANK_WORK/bank-container" \
  "$BANK_WORK/bank-manifest-out" "$BANK_WORK/bank-spill" \
  "$BANK_WORK/bank-spill-segs"

owned='' spillset='0123456789abcdef'
if [ "$SHARD" != "-" ]; then
  a=$(printf '%x' $((SHARD * 2))); b=$(printf '%x' $((SHARD * 2 + 1)))
  owned="$a$b"
  spillset=$(echo "$spillset" | tr -d "$owned")
fi

# A failed own-manifest lookup at restore must not let this lap stage
# a thin manifest that newest-wins would put over the fat one: demote
# to spill-only (the range owner re-banks from spill next lap).
if [ -f "$BANK_WORK/.own-range-unknown" ] && [ "$SHARD" != "-" ]; then
  echo "[bank] $ROLE r$SHARD: own manifest state unknown - spill-only lap"
  SHARD="-"
  owned=""
  spillset='0123456789abcdef'
fi

# ── own range: segments + staged manifest ───────────────────────────
if [ -n "$owned" ]; then
  ci/cas-bank.sh pack_segments "$STORE_DIR" "$bank_list" \
    "$BANK_WORK/bank-segs" "$owned" > "$BANK_WORK/bank-segs.names" || true
  if [ -s "$BANK_WORK/bank-segs.names" ]; then
    mkdir -p "$BANK_WORK/bank-container"
    while IFS= read -r seg; do
      mkdir -p "$BANK_WORK/bank-container/$seg"
      mv "$BANK_WORK/bank-segs/$seg/bulk.tar.zst" \
         "$BANK_WORK/bank-container/$seg/"
      # Tag the meta with its container for restore's fetch mapping.
      jq -c --arg artifact "$CONTAINER" '. + {artifact: $artifact}' \
        "$BANK_WORK/bank-segs/$seg/meta.json" \
        > "$BANK_WORK/bank-segs/$seg/meta.json.tmp" \
        && mv "$BANK_WORK/bank-segs/$seg/meta.json.tmp" \
              "$BANK_WORK/bank-segs/$seg/meta.json"
    done < "$BANK_WORK/bank-segs.names"
    head_dir="-"
    prev_gen="-"
    if [ -f "$BANK_WORK/own-range/manifest.json" ]; then
      head_dir="$BANK_WORK/own-range"
      prev_gen=$(jq -r .generation "$head_dir/manifest.json" | tr -d '\r')
    fi
    ci/cas-bank.sh write_manifest "$CAS_LINEAGE" "$RUN-1" - "$prev_gen" \
      "$RUN" "$head_dir" "$BANK_WORK/bank-segs" "$BANK_WORK/bank-manifest-out"
    echo "[bank] $ROLE r$SHARD: $(wc -l < "$BANK_WORK/bank-segs.names" | tr -d ' ') segments," \
      "$(du -sh "$BANK_WORK/bank-container" | cut -f1) in $CONTAINER;" \
      "manifest gen $RUN-1 staged ($(jq '.segments|length' \
        "$BANK_WORK/bank-manifest-out/manifest.json") segments total)"
    [ -n "${GITHUB_OUTPUT:-}" ] && { echo "have=1"; echo "manifest=1"; } \
      >> "$GITHUB_OUTPUT"
  else
    echo "[bank] $ROLE r$SHARD: nothing new in range $owned"
  fi
  rm -rf "$BANK_WORK/bank-segs"
fi

# ── everything else: spill for range owners to absorb ───────────────
ci/cas-bank.sh pack_segments "$STORE_DIR" "$bank_list" \
  "$BANK_WORK/bank-spill-segs" "$spillset" \
  > "$BANK_WORK/bank-spill.names" || true
if [ -s "$BANK_WORK/bank-spill.names" ]; then
  mkdir -p "$BANK_WORK/bank-spill"
  while IFS= read -r seg; do
    mv "$BANK_WORK/bank-spill-segs/$seg" "$BANK_WORK/bank-spill/$seg"
  done < "$BANK_WORK/bank-spill.names"
  echo "[bank] $ROLE: $(wc -l < "$BANK_WORK/bank-spill.names" | tr -d ' ') spill segments," \
    "$(du -sh "$BANK_WORK/bank-spill" | cut -f1) (out-of-range, owners absorb)"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "spill=1" >> "$GITHUB_OUTPUT"
else
  echo "[bank] $ROLE: nothing to spill"
fi
rm -rf "$BANK_WORK/bank-spill-segs" "$BANK_WORK/bank-segs.names" \
  "$BANK_WORK/bank-spill.names"
exit 0
