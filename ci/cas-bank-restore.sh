#!/usr/bin/env bash
# Restore a subset of the CAS bank into a store dir.
#   ci/cas-bank-restore.sh <store_dir> <owned_prefixes|*>
# Env: CAS_LINEAGE (required), GH_TOKEN, GITHUB_REPOSITORY.
# Side effects in $BANK_WORK (default: a fresh temp dir; set it to a
# persistent NON-REPO dir in CI - stray files in the repo root churn
# buck2's file watcher): "$BANK_WORK/bank-blobs.txt" (the bank's full blob list,
# for the pack step's diff) and "$BANK_WORK/bank-manifest.json".
# Exit 3 = no bank manifest for this lineage (caller may fall back
# to the legacy monolithic shard artifacts for bootstrap).
set -euo pipefail
mkdir -p "$1"
STORE_DIR=$(cd "$1" && pwd); OWNED="$2"
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}"
BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
mkdir -p "$BANK_WORK"

# Newest unexpired manifest for this lineage, provenance-checked: the
# publishing run must have run on the lineage's own branch in this
# repo (blocks a hostile branch publishing under another lineage's
# manifest name - see ci/cas-bank-design.md).
row=$(gh api \
  "repos/$GITHUB_REPOSITORY/actions/artifacts?name=cas-manifest-$CAS_LINEAGE&per_page=20" \
  --jq "[.artifacts[]
    | select(.expired == false
             and .workflow_run.head_repository_id == .workflow_run.repository_id
             and .workflow_run.head_branch == \"$CAS_LINEAGE\")][0]
    | .id // empty" 2>/dev/null || true)
if [ -z "$row" ] || [ "$row" = "null" ]; then
  echo "[bank] no cas-manifest-$CAS_LINEAGE artifact - cold bank"
  exit 3
fi
rm -rf "$BANK_WORK/.m" && mkdir -p "$BANK_WORK/.m"
gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$row/zip" > "$BANK_WORK/.m.zip"
unzip -o -q "$BANK_WORK/.m.zip" -d "$BANK_WORK/.m" && rm -f "$BANK_WORK/.m.zip"
cp "$BANK_WORK/.m"/manifest.json "$BANK_WORK/bank-manifest.json"
zstd -dq -c "$BANK_WORK/.m"/blobs.txt.zst > "$BANK_WORK/bank-blobs.txt"
gen=$(jq -r .generation "$BANK_WORK/bank-manifest.json")
echo "[bank] manifest $CAS_LINEAGE@$gen: $(jq '.segments|length' \
  "$BANK_WORK/bank-manifest.json") segments, $(wc -l < "$BANK_WORK/bank-blobs.txt" | tr -d ' ') blobs"

# The matching game: segments whose prefix bitmap overlaps our range,
# grouped by the container artifact that holds them.
needed=$(ci/cas-bank.sh segments_to_fetch "$BANK_WORK/bank-manifest.json" "$OWNED")
if [ -z "$needed" ]; then
  echo "[bank] no segments overlap range '$OWNED'"
  mkdir -p "$STORE_DIR"
  exit 0
fi
# Single jq pass: a fork per needed segment re-parsed the manifest
# 476 times at live fleet scale (same O(n*forks) class as the pack
# loop).
containers=$(printf '%s\n' "$needed" \
  | jq -rR --slurpfile m "$BANK_WORK/bank-manifest.json" \
      '. as $n | $m[0].segments[] | select(.name == $n) | .artifact' \
  | sort -u)

mkdir -p "$STORE_DIR"
fetched=0
for c in $containers; do
  aid=$(gh api \
    "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$c&per_page=1" \
    --jq '[.artifacts[] | select(.expired == false)][0].id // empty' \
    2>/dev/null || true)
  if [ -z "$aid" ]; then
    # Referenced-but-missing container: degrade to re-execution (the
    # affected actions miss the cache) rather than failing the lap.
    echo "[bank] WARN container $c missing - its blobs will re-derive"
    continue
  fi
  rm -rf "$BANK_WORK/.seg" && mkdir -p "$BANK_WORK/.seg"
  gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$aid/zip" \
    > "$BANK_WORK/.seg.zip"
  unzip -o -q "$BANK_WORK/.seg.zip" -d "$BANK_WORK/.seg" && rm -f "$BANK_WORK/.seg.zip"
  for name in $needed; do
    [ -d "$BANK_WORK/.seg/$name" ] || continue
    ci/cas-bank.sh seed_store "$STORE_DIR" "$BANK_WORK/.seg/$name"
    fetched=$((fetched + 1))
  done
  rm -rf "$BANK_WORK/.seg"
done
echo "[bank] seeded $fetched segments into $STORE_DIR"
