#!/usr/bin/env bash
# Local tests for ci/cas-bank.sh - no GitHub required.
#   ci/cas-bank-test.sh            # run all
set -euo pipefail
cd "$(dirname "$0")/.."
BANK=ci/cas-bank.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Child CPU seconds so far (user+sys): scale guards bound CPU, not
# wall clock - fork amplification burns CPU regardless of host load,
# while a loaded box (load 18 happens here) stretches wall arbitrarily.
child_cpu() {
  times | awk 'NR==2 { s = 0
    for (i = 1; i <= 2; i++) { split($i, a, "m"); sub("s", "", a[2])
      s += a[1] * 60 + a[2] }
    print int(s) }'
}
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }

mkblob() { # <store> <hash> <bytes>
  mkdir -p "$1/cas/${2:0:2}"
  head -c "$3" /dev/zero | tr '\0' "${2:0:1}" > "$1/cas/${2:0:2}/$2"
}

# ── pack: cold bank, three blobs, tiny SEG_MAX to force a split ────
S1="$T/store1"
mkblob "$S1" 1111aaaa 100
mkblob "$S1" 2222bbbb 200
mkblob "$S1" 99ffcccc 300
SEG_MAX_MB=1 $BANK pack_segments "$S1" /dev/null "$T/segs1" \
  > "$T/segs1.names"
[ "$(wc -l < "$T/segs1.names")" -eq 1 ] \
  || fail "expected 1 segment for 600 bytes, got $(cat "$T/segs1.names")"
seg1=$(cat "$T/segs1.names")
[ -f "$T/segs1/$seg1/bulk.tar.zst" ] || fail "segment tar missing"
prefixes=$(jq -r .prefixes "$T/segs1/$seg1/meta.json")
[ "$prefixes" = "129" ] || fail "prefix bitmap wrong: $prefixes"
ok "pack: cold bank -> one segment, bitmap {1,2,9}"

# ── pack determinism: same blobs, fresh store -> same segment hash ──
S1b="$T/store1b"
mkblob "$S1b" 1111aaaa 100
mkblob "$S1b" 2222bbbb 200
mkblob "$S1b" 99ffcccc 300
SEG_MAX_MB=1 $BANK pack_segments "$S1b" /dev/null "$T/segs1b" \
  > "$T/segs1b.names"
diff "$T/segs1.names" "$T/segs1b.names" \
  || fail "identical blob sets produced different segment names"
ok "pack: content-named and deterministic"

# ── manifest: cold, then incremental ────────────────────────────────
$BANK write_manifest lin-a gen-1 - - 1001 - "$T/segs1" "$T/m1"
[ "$(jq -r .lineage "$T/m1/manifest.json")" = "lin-a" ] || fail "lineage"
[ "$(jq '.segments | length' "$T/m1/manifest.json")" -eq 1 ] \
  || fail "manifest segment count"
[ "$(zstd -dq -c "$T/m1/blobs.txt.zst" | wc -l | tr -d ' ')" -eq 3 ] \
  || fail "manifest blob list"
ok "manifest: cold bank generation"

# lap 2: one new blob; diff against bank list must pack only it.
mkblob "$S1" eeee0123 50
zstd -dq -c "$T/m1/blobs.txt.zst" > "$T/bank-blobs"
SEG_MAX_MB=1 $BANK pack_segments "$S1" "$T/bank-blobs" "$T/segs2" \
  > "$T/segs2.names"
[ "$(wc -l < "$T/segs2.names")" -eq 1 ] || fail "lap2 segment count"
seg2=$(cat "$T/segs2.names")
[ "$(zstd -dq -c "$T/segs2/$seg2/blobs.txt.zst")" = "eeee0123" ] \
  || fail "lap2 packed old blobs too"
$BANK write_manifest lin-a gen-2 - - 1002 "$T/m1" "$T/segs2" "$T/m2"
[ "$(jq '.segments | length' "$T/m2/manifest.json")" -eq 2 ] \
  || fail "gen-2 segments"
[ "$(zstd -dq -c "$T/m2/blobs.txt.zst" | wc -l | tr -d ' ')" -eq 4 ] \
  || fail "gen-2 blob union"
ok "manifest: incremental lap packs only new blobs"

# ── pack prefix filter (federated range/spill split) ────────────────
$BANK pack_segments "$S1" /dev/null "$T/segsF" "9e" > "$T/segsF.names"
segF=$(cat "$T/segsF.names")
got=$(zstd -dq -c "$T/segsF/$segF/blobs.txt.zst" | tr '\n' ' ')
[ "$got" = "99ffcccc eeee0123 " ] \
  || fail "prefix filter 9e packed wrong blobs: $got"
$BANK pack_segments "$S1" /dev/null "$T/segsF2" "12" > "$T/segsF2.names"
got=$(zstd -dq -c "$T/segsF2/$(cat "$T/segsF2.names")/blobs.txt.zst" | tr '\n' ' ')
[ "$got" = "1111aaaa 2222bbbb " ] \
  || fail "prefix filter 12 packed wrong blobs: $got"
ok "pack: prefix filter splits range from spill"

# ── prefix matching game ────────────────────────────────────────────
got=$($BANK segments_to_fetch "$T/m2/manifest.json" "9")
[ "$got" = "$seg1" ] || fail "owner of 9 should fetch only seg1: $got"
got=$($BANK segments_to_fetch "$T/m2/manifest.json" "e")
[ "$got" = "$seg2" ] || fail "owner of e should fetch only seg2: $got"
got=$($BANK segments_to_fetch "$T/m2/manifest.json" "45")
[ -z "$got" ] || fail "owner of 45 should fetch nothing: $got"
got=$($BANK segments_to_fetch "$T/m2/manifest.json" '*' | wc -l | tr -d ' ')
[ "$got" -eq 2 ] || fail "wildcard fetches all"
ok "prefix bitmap: skip is certain, overlap fetches"

# ── seed round-trip ─────────────────────────────────────────────────
S2="$T/store2"
$BANK seed_store "$S2" "$T/segs1/$seg1" "$T/segs2/$seg2"
for b in 1111aaaa 2222bbbb 99ffcccc eeee0123; do
  cmp -s "$S1/cas/${b:0:2}/$b" "$S2/cas/${b:0:2}/$b" \
    || fail "round-trip mismatch for $b"
done
ok "seed: byte-identical round-trip"

# ── executables survive the bank ────────────────────────────────────
# Red run was live: lap 29507595376's 29 linux "failures" were ONE bug
# - mode 0644 on every USTAR entry stripped exec bits, and rebuck2
# hardlinks store files into exec dirs, so bank-seeded build scripts
# died with EACCES.
SX="$T/storex"
mkblob "$SX" ab120001 40
chmod 755 "$SX/cas/ab/ab120001"
$BANK pack_segments "$SX" /dev/null "$T/segsx" > "$T/segsx.names"
SX2="$T/storex2"
$BANK seed_store "$SX2" "$T/segsx/$(cat "$T/segsx.names")"
[ -x "$SX2/cas/ab/ab120001" ] \
  || fail "exec bit lost through pack/seed round-trip"
ok "seed: executables stay executable"

# ── needs_compaction thresholds ─────────────────────────────────────
res=$(COMPACT_MIN_MB=0 $BANK needs_compaction "$T/m2/manifest.json")
case "$res" in yes\ cold-bank*) ;; *) fail "cold bank should compact: $res";;
esac
res=$(COMPACT_MIN_MB=999999 $BANK needs_compaction "$T/m2/manifest.json")
[ "$res" = "no" ] || fail "floor should suppress: $res"
res=$(COMPACT_MAX_SEGMENTS=1 COMPACT_MIN_MB=999999 $BANK needs_compaction \
  "$T/m2/manifest.json")
case "$res" in yes\ segments*) ;; *) fail "segment cap should fire: $res";;
esac
ok "compaction triggers: floor, cold-bank, segment cap"

# ── compact: re-bin into full packs; blob set preserved ─────────────
$BANK compact "$S2" "$T/packs" > "$T/packs.names"
[ "$(wc -l < "$T/packs.names")" -ge 1 ] || fail "no packs produced"
all_full=$(cat "$T/packs"/cas-seg-*/meta.json | jq -s 'all(.full == true)')
[ "$all_full" = "true" ] || fail "packs not marked full"
$BANK write_manifest lin-a gen-3 - - 1003 - "$T/packs" "$T/m3"
diff <(zstd -dq -c "$T/m2/blobs.txt.zst") \
     <(zstd -dq -c "$T/m3/blobs.txt.zst") \
  || fail "compaction changed the blob set"
S3="$T/store3"
dirs=()
while IFS= read -r n; do dirs+=("$T/packs/$n"); done < "$T/packs.names"
$BANK seed_store "$S3" "${dirs[@]}"
for b in 1111aaaa 2222bbbb 99ffcccc eeee0123; do
  cmp -s "$S1/cas/${b:0:2}/$b" "$S3/cas/${b:0:2}/$b" \
    || fail "post-compaction mismatch for $b"
done
res=$(COMPACT_MIN_MB=0 COMPACT_DELTA_PCT=20 COMPACT_HYSTERESIS_PCT=5 \
  $BANK needs_compaction "$T/m3/manifest.json")
[ "$res" = "no" ] || fail "freshly compacted bank should not re-fire: $res"
ok "compact: full packs, blob set preserved, trigger quiesces"

# ── pack at fleet scale: single pass, no per-blob forks ─────────────
# Red run was live: lap 29435672672 stalled all 11 workers 30min+ in
# the per-blob awk+wc loop (O(n^2), 2 forks per blob) this guards.
S5="$T/store5"
$BANK _tool gen-store "$S5" 10000
start=$(child_cpu)
$BANK pack_segments "$S5" /dev/null "$T/segs5" > "$T/segs5.names"
elapsed=$(( $(child_cpu) - start ))
n=$(zstd -dq -c "$T/segs5"/cas-seg-*/blobs.txt.zst | wc -l | tr -d ' ')
[ "$n" -eq 10000 ] || fail "scale pack lost blobs: $n/10000"
[ "$elapsed" -lt 60 ] \
  || fail "scale pack burned ${elapsed}s CPU - O(n^2) regression?"
ok "pack: 10k blobs in ${elapsed}s (single pass)"

# ── compact at fleet scale: no per-blob forks in the re-bin ─────────
# Same failure class as the pack loop: the mini-store hardlink loop
# forked mkdir+ln per blob - hours at the bank's 2.27M blobs.
start=$(child_cpu)
$BANK compact "$S5" "$T/packs5" > "$T/packs5.names"
elapsed=$(( $(child_cpu) - start ))
n=$(zstd -dq -c "$T/packs5"/cas-seg-*/blobs.txt.zst | sort -u | wc -l | tr -d ' ')
[ "$n" -eq 10000 ] || fail "scale compact lost blobs: $n/10000"
[ "$elapsed" -lt 60 ] \
  || fail "scale compact burned ${elapsed}s CPU - per-blob forks?"
ok "compact: 10k blobs re-binned in ${elapsed}s (single pass)"

# ── manifest assembly + prefix matching at fleet scale ──────────────
# 600 segments approximates a few uncompacted laps (476 seen live).
$BANK _tool gen-segments "$T/segs6" 600
for d in "$T/segs6"/cas-seg-*/; do zstd -q --rm "$d/blobs.txt"; done
start=$(child_cpu)
$BANK write_manifest lin-b gen-1 - - 1006 - "$T/segs6" "$T/m6"
elapsed=$(( $(child_cpu) - start ))
[ "$(jq '.segments | length' "$T/m6/manifest.json")" -eq 600 ] \
  || fail "scale manifest segment count"
[ "$(zstd -dq -c "$T/m6/blobs.txt.zst" | wc -l | tr -d ' ')" -eq 12000 ] \
  || fail "scale manifest blob union"
[ "$elapsed" -lt 60 ] || fail "scale manifest burned ${elapsed}s CPU"
start=$(child_cpu)
hits=$($BANK segments_to_fetch "$T/m6/manifest.json" "01" | wc -l | tr -d ' ')
elapsed=$(( $(child_cpu) - start ))
[ "$hits" -gt 0 ] || fail "scale fetch matched nothing"
[ "$elapsed" -lt 10 ] || fail "scale segments_to_fetch burned ${elapsed}s CPU"
ok "manifest+fetch: 600 segments in bounds (write ok, match ${hits} segs)"

# ── segment split honours SEG_MAX ───────────────────────────────────
S4="$T/store4"
for i in 1 2 3 4 5 6; do
  mkblob "$S4" "aa0${i}$(printf '%04d' $i)" $((600 * 1024))
done
SEG_MAX_MB=1 $BANK pack_segments "$S4" /dev/null "$T/segs4" \
  > "$T/segs4.names"
n=$(wc -l < "$T/segs4.names" | tr -d ' ')
[ "$n" -ge 3 ] || fail "3.6MB at 1MB cap should split >=3 ways, got $n"
ok "pack: SEG_MAX split ($n segments for 3.6MB at 1MB cap)"

# ── dice bank: pack/merge the pagable sqlite rows ────────────────────
# Fixture: 2 shards with rows whose key_lo & 15 matches the shard file
# (the engine's shard_for is key.0 % 16 = key_lo & 15).
D1="$T/dice1"
mkdir -p "$D1"
mkrow() { # <shard> <key_hi> <key_lo> <hex>
  sqlite3 "$D1/pagable.$1.db" \
    "CREATE TABLE IF NOT EXISTS pagable_data (
       key_lo INTEGER NOT NULL, key_hi INTEGER NOT NULL,
       value BLOB NOT NULL, UNIQUE(key_hi, key_lo));
     INSERT OR IGNORE INTO pagable_data VALUES($3, $2, X'$4');"
}
mkrow 0 100 16 DEADBEEF
mkrow 0 101 32 CAFE
mkrow 3 -200 19 0BADF00D
$BANK dice_pack "$D1" /dev/null "$T/dsegs1" > "$T/dsegs1.names"
[ "$(wc -l < "$T/dsegs1.names" | tr -d ' ')" -eq 1 ] \
  || fail "dice cold pack segment count"
dseg1=$(cat "$T/dsegs1.names")
[ "$(zstd -dq -c "$T/dsegs1/$dseg1/blobs.txt.zst" | wc -l | tr -d ' ')" -eq 3 ] \
  || fail "dice pack key count"
# determinism
$BANK dice_pack "$D1" /dev/null "$T/dsegs1b" > "$T/dsegs1b.names"
diff "$T/dsegs1.names" "$T/dsegs1b.names" || fail "dice pack nondeterministic"
ok "dice: cold pack, content-named and deterministic"

# delta: only the new row packs
$BANK dice_keys "$D1" > "$T/dice-banked"
mkrow 5 300 21 ABCD
$BANK dice_pack "$D1" "$T/dice-banked" "$T/dsegs2" > "$T/dsegs2.names"
dseg2=$(cat "$T/dsegs2.names")
[ "$(zstd -dq -c "$T/dsegs2/$dseg2/blobs.txt.zst")" = "300 21" ] \
  || fail "dice delta packed old rows"
ok "dice: delta packs only new rows"

# merge into a fresh db dir; placement + idempotence + round-trip
D2="$T/dice2"
$BANK dice_merge "$D2" "$T/dsegs1/$dseg1" "$T/dsegs2/$dseg2"
got=$(sqlite3 "$D2/pagable.0.db" \
  "SELECT hex(value) FROM pagable_data ORDER BY key_hi;" | tr '\n' ' ')
[ "$got" = "DEADBEEF CAFE " ] || fail "dice merge shard 0 wrong: $got"
got=$(sqlite3 "$D2/pagable.3.db" "SELECT hex(value) FROM pagable_data;")
[ "$got" = "0BADF00D" ] || fail "dice merge shard 3 wrong: $got"
got=$(sqlite3 "$D2/pagable.5.db" "SELECT hex(value) FROM pagable_data;")
[ "$got" = "ABCD" ] || fail "dice merge shard 5 wrong: $got"
$BANK dice_merge "$D2" "$T/dsegs1/$dseg1"
n=$(sqlite3 "$D2/pagable.0.db" "SELECT count(*) FROM pagable_data;")
[ "$n" -eq 2 ] || fail "dice re-merge not idempotent: $n rows"
diff <($BANK dice_keys "$D1") <($BANK dice_keys "$D2") \
  || fail "dice key sets diverge after merge"
ok "dice: merge places by key_lo&15, idempotent, key sets match"

echo "PASS: $pass groups"
