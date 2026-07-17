#!/usr/bin/env bash
# CAS bank: segment/manifest persistence for the rebuck2 fleet store.
# Design: ci/cas-bank-design.md. Sourced by workflow steps; every
# function is also callable standalone for the local test harness:
#   ci/cas-bank.sh <function> [args...]
#
# Knobs (env, all tunable):
#   SEG_MAX_MB   segment size target (default 64)
#   BANK_DIR     working dir for manifest/segment staging (required)
#
# Artifact upload/download is the caller's job (workflow steps or the
# test harness) - these functions only produce/consume files, so they
# are testable without GitHub.

set -euo pipefail

SEG_MAX_MB="${SEG_MAX_MB:-64}"

# ── helpers ─────────────────────────────────────────────────────────

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Rust helper for the per-blob hot paths (index/tar/link): shell loops
# fork per item and melt at fleet scale. Zero deps, so the on-demand
# build works offline; CAS_BANK_TOOL overrides (e.g. a prebuilt path).
_tool() {
  if [ -z "${CAS_BANK_TOOL:-}" ]; then
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cas-bank-tool"
    if [ -x "$dir/target/release/cas-bank-tool" ]; then
      CAS_BANK_TOOL="$dir/target/release/cas-bank-tool"
    elif [ -x "$dir/target/release/cas-bank-tool.exe" ]; then
      CAS_BANK_TOOL="$dir/target/release/cas-bank-tool.exe"
    else
      cargo build --release --quiet --manifest-path "$dir/Cargo.toml"
      CAS_BANK_TOOL="$dir/target/release/cas-bank-tool"
      [ -x "$CAS_BANK_TOOL" ] || CAS_BANK_TOOL="$CAS_BANK_TOOL.exe"
    fi
  fi
  "$CAS_BANK_TOOL" "$@"
}

# ── pack_segments <store_dir> <bank_blobs_file> <out_dir> [prefixes] ─
# Diff the store against the bank's blob list; pack new blobs into
# <=SEG_MAX_MB tar.zst segments under out_dir, one subdir per segment:
#   out_dir/cas-seg-<sha256>/{bulk.tar.zst,blobs.txt.zst,meta.json}
# Prints created segment names, one per line. No new blobs -> no
# output, exit 0. bank_blobs_file may be /dev/null (cold bank).
# prefixes: only pack new blobs whose first hex char is in this set
# (e.g. "01"); '*' or absent = all (federated split: a range owner
# packs its own prefixes; everything else spills).
pack_segments() {
  local store="$1" bank_blobs="$2" out="$3" only="${4:-*}"
  mkdir -p "$out"
  [ -d "$store/cas" ] || return 0

  local new_list="$out/.new-blobs" tab
  tab=$(printf '\t')
  # Store layout: cas/<2-hex>/<full-hash>. Blob id = basename. One
  # tool pass indexes blob\tpath\tbytes (blob-sorted): sizing per blob
  # inside the batching loop (an awk scan + wc fork each) was O(n^2)
  # and stalled every worker 30min+ at fleet scale (run 29435672672).
  _tool index "$store" > "$out/.store-idx"
  # bank blob list: plain sorted hashes (possibly zstd'd by caller).
  comm -23 <(cut -f1 "$out/.store-idx") <(sort -u "$bank_blobs") \
    > "$new_list"
  if [ "$only" != '*' ]; then
    grep "^[$only]" "$new_list" > "$new_list.f" || true
    mv "$new_list.f" "$new_list"
  fi
  if ! [ -s "$new_list" ]; then
    rm -f "$out/.new-blobs" "$out/.store-idx"
    return 0
  fi
  # New blobs joined back to their path+size, still hash-sorted.
  join -t "$tab" "$new_list" "$out/.store-idx" > "$out/.new-idx"

  # Greedy split by cumulative file size.
  local max_bytes=$((SEG_MAX_MB * 1024 * 1024))
  local batch="$out/.batch" batch_bytes=0 batch_n=0 seg_i=0
  : > "$batch"
  _seal() {
    [ -s "$batch" ] || return 0
    local tmp="$out/.seg-$seg_i"
    mkdir -p "$tmp"
    # Deterministic USTAR via the rust tool (bsdtar on mac lacks
    # --mtime etc). Segment name = sha256 of the RAW tar, so a zstd
    # version bump cannot fork the name of identical content.
    _tool tar "$store" "$batch" "$tmp/bulk.tar"
    local sha
    sha=$(_sha256 "$tmp/bulk.tar")
    zstd -q -8 --rm "$tmp/bulk.tar" -o "$tmp/bulk.tar.zst"
    awk -F/ '{print $NF}' "$batch" | sort > "$tmp/blobs.txt"
    zstd -q --rm "$tmp/blobs.txt"
    local prefixes bytes blobs
    prefixes=$(zstd -dq -c "$tmp/blobs.txt.zst" | cut -c1 | sort -u \
      | tr -d '\n')
    blobs=$(zstd -dq -c "$tmp/blobs.txt.zst" | wc -l | tr -d ' ')
    bytes=$(wc -c < "$tmp/bulk.tar.zst" | tr -d ' ')
    printf '{"name":"cas-seg-%s","bytes":%s,"blobs":%s,"prefixes":"%s"}\n' \
      "$sha" "$bytes" "$blobs" "$prefixes" > "$tmp/meta.json"
    mv "$tmp" "$out/cas-seg-$sha"
    echo "cas-seg-$sha"
    seg_i=$((seg_i + 1)); batch_bytes=0; batch_n=0; : > "$batch"
  }
  local path sz
  while IFS="$tab" read -r _ path sz; do
    if [ "$batch_n" -gt 0 ] \
       && [ $((batch_bytes + sz)) -gt "$max_bytes" ]; then
      _seal
    fi
    echo "$path" >> "$batch"
    batch_bytes=$((batch_bytes + sz)); batch_n=$((batch_n + 1))
  done < "$out/.new-idx"
  _seal
  rm -f "$new_list" "$out/.store-idx" "$out/.new-idx" "$batch"
}

# ── write_manifest <lineage> <generation> <parent_lineage|-> \
#                  <parent_generation|-> <run_id> <head_dir|-> \
#                  <segments_dir> <out_dir> ─────────────────────────
# head_dir: unpacked previous cas-manifest artifact (manifest.json +
# blobs.txt.zst), or '-' for a cold bank. segments_dir: dir of
# verified new cas-seg-*/ subdirs (may be empty). Produces
# out_dir/{manifest.json,blobs.txt.zst}.
write_manifest() {
  local lineage="$1" generation="$2" parent_lineage="$3"
  local parent_generation="$4" run_id="$5" head="$6" segs="$7" out="$8"
  mkdir -p "$out"

  local old_segments='[]' old_blobs="$out/.old-blobs"
  : > "$old_blobs"
  if [ "$head" != "-" ] && [ -f "$head/manifest.json" ]; then
    old_segments=$(jq -c '.segments' "$head/manifest.json")
    zstd -dq -c "$head/blobs.txt.zst" > "$old_blobs"
  fi

  local new_segments="$out/.new-segs" new_blobs="$out/.new-blobs"
  : > "$new_segments"; : > "$new_blobs"
  local d
  for d in "$segs"/cas-seg-*/; do
    [ -d "$d" ] || continue
    cat "$d/meta.json" >> "$new_segments"
    zstd -dq -c "$d/blobs.txt.zst" >> "$new_blobs"
  done

  # Real file, not <(): native jq.exe on windows cannot open MSYS
  # /proc/N/fd process-substitution paths (bit win workers the first
  # lap write_manifest ran outside the ubuntu banker, run 29486020160).
  jq -s '.' "$new_segments" > "$out/.new-segs.json" 2>/dev/null \
    || echo '[]' > "$out/.new-segs.json"
  jq -n \
    --arg lineage "$lineage" \
    --arg generation "$generation" \
    --arg parent_lineage "$parent_lineage" \
    --arg parent_generation "$parent_generation" \
    --argjson run_id "$run_id" \
    --argjson old "$old_segments" \
    --slurpfile new "$out/.new-segs.json" \
    '{version: 1, lineage: $lineage, generation: $generation,
      parent_lineage: (if $parent_lineage == "-" then null
                       else $parent_lineage end),
      parent_generation: (if $parent_generation == "-" then null
                          else $parent_generation end),
      created_by_run: $run_id,
      segments: ($old + $new[0])}' > "$out/manifest.json"

  sort -u "$old_blobs" "$new_blobs" | zstd -q -o "$out/blobs.txt.zst" -f
  rm -f "$old_blobs" "$new_segments" "$new_blobs" "$out/.new-segs.json"
}

# ── segments_to_fetch <manifest.json> <owned_prefixes> ──────────────
# Prefix-bitmap matching game: print names of segments whose prefixes
# overlap owned_prefixes (e.g. "89"). '*' means fetch everything.
segments_to_fetch() {
  local manifest="$1" owned="$2"
  # tr: jq.exe emits CRLF on windows; a stray \r in a segment name made
  # every [ -d ] test fail except the last line's (run 29491383253:
  # "seeded 1 segments" against a 16-segment head).
  if [ "$owned" = '*' ]; then
    jq -r '.segments[].name' "$manifest" | tr -d '\r'
    return 0
  fi
  jq -r --arg owned "$owned" '
    .segments[]
    | select(.prefixes | split("") | any(. as $p
        | ($owned | contains($p))))
    | .name' "$manifest" | tr -d '\r'
}

# ── seed_store <store_dir> <segment_dir>... ─────────────────────────
# Untar downloaded segments into the store.
seed_store() {
  local store="$1"; shift
  mkdir -p "$store"
  local d
  for d in "$@"; do
    [ -f "$d/bulk.tar.zst" ] || continue
    zstd -dq -c "$d/bulk.tar.zst" | tar -x -C "$store"
  done
}

# ── needs_compaction <manifest.json> ────────────────────────────────
# Applies the tunable thresholds; prints "yes <reason>" or "no".
# Fulls are prefix-binned packs (marked "full":true by compaction);
# everything else counts as delta.
needs_compaction() {
  local manifest="$1"
  local pct="${COMPACT_DELTA_PCT:-20}" hyst="${COMPACT_HYSTERESIS_PCT:-5}"
  local min_mb="${COMPACT_MIN_MB:-256}" max_segs="${COMPACT_MAX_SEGMENTS:-64}"
  local full_bytes delta_bytes segs
  full_bytes=$(jq '[.segments[] | select(.full == true) | .bytes] | add // 0' \
    "$manifest")
  delta_bytes=$(jq '[.segments[] | select(.full != true) | .bytes] | add // 0' \
    "$manifest")
  # Cap counts DELTA segments only: full packs are as binned as they
  # get - a big range legitimately needs many of them (r0's first
  # compaction produced 70 at SEG_MAX=64MB, and counting those re-fired
  # the trigger every lap: 1.3GB of churn re-packing already-compact
  # content, run 29589478222).
  segs=$(jq '[.segments[] | select(.full != true)] | length' "$manifest")
  if [ "$segs" -gt "$max_segs" ]; then
    echo "yes segments=$segs>max=$max_segs"; return 0
  fi
  if [ "$delta_bytes" -lt $((min_mb * 1024 * 1024)) ]; then
    echo "no"; return 0
  fi
  # Cold bank (no fulls yet): any delta above the floor compacts.
  if [ "$full_bytes" -eq 0 ]; then
    echo "yes cold-bank delta=${delta_bytes}B"; return 0
  fi
  local threshold=$(( full_bytes * (pct + hyst) / 100 ))
  if [ "$delta_bytes" -gt "$threshold" ]; then
    echo "yes delta=${delta_bytes}B>$((pct + hyst))%of=${full_bytes}B"
  else
    echo "no"
  fi
}

# ── compact <store_dir> <out_dir> ───────────────────────────────────
# store_dir holds the fully-seeded bank content. Re-bin every blob
# into prefix-grouped segments (all 16 prefixes spread over packs of
# <=SEG_MAX_MB), marked "full":true in their meta. Caller publishes a
# fresh manifest whose segment list is exactly these.
compact() {
  local store="$1" out="$2"
  mkdir -p "$out"
  local p
  for p in 0 1 2 3 4 5 6 7 8 9 a b c d e f; do
    local sub="$out/.prefix-$p"
    mkdir -p "$sub"
    (cd "$store" && find cas -mindepth 2 -maxdepth 2 -type f \
        -path "cas/$p*" | sort) > "$sub/paths" || true
    [ -s "$sub/paths" ] || { rm -rf "$sub"; continue; }
    # Reuse pack_segments' sealing by faking a mini-store view: one
    # tool pass hardlinks the prefix's blobs (a per-blob mkdir+ln
    # shell loop here was the pack loop's O(n*forks) class again -
    # 170s at 10k blobs, hours at the live bank's 2.27M).
    local mini="$sub/store"
    _tool link "$store" "$sub/paths" "$mini"
    pack_segments "$mini" /dev/null "$out" > /dev/null
    rm -rf "$sub"
  done
  # Stamp every produced segment as a full pack.
  local d
  for d in "$out"/cas-seg-*/; do
    [ -d "$d" ] || continue
    jq -c '. + {full: true}' "$d/meta.json" > "$d/meta.json.tmp" \
      && mv "$d/meta.json.tmp" "$d/meta.json"
    basename "$d"
  done
}

# ── dice_pack <db_dir> <banked_keys_file> <out_dir> ─────────────────
# The dice value store (pagable.{0..15}.db, table pagable_data with
# content-addressed 128-bit keys, INSERT OR IGNORE writes) is a CAS in
# sqlite clothing - so bank it like one. Exports rows whose key is not
# in banked_keys as deterministic text segments:
#   out_dir/cas-seg-<sha256>/{rows.txt.zst,blobs.txt.zst,meta.json}
# rows.txt lines: "<shard> <key_hi> <key_lo> <hexvalue>" (shard =
# key_lo & 15, computed by sqlite - exact i64 math awk cannot do).
# blobs.txt lines: "<key_hi> <key_lo>" (the diff list). Prints segment
# names. banked_keys may be /dev/null (cold bank).
dice_pack() {
  local db="$1" banked="$2" out="$3"
  local raw_mb="${DICE_SEG_RAW_MB:-256}"
  mkdir -p "$out"
  local rows="$out/.rows" i
  : > "$rows"
  for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [ -f "$db/pagable.$i.db" ] || continue
    sqlite3 -readonly "$db/pagable.$i.db" \
      "SELECT printf('%d %d %d ', key_lo & 15, key_hi, key_lo) || hex(value)
       FROM pagable_data ORDER BY key_hi, key_lo;" >> "$rows"
  done
  # Diff on (key_hi, key_lo) against the banked set, then greedy-split
  # into raw parts of <= raw_mb.
  # FILENAME guard, not NR==FNR: an EMPTY banked file (cold bank via
  # /dev/null) makes NR==FNR true for the rows file's first lines.
  awk -v out="$out/.part" -v max=$((raw_mb * 1024 * 1024)) \
      -v bankfile="$banked" '
    FILENAME == bankfile { bank[$0] = 1; next }
    {
      if (($2 " " $3) in bank) next
      if (bytes >= max) { close(out "." part); part++; bytes = 0 }
      print > (out "." part)
      bytes += length($0) + 1
    }' "$banked" "$rows"
  rm -f "$rows"
  local part sha tmp
  for part in "$out"/.part.*; do
    [ -f "$part" ] || continue
    sha=$(_sha256 "$part")
    tmp="$out/cas-seg-$sha"
    mkdir -p "$tmp"
    awk '{print $2 " " $3}' "$part" | sort > "$tmp/blobs.txt"
    zstd -q --rm "$tmp/blobs.txt"
    local nrows bytes
    nrows=$(zstd -dq -c "$tmp/blobs.txt.zst" | wc -l | tr -d ' ')
    zstd -q -8 --rm "$part" -o "$tmp/rows.txt.zst"
    bytes=$(wc -c < "$tmp/rows.txt.zst" | tr -d ' ')
    printf '{"name":"cas-seg-%s","bytes":%s,"blobs":%s,"prefixes":"*"}\n' \
      "$sha" "$bytes" "$nrows" > "$tmp/meta.json"
    echo "cas-seg-$sha"
  done
}

# ── dice_merge <db_dir> <segment_dir>... ────────────────────────────
# Replay segments into the sharded dbs. INSERT OR IGNORE on content-
# addressed keys: idempotent, order-independent, conflict-free.
dice_merge() {
  local db="$1"; shift
  mkdir -p "$db"
  local i d
  for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sqlite3 "$db/pagable.$i.db" \
      "CREATE TABLE IF NOT EXISTS pagable_data (
         key_lo INTEGER NOT NULL, key_hi INTEGER NOT NULL,
         value BLOB NOT NULL, UNIQUE(key_hi, key_lo));"
  done
  local work
  work=$(mktemp -d)
  for d in "$@"; do
    [ -f "$d/rows.txt.zst" ] || continue
    zstd -dq -c "$d/rows.txt.zst" | awk -v w="$work" -v q="'" '
      {
        print "INSERT OR IGNORE INTO pagable_data VALUES(" \
          $3 "," $2 ",X" q $4 q ");" >> (w "/shard" $1 ".sql")
      }'
  done
  for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [ -f "$work/shard$i.sql" ] || continue
    { echo "BEGIN;"; cat "$work/shard$i.sql"; echo "COMMIT;"; } \
      | sqlite3 "$db/pagable.$i.db"
  done
  rm -rf "$work"
}

# ── dice_keys <db_dir> ──────────────────────────────────────────────
# Sorted "<key_hi> <key_lo>" list of every row (the banked-set shape).
dice_keys() {
  local db="$1" i
  for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [ -f "$db/pagable.$i.db" ] || continue
    sqlite3 -readonly "$db/pagable.$i.db" \
      "SELECT printf('%d %d', key_hi, key_lo) FROM pagable_data;"
  done | sort
}

# Allow `ci/cas-bank.sh <fn> args...` for tests and workflow one-liners.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  "$@"
fi
