#!/usr/bin/env bash
# Stage this node's new/changed AC rows for the federated AC bank.
#   ci/ac-bank-publish.sh <store_dir> <role>
# Every node banks the rows it AUTHORED into its own role manifest -
# no ranges, no spill: an unbanked row is simply a cache miss next lap.
# Env: CAS_LINEAGE (required), GITHUB_RUN_ID, SEG_MAX_MB,
# AC_COMPACT_MIN_MB, AC_COMPACT_MAX_SEGMENTS, REWARM_DAYS, BANK_WORK.
# Produces (in $BANK_WORK):
#   ac-container/       new/changed row segments -> artifact
#                       "cas-ac-segs-<lineage>-<run>-<role>"
#   ac-manifest-out/    this role's NEW manifest -> artifact
#                       "cas-manifest-<lineage>-ac-<role>". Upload the
#                       container FIRST and gate this on it: the same
#                       self-verification-by-step-order as the blob
#                       bank - a manifest can never reference a
#                       container that did not land.
# GITHUB_OUTPUT: have=1 when there is anything to upload.
set -euo pipefail
mkdir -p "$1"
STORE_DIR=$(cd "$1" && pwd); ROLE="$2"
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}"
BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
mkdir -p "$BANK_WORK"
RUN="${GITHUB_RUN_ID:-local}"
# Numeric form for the segment's sort key: run ids are monotonic, so
# they ARE the generation clock the restore orders by. A non-numeric
# run (local testing) sorts first, which is harmless - it only ever
# competes with itself.
case "$RUN" in
  ''|*[!0-9]*) RUN_NUM=0 ;;
  *) RUN_NUM="$RUN" ;;
esac
CONTAINER="cas-ac-segs-$CAS_LINEAGE-$RUN-$ROLE"

rm -rf "$BANK_WORK/ac-segs" "$BANK_WORK/ac-container" \
  "$BANK_WORK/ac-manifest-out"

# A failed own-manifest lookup at restore leaves this role's banked
# state unknown; staging anything now risks newest-wins putting a thin
# manifest over the fat one. Skip the lap - rows re-bank next time.
if [ -f "$BANK_WORK/.ac-own-unknown" ]; then
  echo "[ac-bank] $ROLE: own manifest state unknown - not staging"
  exit 0
fi

# Never bank poison: --cache-failures rows are useful WITHIN a lap and
# fatal across laps. Purging here (not just at seed) keeps them out of
# the artifact pool entirely.
for d in "$STORE_DIR/ac" "$STORE_DIR/acn"; do
  [ -d "$d" ] && ci/cas-bank.sh _tool ac-purge-failures "$d"
done

banked="$BANK_WORK/ac-banked-rows.txt"
[ -f "$banked" ] || banked=/dev/null

# ── compaction: same owner-side machinery, AC-sized thresholds ──────
# The row set is bounded by the action graph (~22MB fleet-wide), so the
# blob bank's 256MB floor would never fire; everything else - the 20%
# rule, the measured restore-overhead autotune, the REWARM_DAYS
# retention defiance - applies unchanged.
compact_reason=""
if [ -f "$BANK_WORK/own-ac/manifest.json" ]; then
  verdict=$(COMPACT_MIN_MB="${AC_COMPACT_MIN_MB:-8}" \
    COMPACT_MAX_SEGMENTS="${AC_COMPACT_MAX_SEGMENTS:-32}" \
    ci/cas-bank.sh needs_compaction "$BANK_WORK/own-ac/manifest.json")
  case "$verdict" in yes*) compact_reason="$verdict" ;; esac
  if [ -z "$compact_reason" ] && [ -f "$BANK_WORK/.ac-oldest-container" ]; then
    now=$(date +%s)
    cutoff=$(date -u -d "@$((now - ${REWARM_DAYS:-60} * 86400))" \
        +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -r $((now - ${REWARM_DAYS:-60} * 86400)) \
        +%Y-%m-%dT%H:%M:%SZ)
    oldest=$(cat "$BANK_WORK/.ac-oldest-container")
    if [ "$oldest" \< "$cutoff" ]; then
      compact_reason="rewarm oldest-container=$oldest"
    fi
  fi
fi

diff_base="$banked"
if [ -n "$compact_reason" ]; then
  echo "[ac-bank] $ROLE: COMPACTING ($compact_reason)"
  diff_base=/dev/null
fi
ci/cas-bank.sh ac_pack "$STORE_DIR" "$diff_base" "$BANK_WORK/ac-segs" \
  > "$BANK_WORK/ac-segs.names" || true

# Monotonicity gate on the full path: a compaction that would SHED rows
# (a referenced container failed to restore) falls back to a delta, so
# newest-wins never loses history.
if [ -n "$compact_reason" ] && [ -s "$BANK_WORK/ac-segs.names" ] \
   && [ -f "$BANK_WORK/own-ac/blobs.txt.zst" ]; then
  old_n=$(zstd -dq -c "$BANK_WORK/own-ac/blobs.txt.zst" \
    | cut -d' ' -f1 | sort -u | wc -l | tr -d ' ')
  new_n=$(zstd -dq -c "$BANK_WORK/ac-segs"/cas-seg-*/blobs.txt.zst \
    | cut -d' ' -f1 | sort -u | wc -l | tr -d ' ')
  if [ "$new_n" -lt "$old_n" ]; then
    echo "[ac-bank] $ROLE: compact would shed rows ($old_n -> $new_n) - delta instead"
    compact_reason=""
    rm -rf "$BANK_WORK/ac-segs"
    ci/cas-bank.sh ac_pack "$STORE_DIR" "$banked" "$BANK_WORK/ac-segs" \
      > "$BANK_WORK/ac-segs.names" || true
  fi
fi

if ! [ -s "$BANK_WORK/ac-segs.names" ]; then
  echo "[ac-bank] $ROLE: no new or changed rows"
  rm -rf "$BANK_WORK/ac-segs" "$BANK_WORK/ac-segs.names"
  exit 0
fi

mkdir -p "$BANK_WORK/ac-container"
while IFS= read -r seg; do
  mkdir -p "$BANK_WORK/ac-container/$seg"
  mv "$BANK_WORK/ac-segs/$seg/bulk.tar.zst" \
     "$BANK_WORK/ac-container/$seg/"
  # run + role are the restore's sort key (generation order across
  # roles); artifact maps the segment to its container; full lets
  # needs_compaction quiesce.
  full=false
  [ -z "$compact_reason" ] || full=true
  jq -c --arg artifact "$CONTAINER" --arg role "$ROLE" \
    --argjson run "$RUN_NUM" --argjson full "$full" \
    '. + {artifact: $artifact, role: $role, run: $run}
     + (if $full then {full: true} else {} end)' \
    "$BANK_WORK/ac-segs/$seg/meta.json" \
    > "$BANK_WORK/ac-segs/$seg/meta.json.tmp" \
    && mv "$BANK_WORK/ac-segs/$seg/meta.json.tmp" \
          "$BANK_WORK/ac-segs/$seg/meta.json"
done < "$BANK_WORK/ac-segs.names"

head_dir="-"
prev_gen="-"
if [ -f "$BANK_WORK/own-ac/manifest.json" ]; then
  prev_gen=$(jq -r .generation "$BANK_WORK/own-ac/manifest.json" | tr -d '\r')
  # A compacting manifest references ONLY the fresh full packs.
  [ -n "$compact_reason" ] || head_dir="$BANK_WORK/own-ac"
fi
ci/cas-bank.sh write_manifest "$CAS_LINEAGE" "$RUN-1" \
  "${CAS_PARENT_LINEAGE:--}" "$prev_gen" \
  "$RUN" "$head_dir" "$BANK_WORK/ac-segs" "$BANK_WORK/ac-manifest-out"

# write_manifest unions the row lists line-wise; for the AC a mutated
# row leaves both (path, old-hash) and (path, new-hash) behind. Collapse
# to newest-per-path (this lap's lines last) so the list stays the size
# of the row set, not of its history.
zstd -dq -c "$BANK_WORK/ac-manifest-out/blobs.txt.zst" \
  > "$BANK_WORK/.ac-rowlist"
zstd -dq -c "$BANK_WORK/ac-segs"/cas-seg-*/blobs.txt.zst \
  >> "$BANK_WORK/.ac-rowlist"
awk '{ h[$1] = $2 } END { for (p in h) print p, h[p] }' \
  "$BANK_WORK/.ac-rowlist" | sort \
  | zstd -q -o "$BANK_WORK/ac-manifest-out/blobs.txt.zst" -f
rm -f "$BANK_WORK/.ac-rowlist"

echo "[ac-bank] $ROLE: $(wc -l < "$BANK_WORK/ac-segs.names" | tr -d ' ') segments," \
  "$(du -sh "$BANK_WORK/ac-container" | cut -f1) in $CONTAINER;" \
  "manifest gen $RUN-1 staged ($(jq '.segments|length' \
    "$BANK_WORK/ac-manifest-out/manifest.json") segments total)"
rm -rf "$BANK_WORK/ac-segs" "$BANK_WORK/ac-segs.names"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "have=1" >> "$GITHUB_OUTPUT"
exit 0
