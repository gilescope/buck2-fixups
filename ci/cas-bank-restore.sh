#!/usr/bin/env bash
# Restore from the federated CAS bank (8 per-range manifests, one per
# shard, each published only by its range's primary owner).
#   ci/cas-bank-restore.sh <store_dir> <shard|->
# shard: this worker's shard number (owns hex prefixes 2n,2n+1); '-'
# fetches only the blob-list union (driver/co-worker: no seeding).
# Env: CAS_LINEAGE (required), CAS_PARENT_LINEAGE (optional: the trunk
# a branch/PR lineage inherits from - its bank seeds this store and
# joins the union, so a branch's first lap is warm and only its OWN new
# blobs are banked, under its OWN manifest), GH_TOKEN,
# GITHUB_REPOSITORY, ABSORB_SPILLS=1 (primaries only: also seed recent
# spill artifacts' own-range blobs so the next publish banks them
# properly).
# Side effects in $BANK_WORK (set it to a persistent NON-REPO dir in
# CI - stray files in the repo root churn buck2's file watcher):
#   bank-blobs.txt      union blob list of every manifest found
#   bank-manifest-rN.json  each range manifest found
#   own-range/          own manifest + blob list (publish's head dir)
# Exit 3 = no range manifests for this lineage (caller may fall back
# to the legacy monolithic shard artifacts for bootstrap).
set -euo pipefail
mkdir -p "$1"
STORE_DIR=$(cd "$1" && pwd); SHARD="$2"
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}"
BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
mkdir -p "$BANK_WORK"

# Newest unexpired artifact for an exact name, provenance-checked: the
# publishing run must have run on that lineage's own branch in this repo
# (blocks a hostile branch publishing under another lineage's name - see
# ci/cas-bank-design.md). $2 = the branch to demand, defaulting to this
# lineage; a parent lineage's manifests are checked against THEIR branch.
# Prints "id created_at" or nothing.
_artifact_row() {
  local want="${2:-$CAS_LINEAGE}"
  gh api \
    "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$1&per_page=20" \
    --jq "[.artifacts[]
      | select(.expired == false
               and .workflow_run.head_repository_id == .workflow_run.repository_id
               and .workflow_run.head_branch == \"$want\")][0]
      | select(. != null) | \"\(.id) \(.created_at)\"" 2>/dev/null || true
}

_fetch_zip() { # <artifact_id> <dest_dir>
  rm -rf "$2" && mkdir -p "$2"
  gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$1/zip" > "$2.zip"
  unzip -o -q "$2.zip" -d "$2" && rm -f "$2.zip"
}

# ── all range manifests: union blob list + own head ────────────────
found=0
: > "$BANK_WORK/.union"
own_created=""
rm -f "$BANK_WORK/.own-range-unknown"
for n in 0 1 2 3 4 5 6 7; do
  # For the OWN range, a lookup ERROR must not read as "absent": the
  # publish would stage a thin manifest and newest-wins would clobber
  # the fat one - monotonicity broken by a network flake. Flag it so
  # publish skips manifest staging (spill-only lap, self-heals).
  if [ "$SHARD" != "-" ] && [ "$n" = "$SHARD" ]; then
    if ! row=$(gh api \
      "repos/$GITHUB_REPOSITORY/actions/artifacts?name=cas-manifest-$CAS_LINEAGE-r$n&per_page=20" \
      --jq "[.artifacts[]
        | select(.expired == false
                 and .workflow_run.head_repository_id == .workflow_run.repository_id
                 and .workflow_run.head_branch == \"$CAS_LINEAGE\")][0]
        | select(. != null) | \"\(.id) \(.created_at)\"" 2>/dev/null); then
      echo "[bank] WARN own-range manifest lookup FAILED - publish will spill-only"
      touch "$BANK_WORK/.own-range-unknown"
      continue
    fi
  else
    row=$(_artifact_row "cas-manifest-$CAS_LINEAGE-r$n")
  fi
  [ -n "$row" ] || continue
  aid="${row%% *}"
  _fetch_zip "$aid" "$BANK_WORK/.m$n"
  cp "$BANK_WORK/.m$n/manifest.json" "$BANK_WORK/bank-manifest-r$n.json"
  zstd -dq -c "$BANK_WORK/.m$n/blobs.txt.zst" >> "$BANK_WORK/.union"
  found=$((found + 1))
  if [ "$SHARD" != "-" ] && [ "$n" = "$SHARD" ]; then
    own_created="${row#* }"
    rm -rf "$BANK_WORK/own-range" && mkdir -p "$BANK_WORK/own-range"
    cp "$BANK_WORK/.m$n/manifest.json" "$BANK_WORK/own-range/manifest.json"
    cp "$BANK_WORK/.m$n/blobs.txt.zst" "$BANK_WORK/own-range/blobs.txt.zst"
  fi
done

# ── parent lineage: inherit the trunk's bank, read-only ────────────
# Write isolation is absolute (see ci/cas-bank-design.md): the parent's
# blobs join the union so this lap never re-banks them, and its segments
# seed this store, but every publish still goes to the CHILD's manifest.
# On merge the trunk re-derives under its own trust.
parent_found=0
if [ -n "${CAS_PARENT_LINEAGE:-}" ] \
   && [ "$CAS_PARENT_LINEAGE" != "$CAS_LINEAGE" ]; then
  for n in 0 1 2 3 4 5 6 7; do
    prow=$(_artifact_row "cas-manifest-$CAS_PARENT_LINEAGE-r$n" \
      "$CAS_PARENT_LINEAGE")
    [ -n "$prow" ] || continue
    _fetch_zip "${prow%% *}" "$BANK_WORK/.p$n"
    cp "$BANK_WORK/.p$n/manifest.json" "$BANK_WORK/parent-manifest-r$n.json"
    zstd -dq -c "$BANK_WORK/.p$n/blobs.txt.zst" >> "$BANK_WORK/.union"
    parent_found=$((parent_found + 1))
  done
  [ "$parent_found" -eq 0 ] \
    || echo "[bank] parent lineage $CAS_PARENT_LINEAGE: $parent_found manifests inherited"
fi

if [ "$((found + parent_found))" -eq 0 ]; then
  echo "[bank] no range manifests for $CAS_LINEAGE - cold bank"
  exit 3
fi
sort -u "$BANK_WORK/.union" > "$BANK_WORK/bank-blobs.txt"
rm -f "$BANK_WORK/.union"
echo "[bank] $found own + $parent_found inherited manifests," \
  "union $(wc -l < "$BANK_WORK/bank-blobs.txt" | tr -d ' ') blobs"

[ "$SHARD" != "-" ] || exit 0
a=$(printf '%x' $((SHARD * 2))); b=$(printf '%x' $((SHARD * 2 + 1)))

# ── seed own range: containers named by the manifest ───────────────
_seed_from_manifest() { # <manifest.json> <owned_prefixes>
  local manifest="$1" owned="$2" needed containers c aid name
  needed=$(ci/cas-bank.sh segments_to_fetch "$manifest" "$owned")
  [ -n "$needed" ] || return 0
  # Single jq pass: a fork per needed segment re-parsed the manifest
  # 476 times at live fleet scale.
  containers=$(printf '%s\n' "$needed" \
    | jq -rR --slurpfile m "$manifest" \
        '. as $n | $m[0].segments[] | select(.name == $n) | .artifact' \
    | tr -d '\r' | sort -u)
  for c in $containers; do
    # Autotune input: wall seconds spent fetching DELTA containers.
    # Full-pack containers are the post-compaction steady state; the
    # delta overhead is the cost compaction can actually reclaim, and
    # publish compacts when it exceeds COMPACT_RESTORE_BUDGET.
    c_start=$(date +%s)
    c_is_full=$(jq -r --arg c "$c" \
      '[.segments[] | select(.artifact == $c) | .full == true] | all' \
      "$manifest")
    row=$(gh api \
      "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$c&per_page=1" \
      --jq '[.artifacts[] | select(.expired == false)][0]
        | select(. != null) | "\(.id) \(.created_at)"' \
      2>/dev/null || true)
    aid="${row%% *}"
    # Oldest referenced container feeds publish's rewarm check: a
    # container nearing the 90d retention cliff triggers a full
    # re-pack, which is the bank's only GC-defiance.
    created="${row#* }"
    if [ -n "$created" ] && { [ ! -f "$BANK_WORK/.oldest-container" ] \
         || [ "$created" \< "$(cat "$BANK_WORK/.oldest-container")" ]; }; then
      printf '%s' "$created" > "$BANK_WORK/.oldest-container"
    fi
    if [ -z "$aid" ]; then
      # Referenced-but-missing container: degrade to re-execution (the
      # affected actions miss the cache) rather than failing the lap.
      echo "[bank] WARN container $c missing - its blobs will re-derive"
      continue
    fi
    _fetch_zip "$aid" "$BANK_WORK/.seg"
    for name in $needed; do
      [ -d "$BANK_WORK/.seg/$name" ] || continue
      ci/cas-bank.sh seed_store "$STORE_DIR" "$BANK_WORK/.seg/$name"
      seeded=$((seeded + 1))
    done
    rm -rf "$BANK_WORK/.seg"
    if [ "$c_is_full" != "true" ]; then
      prev=$(cat "$BANK_WORK/.delta-restore-secs" 2>/dev/null || echo 0)
      echo $((prev + $(date +%s) - c_start)) \
        > "$BANK_WORK/.delta-restore-secs"
    fi
  done
}

seeded=0
mkdir -p "$STORE_DIR"
# The parent's range first (the branch's warm base), then this
# lineage's own segments on top. Content-addressed, so the order is
# only about doing the bulk fetch once.
if [ -f "$BANK_WORK/parent-manifest-r$SHARD.json" ]; then
  _seed_from_manifest "$BANK_WORK/parent-manifest-r$SHARD.json" "$a$b"
fi
# The own-range head names every segment this range holds.
if [ -f "$BANK_WORK/own-range/manifest.json" ]; then
  _seed_from_manifest "$BANK_WORK/own-range/manifest.json" "$a$b"
fi
echo "[bank] seeded $seeded segments for range $a$b"

# ── absorb recent spills (primary only) ────────────────────────────
# Out-of-range blobs other nodes produced land in cas-spill-* until
# their range owner seeds them; the owner's next publish then diffs
# them as new and banks them as proper range segments - absorption is
# a side effect of the ordinary pack, not extra machinery.
if [ "${ABSORB_SPILLS:-}" = "1" ]; then
  cutoff="${own_created:-1970-01-01T00:00:00Z}"
  spills=$(gh api \
    "repos/$GITHUB_REPOSITORY/actions/artifacts?per_page=100" \
    --jq "[.artifacts[]
      | select(.expired == false
               and (.name | startswith(\"cas-spill-$CAS_LINEAGE-\"))
               and .workflow_run.head_repository_id == .workflow_run.repository_id
               and .workflow_run.head_branch == \"$CAS_LINEAGE\"
               and .created_at > \"$cutoff\")
      | .id][:40] | .[]" 2>/dev/null || true)
  absorbed=0
  for aid in $spills; do
    _fetch_zip "$aid" "$BANK_WORK/.spill"
    # Only this worker's range moves into the store: seeding foreign
    # prefixes would make a spill-only node re-spill them (ping-pong).
    for d in "$BANK_WORK/.spill"/cas-seg-*/; do
      [ -f "$d/bulk.tar.zst" ] || continue
      rm -rf "$BANK_WORK/.spill-x" && mkdir -p "$BANK_WORK/.spill-x"
      zstd -dq -c "$d/bulk.tar.zst" | tar -x -C "$BANK_WORK/.spill-x"
      # Store dirs are TWO hex chars (cas/0f/); the range is the first.
      for p in "$a" "$b"; do
        for dd in "$BANK_WORK/.spill-x/cas/$p"*/; do
          [ -d "$dd" ] || continue
          base=$(basename "$dd")
          mkdir -p "$STORE_DIR/cas/$base"
          cp -R "$dd". "$STORE_DIR/cas/$base/"
          absorbed=$((absorbed + 1))
        done
      done
      rm -rf "$BANK_WORK/.spill-x"
    done
    rm -rf "$BANK_WORK/.spill"
  done
  echo "[bank] absorbed own-range dirs from $absorbed spill segments since $cutoff"
fi

# Heal segments/spills packed before the tool stamped 0755: a 0644
# store file hardlinked into an exec dir kills build scripts with
# EACCES. Runs LAST so spill-absorbed blobs are covered too; matches
# nothing once pre-fix segments compact away - remove then.
if [ -d "$STORE_DIR/cas" ]; then
  find "$STORE_DIR/cas" -type f ! -perm -100 -print0 2>/dev/null \
    | xargs -0 chmod a+x 2>/dev/null || true
fi
