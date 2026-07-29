#!/usr/bin/env bash
# Stage this lap's dice delta for banking.
#   ci/dice-bank-publish.sh <dice_sweep_dir>
# Env: CAS_LINEAGE, DICE_SEED, GITHUB_RUN_ID, BANK_WORK.
# Produces (in $BANK_WORK):
#   dice-container/     delta row segments -> artifact
#                       "cas-dice-segs-<lineage>-<run>"
#   dice-manifest-out/  new manifest (head from restore) + the
#                       graph.meta of THIS page-out -> artifact
#                       "cas-manifest-<lineage>-dice-<seed8>". Upload
#                       container first, manifest gated on it - the
#                       same self-verification-by-step-order as the
#                       blob bank.
# GITHUB_OUTPUT: have=1 when there is anything to publish.
set -euo pipefail
DICE_DIR=$(cd "$1" && pwd)
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}" "${DICE_SEED:?}"
BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
mkdir -p "$BANK_WORK"
RUN="${GITHUB_RUN_ID:-local}"
CONTAINER="cas-dice-segs-$CAS_LINEAGE-$RUN"

_sha8() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-8
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-8
  fi
}
SEED8=$(_sha8 "$DICE_SEED")

if [ ! -d "$DICE_DIR/db" ] || [ ! -f "$DICE_DIR/graph.meta" ]; then
  echo "[dice-bank] no db/graph.meta under $DICE_DIR - nothing to publish"
  exit 0
fi

banked="$BANK_WORK/dice-banked-keys.txt"
[ -f "$banked" ] || banked=/dev/null

rm -rf "$BANK_WORK/dice-segs" "$BANK_WORK/dice-container" \
  "$BANK_WORK/dice-manifest-out"
ci/cas-bank.sh dice_pack "$DICE_DIR/db" "$banked" "$BANK_WORK/dice-segs" \
  > "$BANK_WORK/dice-segs.names" || true
if ! [ -s "$BANK_WORK/dice-segs.names" ]; then
  echo "[dice-bank] no new dice rows"
  rm -rf "$BANK_WORK/dice-segs"
  exit 0
fi

mkdir -p "$BANK_WORK/dice-container"
while IFS= read -r seg; do
  mkdir -p "$BANK_WORK/dice-container/$seg"
  mv "$BANK_WORK/dice-segs/$seg/rows.txt.zst" \
     "$BANK_WORK/dice-container/$seg/"
  jq -c --arg artifact "$CONTAINER" '. + {artifact: $artifact}' \
    "$BANK_WORK/dice-segs/$seg/meta.json" \
    > "$BANK_WORK/dice-segs/$seg/meta.json.tmp" \
    && mv "$BANK_WORK/dice-segs/$seg/meta.json.tmp" \
          "$BANK_WORK/dice-segs/$seg/meta.json"
done < "$BANK_WORK/dice-segs.names"

head_dir="-"
prev_gen="-"
if [ -f "$BANK_WORK/dice-head/manifest.json" ]; then
  head_dir="$BANK_WORK/dice-head"
  prev_gen=$(jq -r .generation "$head_dir/manifest.json" | tr -d '\r')
fi
ci/cas-bank.sh write_manifest "$CAS_LINEAGE" "$RUN-1" \
  "${CAS_PARENT_LINEAGE:--}" "$prev_gen" \
  "$RUN" "$head_dir" "$BANK_WORK/dice-segs" "$BANK_WORK/dice-manifest-out"
# The skeleton rides the manifest whole: 19MB raw, byte-stable, and it
# must be atomic with the row index it references.
zstd -q -8 -f "$DICE_DIR/graph.meta" \
  -o "$BANK_WORK/dice-manifest-out/graph.meta.zst"

echo "[dice-bank] $(wc -l < "$BANK_WORK/dice-segs.names" | tr -d ' ') segments," \
  "$(du -sh "$BANK_WORK/dice-container" | cut -f1) in $CONTAINER;" \
  "manifest dice-$SEED8 gen $RUN-1 staged"
rm -rf "$BANK_WORK/dice-segs" "$BANK_WORK/dice-segs.names"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "have=1" >> "$GITHUB_OUTPUT"
exit 0
