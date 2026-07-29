#!/usr/bin/env bash
# Restore action-cache rows from the federated AC bank (one manifest
# per ROLE - every node banks the rows it authored; see
# ci/ac-bank-plan.md).
#   ci/ac-bank-restore.sh <store_dir> <role> [all|own]
# all = lay down every role's rows (the driver: it is the only reader).
# own = lay down only this role's own history (workers: enough for a
#       compaction re-pack, and they never read the AC).
# Env: CAS_LINEAGE (required), CAS_PARENT_LINEAGE (optional trunk to
# inherit from - "all" mode lays its rows down UNDER this lineage's),
# GH_TOKEN, GITHUB_REPOSITORY, BANK_WORK.
# Side effects in $BANK_WORK:
#   ac-banked-rows.txt   union "<path> <sha256>" list (the publish diff)
#   own-ac/              own role manifest + row list (publish's head)
#   .ac-own-unknown      own-manifest lookup FAILED (publish must not
#                        stage a thin manifest over the fat one)
#   .ac-oldest-container created_at of the oldest container fetched
# Exit 3 = no AC manifests for this lineage (cold bank).
set -euo pipefail
mkdir -p "$1"
STORE_DIR=$(cd "$1" && pwd); ROLE="$2"; MODE="${3:-own}"
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}"
BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
mkdir -p "$BANK_WORK"
PREFIX="cas-manifest-$CAS_LINEAGE-ac-"

_fetch_zip() { # <artifact_id> <dest_dir>
  rm -rf "$2" && mkdir -p "$2"
  gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$1/zip" > "$2.zip"
  unzip -o -q "$2.zip" -d "$2" && rm -f "$2.zip"
}

# ── which role manifests to read ────────────────────────────────────
# Provenance-checked exactly like every other manifest: the publishing
# run must have run on the lineage's own branch in this repo.
rm -f "$BANK_WORK/.ac-own-unknown"
own_row=""
if ! own_row=$(gh api \
  "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$PREFIX$ROLE&per_page=20" \
  --jq "[.artifacts[]
    | select(.expired == false
             and .workflow_run.head_repository_id == .workflow_run.repository_id
             and .workflow_run.head_branch == \"$CAS_LINEAGE\")][0]
    | select(. != null) | \"\(.id) \(.name)\"" 2>/dev/null); then
  # A flake must not read as "absent": newest-wins would let this lap's
  # thin manifest clobber the fat one. Publish skips staging entirely.
  echo "[ac-bank] WARN own manifest lookup FAILED - publish will not stage"
  touch "$BANK_WORK/.ac-own-unknown"
  own_row=""
fi

: > "$BANK_WORK/.ac-manifests"
_list_role_manifests() { # <lineage>
  gh api "repos/$GITHUB_REPOSITORY/actions/artifacts?per_page=100" \
    --jq "[.artifacts[]
      | select(.expired == false
               and (.name | startswith(\"cas-manifest-$1-ac-\"))
               and .workflow_run.head_repository_id == .workflow_run.repository_id
               and .workflow_run.head_branch == \"$1\")]
      | group_by(.name) | map(sort_by(.created_at) | last)[]
      | \"\(.id) \(.name)\"" 2>/dev/null | tr -d '\r' || true
}

: > "$BANK_WORK/.ac-parents"
if [ "$MODE" = "all" ]; then
  # Newest artifact per role name, in one listing call - roles need no
  # enumeration here, so a matrix change cannot silently drop a slice.
  _list_role_manifests "$CAS_LINEAGE" > "$BANK_WORK/.ac-manifests"
  # Parent lineage (a branch inheriting the trunk): read-only. Its rows
  # seed this store and join the diff base so they are never re-banked,
  # but every publish still goes to THIS lineage's manifest.
  # Workers ('own' mode) skip it - they only need their own history for
  # a compaction re-pack, and inheriting rows they did not author would
  # invite them to re-bank the trunk.
  if [ -n "${CAS_PARENT_LINEAGE:-}" ] \
     && [ "$CAS_PARENT_LINEAGE" != "$CAS_LINEAGE" ]; then
    _list_role_manifests "$CAS_PARENT_LINEAGE" > "$BANK_WORK/.ac-parents"
  fi
fi
# The own manifest is always read (head + diff base), even in all mode
# where the listing may not have surfaced it yet.
if [ -n "$own_row" ] \
   && ! grep -qx "$own_row" "$BANK_WORK/.ac-manifests" 2>/dev/null; then
  printf '%s\n' "$own_row" >> "$BANK_WORK/.ac-manifests"
fi

if ! [ -s "$BANK_WORK/.ac-manifests" ] && ! [ -s "$BANK_WORK/.ac-parents" ]; then
  echo "[ac-bank] no AC manifests for $CAS_LINEAGE - cold bank"
  rm -f "$BANK_WORK/.ac-manifests" "$BANK_WORK/.ac-parents"
  exit 3
fi

# ── read every manifest: union row list + ordered segment plan ──────
# Rows are name-stable but content-mutable, so the apply order must be
# TOTAL and deterministic: (run asc, role asc, driver LAST). The driver
# goes last because its row is the normalized one and it is the only
# node that serves.
: > "$BANK_WORK/.ac-union"
: > "$BANK_WORK/.ac-plan"
found=0
inherited=0
# Rank 0 = parent lineage, 1 = this one. Rows are name-stable and
# content-mutable, so the apply order must be TOTAL: (lineage, run,
# role). Lineage outranks run because a branch that re-derived an
# action must beat the trunk's row for it even when the trunk published
# later - ordering by run alone would silently serve the trunk's stale
# result to the branch that changed the input.
awk '{print "0 " $0}' "$BANK_WORK/.ac-parents" > "$BANK_WORK/.ac-all"
awk '{print "1 " $0}' "$BANK_WORK/.ac-manifests" >> "$BANK_WORK/.ac-all"
mv "$BANK_WORK/.ac-all" "$BANK_WORK/.ac-manifests"
rm -f "$BANK_WORK/.ac-parents"
while read -r rank aid name; do
  [ -n "$aid" ] || continue
  role="${name##*-ac-}"
  _fetch_zip "$aid" "$BANK_WORK/.acm"
  [ -f "$BANK_WORK/.acm/manifest.json" ] || continue
  zstd -dq -c "$BANK_WORK/.acm/blobs.txt.zst" >> "$BANK_WORK/.ac-union"
  if [ "$rank" = "0" ]; then
    inherited=$((inherited + 1))
  else
    found=$((found + 1))
  fi
  # Segments inherit their packing run/role through write_manifest, so
  # a manifest's own generation says nothing about its old segments.
  sort_role="$role"
  [ "$role" != "driver" ] || sort_role="zzzz-driver"
  jq -r --arg role "$role" --arg sr "$sort_role" --arg rank "$rank" \
    '.segments[]
     | "\($rank)\t\(.run // 0)\t\($sr)\t\(.artifact // "-")\t\(.name)\t\($role)"' \
    "$BANK_WORK/.acm/manifest.json" | tr -d '\r' >> "$BANK_WORK/.ac-plan"
  if [ "$rank" = "1" ] && [ "$role" = "$ROLE" ]; then
    rm -rf "$BANK_WORK/own-ac" && mkdir -p "$BANK_WORK/own-ac"
    cp "$BANK_WORK/.acm/manifest.json" "$BANK_WORK/own-ac/manifest.json"
    cp "$BANK_WORK/.acm/blobs.txt.zst" "$BANK_WORK/own-ac/blobs.txt.zst"
  fi
  rm -rf "$BANK_WORK/.acm"
done < "$BANK_WORK/.ac-manifests"
rm -f "$BANK_WORK/.ac-manifests"

if [ "$((found + inherited))" -eq 0 ]; then
  echo "[ac-bank] AC manifests unreadable - cold bank"
  exit 3
fi
sort -u "$BANK_WORK/.ac-union" > "$BANK_WORK/ac-banked-rows.txt"
rm -f "$BANK_WORK/.ac-union"
echo "[ac-bank] $found role manifests ($inherited inherited), union" \
  "$(wc -l < "$BANK_WORK/ac-banked-rows.txt" | tr -d ' ') rows"

# ── fetch containers and lay rows down in generation order ──────────
sort -k1,1n -k2,2n -k3,3 -k5,5 "$BANK_WORK/.ac-plan" \
  > "$BANK_WORK/.ac-plan.sorted"
seeded=0
cur=""
while IFS="$(printf '\t')" read -r _rank _run _sr container seg _role; do
  [ "$container" != "-" ] || continue
  if [ "$container" != "$cur" ]; then
    rm -rf "$BANK_WORK/.acseg"
    row=$(gh api \
      "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$container&per_page=1" \
      --jq '[.artifacts[] | select(.expired == false)][0]
        | select(. != null) | "\(.id) \(.created_at)"' 2>/dev/null || true)
    aid="${row%% *}"
    created="${row#* }"
    if [ -n "$created" ] && { [ ! -f "$BANK_WORK/.ac-oldest-container" ] \
         || [ "$created" \< "$(cat "$BANK_WORK/.ac-oldest-container")" ]; }; then
      printf '%s' "$created" > "$BANK_WORK/.ac-oldest-container"
    fi
    if [ -z "$aid" ]; then
      # Referenced-but-missing container: those actions re-derive. A
      # missing AC row is a cache miss, never a corruption.
      echo "[ac-bank] WARN container $container missing - its rows re-derive"
      cur="$container"
      continue
    fi
    _fetch_zip "$aid" "$BANK_WORK/.acseg"
    cur="$container"
  fi
  [ -d "$BANK_WORK/.acseg/$seg" ] || continue
  ci/cas-bank.sh seed_store "$STORE_DIR" "$BANK_WORK/.acseg/$seg"
  seeded=$((seeded + 1))
done < "$BANK_WORK/.ac-plan.sorted"
rm -rf "$BANK_WORK/.acseg" "$BANK_WORK/.ac-plan" "$BANK_WORK/.ac-plan.sorted"
echo "[ac-bank] seeded $seeded segments into $STORE_DIR (mode $MODE)"

# --cache-failures writes failure rows; the read path serves them
# unconditionally, so a banked environmental failure (the exec-bit
# EACCES class, lap 29522220924) would replay forever. In-lap failure
# caching keeps working; the poison stops crossing laps.
for d in "$STORE_DIR/ac" "$STORE_DIR/acn"; do
  [ -d "$d" ] && ci/cas-bank.sh _tool ac-purge-failures "$d"
done
exit 0
