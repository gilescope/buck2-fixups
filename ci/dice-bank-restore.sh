#!/usr/bin/env bash
# Restore the dice value store + graph skeleton from the dice bank.
#   ci/dice-bank-restore.sh <dice_sweep_dir>
# Produces <dice_sweep_dir>/{db/pagable.N.db, graph.meta}.
# Env: CAS_LINEAGE, DICE_SEED (must equal BUCK2_DICE_SNAPSHOT_SEED -
# banked rows are only valid within one fork-rev+seed), GH_TOKEN,
# GITHUB_REPOSITORY, BANK_WORK.
# Side effects in $BANK_WORK: dice-banked-keys.txt (for the publish
# diff), dice-head/ (manifest head dir). Exit 3 = no dice manifest for
# this lineage+seed (caller may fall back to the actions/cache dice
# snapshot for bootstrap).
set -euo pipefail
mkdir -p "$1"
DICE_DIR=$(cd "$1" && pwd)
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}" "${DICE_SEED:?}"
BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
mkdir -p "$BANK_WORK"

_sha8() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-8
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-8
  fi
}
SEED8=$(_sha8 "$DICE_SEED")
MANIFEST_NAME="cas-manifest-$CAS_LINEAGE-dice-$SEED8"

row=$(gh api \
  "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$MANIFEST_NAME&per_page=20" \
  --jq "[.artifacts[]
    | select(.expired == false
             and .workflow_run.head_repository_id == .workflow_run.repository_id
             and .workflow_run.head_branch == \"$CAS_LINEAGE\")][0]
    | .id // empty" 2>/dev/null || true)
if [ -z "$row" ]; then
  echo "[dice-bank] no $MANIFEST_NAME - cold dice bank"
  exit 3
fi
rm -rf "$BANK_WORK/dice-head" && mkdir -p "$BANK_WORK/dice-head"
gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$row/zip" \
  > "$BANK_WORK/.dm.zip"
unzip -o -q "$BANK_WORK/.dm.zip" -d "$BANK_WORK/dice-head" \
  && rm -f "$BANK_WORK/.dm.zip"
zstd -dq -c "$BANK_WORK/dice-head/blobs.txt.zst" \
  > "$BANK_WORK/dice-banked-keys.txt"
gen=$(jq -r .generation "$BANK_WORK/dice-head/manifest.json")
echo "[dice-bank] manifest $SEED8@$gen:" \
  "$(jq '.segments|length' "$BANK_WORK/dice-head/manifest.json") segments," \
  "$(wc -l < "$BANK_WORK/dice-banked-keys.txt" | tr -d ' ') rows"

zstd -dq -c "$BANK_WORK/dice-head/graph.meta.zst" > "$DICE_DIR/graph.meta"

containers=$(jq -r '[.segments[].artifact] | unique | .[]' \
  "$BANK_WORK/dice-head/manifest.json")
merged=0
for c in $containers; do
  aid=$(gh api \
    "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$c&per_page=1" \
    --jq '[.artifacts[] | select(.expired == false)][0].id // empty' \
    2>/dev/null || true)
  if [ -z "$aid" ]; then
    # Missing dice container = incomplete value store; hydration of a
    # missing DataKey is an engine error, not a cache miss. Degrade to
    # a cold dice load rather than a poisoned one.
    echo "[dice-bank] container $c missing - cold dice load"
    rm -rf "$DICE_DIR/db" "$DICE_DIR/graph.meta"
    exit 3
  fi
  rm -rf "$BANK_WORK/.dseg" && mkdir -p "$BANK_WORK/.dseg"
  gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$aid/zip" \
    > "$BANK_WORK/.dseg.zip"
  unzip -o -q "$BANK_WORK/.dseg.zip" -d "$BANK_WORK/.dseg" \
    && rm -f "$BANK_WORK/.dseg.zip"
  for d in "$BANK_WORK/.dseg"/cas-seg-*/; do
    [ -d "$d" ] || continue
    ci/cas-bank.sh dice_merge "$DICE_DIR/db" "$d"
    merged=$((merged + 1))
  done
  rm -rf "$BANK_WORK/.dseg"
done
echo "[dice-bank] merged $merged segments into $DICE_DIR/db"
