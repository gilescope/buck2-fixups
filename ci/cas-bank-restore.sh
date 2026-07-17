#!/usr/bin/env bash
# Restore from the federated CAS bank (8 per-range manifests, one per
# shard, each published only by its range's primary owner).
#   ci/cas-bank-restore.sh <store_dir> <shard|->
# shard: this worker's shard number (owns hex prefixes 2n,2n+1); '-'
# fetches only the blob-list union (driver/co-worker: no seeding).
# Env: CAS_LINEAGE (required), GH_TOKEN, GITHUB_REPOSITORY,
# ABSORB_SPILLS=1 (primaries only: also seed recent spill artifacts'
# own-range blobs so the next publish banks them properly).
# Side effects in $BANK_WORK (set it to a persistent NON-REPO dir in
# CI - stray files in the repo root churn buck2's file watcher):
#   bank-blobs.txt      union blob list of every manifest found
#   bank-manifest-rN.json  each range manifest found
#   own-range/          own manifest + blob list (publish's head dir)
# Exit 3 = no manifests of any kind for this lineage (caller may fall
# back to the legacy monolithic shard artifacts for bootstrap).
set -euo pipefail
mkdir -p "$1"
STORE_DIR=$(cd "$1" && pwd); SHARD="$2"
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}"
BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
mkdir -p "$BANK_WORK"

# Newest unexpired artifact for an exact name, provenance-checked:
# the publishing run must have run on the lineage's own branch in this
# repo (blocks a hostile branch publishing under another lineage's
# name - see ci/cas-bank-design.md). Prints "id created_at" or nothing.
_artifact_row() {
  gh api \
    "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$1&per_page=20" \
    --jq "[.artifacts[]
      | select(.expired == false
               and .workflow_run.head_repository_id == .workflow_run.repository_id
               and .workflow_run.head_branch == \"$CAS_LINEAGE\")][0]
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

# Transitional: the pre-federation GLOBAL manifest is a read-only
# parent - its blob list keeps the union complete while ranges are
# still being established, and it seeds ranges that have no manifest
# yet. Remove once all 8 ranges are live.
global_manifest=""
grow=$(_artifact_row "cas-manifest-$CAS_LINEAGE")
if [ -n "$grow" ]; then
  _fetch_zip "${grow%% *}" "$BANK_WORK/.g"
  global_manifest="$BANK_WORK/.g/manifest.json"
  zstd -dq -c "$BANK_WORK/.g/blobs.txt.zst" >> "$BANK_WORK/.union"
  found=$((found + 1))
fi

if [ "$found" -eq 0 ]; then
  echo "[bank] no range or global manifests for $CAS_LINEAGE - cold bank"
  exit 3
fi
sort -u "$BANK_WORK/.union" > "$BANK_WORK/bank-blobs.txt"
rm -f "$BANK_WORK/.union"
echo "[bank] $found manifests, union $(wc -l < "$BANK_WORK/bank-blobs.txt" | tr -d ' ') blobs"

[ "$SHARD" != "-" ] || exit 0
a=$(printf '%x' $((SHARD * 2))); b=$(printf '%x' $((SHARD * 2 + 1)))

# The own-range head MERGES the global manifest's slice in - always,
# not just on first publish. A thin range manifest (published after a
# flaky restore, or before the global existed) would otherwise pin the
# range's pre-migration blobs union-visible (never re-banked) but
# manifest-invisible (never seeded): cold stores forever. The merge is
# idempotent and monotonic; once the global expires it contributes
# nothing and the fallback can go.
if [ -n "$global_manifest" ] && [ ! -f "$BANK_WORK/.own-range-unknown" ]; then
  mkdir -p "$BANK_WORK/own-range"
  own_json="$BANK_WORK/own-range/manifest.json"
  # Base is the own manifest when it exists (its generation chains);
  # otherwise the global with its segments cleared (pure inheritance).
  [ -f "$own_json" ] \
    || jq '. + {segments: []}' "$global_manifest" > "$own_json"
  jq --arg p "[$a$b]" --slurpfile g "$global_manifest" \
    '. + {segments: ((.segments + [$g[0].segments[]
                        | select(.prefixes | test($p))])
                     | unique_by(.name))}' \
    "$own_json" > "$own_json.tmp" && mv "$own_json.tmp" "$own_json"
  { zstd -dq -c "$BANK_WORK/.g/blobs.txt.zst" | grep "^[$a$b]" || true; } \
    > "$BANK_WORK/.gslice"
  if [ -f "$BANK_WORK/own-range/blobs.txt.zst" ]; then
    zstd -dq -c "$BANK_WORK/own-range/blobs.txt.zst" >> "$BANK_WORK/.gslice"
  fi
  sort -u "$BANK_WORK/.gslice" \
    | zstd -q -o "$BANK_WORK/own-range/blobs.txt.zst" -f
  rm -f "$BANK_WORK/.gslice"
  echo "[bank] range $SHARD head merged with the global slice:" \
    "$(jq '.segments|length' "$own_json") segments," \
    "$(zstd -dq -c "$BANK_WORK/own-range/blobs.txt.zst" | wc -l | tr -d ' ') blobs"
fi

# ── seed own range: containers named by the manifest(s) ────────────
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
# The merged own-range head names every segment this range should hold
# (own manifest + global slice); seed straight from it.
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
