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

# The per-item hot paths (index/tar/link/purge) live in the ENGINE, as
# `rebuck2 bank <verb>`: shell loops fork per item and melt at fleet
# scale, and a separate tool in this repo meant the store format had two
# owners - it hand-rolled SHA-256 and a protobuf varint reader that
# rebuck2 already has. rebuck2 is installed on every runner anyway, so
# this also drops a per-runner cargo build. CAS_BANK_TOOL overrides with
# a binary taking the same verbs (a local build under test, say).
_tool() {
  if [ -n "${CAS_BANK_TOOL:-}" ]; then
    "$CAS_BANK_TOOL" "$@"
  else
    rebuck2 bank "$@"
  fi
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
  _tool pack "$1" "$2" "$3" "${4:-*}"
}

# ── write_manifest <lineage> <generation> <parent_lineage|-> \
#                  <parent_generation|-> <run_id> <head_dir|-> \
#                  <segments_dir> <out_dir> ─────────────────────────
# head_dir: unpacked previous cas-manifest artifact (manifest.json +
# blobs.txt.zst), or '-' for a cold bank. segments_dir: dir of
# verified new cas-seg-*/ subdirs (may be empty). Produces
# out_dir/{manifest.json,blobs.txt.zst}.
write_manifest() {
  _tool write-manifest "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

# ── segments_to_fetch <manifest.json> <owned_prefixes> ──────────────
# Prefix-bitmap matching game: print names of segments whose prefixes
# overlap owned_prefixes (e.g. "89"). '*' means fetch everything.
segments_to_fetch() {
  _tool fetch-list "$1" "$2"
}

# ── seed_store <store_dir> <segment_dir>... ─────────────────────────
# Untar downloaded segments into the store.
seed_store() {
  local store="$1"; shift
  _tool seed "$store" "$@"
}

# ── needs_compaction <manifest.json> ────────────────────────────────
# Applies the tunable thresholds; prints "yes <reason>" or "no".
# Fulls are prefix-binned packs (marked "full":true by compaction);
# everything else counts as delta.
needs_compaction() {
  _tool needs-compaction "$1"
}

# ── compact <store_dir> <out_dir> ───────────────────────────────────
# store_dir holds the fully-seeded bank content. Re-bin every blob
# into prefix-grouped segments (all 16 prefixes spread over packs of
# <=SEG_MAX_MB), marked "full":true in their meta. Caller publishes a
# fresh manifest whose segment list is exactly these.
compact() {
  _tool compact "$1" "$2"
}

# ── ac_pack <store_dir> <banked_rows_file> <out_dir> ────────────────
# The action cache banks like the CAS with ONE difference: rows are
# name-stable but content-MUTABLE (a re-executed action overwrites its
# row), so the diff key is (name, content-hash), not name alone.
# Segments carry the CAS layout verbatim - bulk.tar.zst + blobs.txt.zst
# + meta.json - so seed_store/write_manifest/segments_to_fetch are
# reused unchanged; for the AC a "blob" line is
# "<store-relative-path> <sha256(content)>".
# Prints created segment names. banked_rows may be /dev/null.
ac_pack() {
  _tool ac-pack "$1" "$2" "$3"
}

# ── ac_rows <store_dir> ─────────────────────────────────────────────
# "<path> <sha256>" for every row - the banked-set shape.
ac_rows() {
  _tool ac-index "$1" | awk -F'\t' '{print $1 " " $2}' | sort
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
