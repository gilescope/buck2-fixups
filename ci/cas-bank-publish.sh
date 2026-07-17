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
# Compaction rides the owner's own teardown (there is no separate
# workflow): the store already holds the range's full compacted view -
# seeded segments + absorbed spills + this lap's new blobs - so a full
# re-pack is just "diff against nothing". Triggers: the 20% rule via
# needs_compaction, or any referenced container older than REWARM_DAYS
# (fresh uploads reset the 90d retention clock - the bank's only GC).
if [ -n "$owned" ]; then
  compact_reason=""
  if [ -f "$BANK_WORK/own-range/manifest.json" ]; then
    verdict=$(ci/cas-bank.sh needs_compaction \
      "$BANK_WORK/own-range/manifest.json")
    case "$verdict" in yes*) compact_reason="$verdict" ;; esac
    if [ -z "$compact_reason" ] && [ -f "$BANK_WORK/.oldest-container" ]; then
      now=$(date +%s)
      cutoff=$(date -u -d "@$((now - ${REWARM_DAYS:-60} * 86400))" \
          +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r $((now - ${REWARM_DAYS:-60} * 86400)) \
          +%Y-%m-%dT%H:%M:%SZ)
      oldest=$(cat "$BANK_WORK/.oldest-container")
      if [ "$oldest" \< "$cutoff" ]; then
        compact_reason="rewarm oldest-container=$oldest"
      fi
    fi
  fi
  diff_base="$bank_list"
  if [ -n "$compact_reason" ]; then
    echo "[bank] $ROLE r$SHARD: COMPACTING ($compact_reason)"
    diff_base=/dev/null
  fi
  ci/cas-bank.sh pack_segments "$STORE_DIR" "$diff_base" \
    "$BANK_WORK/bank-segs" "$owned" > "$BANK_WORK/bank-segs.names" || true
  # Monotonicity gate on the full path: the store should cover the old
  # manifest's blob list (missing containers degrade to re-derive). If
  # it shrank, DON'T compact this lap - fall back to a delta so
  # newest-wins never sheds history.
  if [ -n "$compact_reason" ] && [ -s "$BANK_WORK/bank-segs.names" ] \
     && [ -f "$BANK_WORK/own-range/blobs.txt.zst" ]; then
    old_n=$(zstd -dq -c "$BANK_WORK/own-range/blobs.txt.zst" | wc -l | tr -d ' ')
    new_n=$(zstd -dq -c "$BANK_WORK/bank-segs"/cas-seg-*/blobs.txt.zst \
      | sort -u | wc -l | tr -d ' ')
    if [ "$new_n" -lt "$old_n" ]; then
      echo "[bank] $ROLE r$SHARD: compact would shed blobs ($old_n -> $new_n) - delta instead"
      compact_reason=""
      rm -rf "$BANK_WORK/bank-segs"
      ci/cas-bank.sh pack_segments "$STORE_DIR" "$bank_list" \
        "$BANK_WORK/bank-segs" "$owned" > "$BANK_WORK/bank-segs.names" || true
    fi
  fi
  if [ -s "$BANK_WORK/bank-segs.names" ]; then
    mkdir -p "$BANK_WORK/bank-container"
    while IFS= read -r seg; do
      mkdir -p "$BANK_WORK/bank-container/$seg"
      mv "$BANK_WORK/bank-segs/$seg/bulk.tar.zst" \
         "$BANK_WORK/bank-container/$seg/"
      # Tag the meta with its container for restore's fetch mapping;
      # full packs are stamped so needs_compaction can quiesce.
      if [ -n "$compact_reason" ]; then
        jq -c --arg artifact "$CONTAINER" \
          '. + {artifact: $artifact, full: true}' \
          "$BANK_WORK/bank-segs/$seg/meta.json" \
          > "$BANK_WORK/bank-segs/$seg/meta.json.tmp"
      else
        jq -c --arg artifact "$CONTAINER" '. + {artifact: $artifact}' \
          "$BANK_WORK/bank-segs/$seg/meta.json" \
          > "$BANK_WORK/bank-segs/$seg/meta.json.tmp"
      fi
      mv "$BANK_WORK/bank-segs/$seg/meta.json.tmp" \
         "$BANK_WORK/bank-segs/$seg/meta.json"
    done < "$BANK_WORK/bank-segs.names"
    head_dir="-"
    prev_gen="-"
    if [ -f "$BANK_WORK/own-range/manifest.json" ]; then
      prev_gen=$(jq -r .generation "$BANK_WORK/own-range/manifest.json" | tr -d '\r')
      # A compacting manifest references ONLY the fresh full packs;
      # a delta chains on the head as before.
      [ -n "$compact_reason" ] || head_dir="$BANK_WORK/own-range"
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
