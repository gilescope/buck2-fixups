#!/usr/bin/env bash
# Local tests for ci/cas-bank.sh - no GitHub required.
#   ci/cas-bank-test.sh            # run all
set -euo pipefail
cd "$(dirname "$0")/.."
BANK=ci/cas-bank.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
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
python3 - "$S5" <<'PY'
import hashlib, os, sys
store = sys.argv[1]
for i in range(10000):
    h = hashlib.sha256(str(i).encode()).hexdigest()
    d = os.path.join(store, "cas", h[:2])
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, h), "wb") as f:
        f.write(str(i).encode())
PY
start=$SECONDS
$BANK pack_segments "$S5" /dev/null "$T/segs5" > "$T/segs5.names"
elapsed=$((SECONDS - start))
n=$(zstd -dq -c "$T/segs5"/cas-seg-*/blobs.txt.zst | wc -l | tr -d ' ')
[ "$n" -eq 10000 ] || fail "scale pack lost blobs: $n/10000"
[ "$elapsed" -lt 60 ] \
  || fail "scale pack took ${elapsed}s - O(n^2) regression?"
ok "pack: 10k blobs in ${elapsed}s (single pass)"

# ── compact at fleet scale: no per-blob forks in the re-bin ─────────
# Same failure class as the pack loop: the mini-store hardlink loop
# forked mkdir+ln per blob - hours at the bank's 2.27M blobs.
start=$SECONDS
$BANK compact "$S5" "$T/packs5" > "$T/packs5.names"
elapsed=$((SECONDS - start))
n=$(zstd -dq -c "$T/packs5"/cas-seg-*/blobs.txt.zst | sort -u | wc -l | tr -d ' ')
[ "$n" -eq 10000 ] || fail "scale compact lost blobs: $n/10000"
[ "$elapsed" -lt 60 ] \
  || fail "scale compact took ${elapsed}s - per-blob forks?"
ok "compact: 10k blobs re-binned in ${elapsed}s (single pass)"

# ── manifest assembly + prefix matching at fleet scale ──────────────
# 600 segments approximates a few uncompacted laps (476 seen live).
python3 - "$T/segs6" <<'PY'
import hashlib, json, os, sys
out = sys.argv[1]
for i in range(600):
    h = hashlib.sha256(f"seg{i}".encode()).hexdigest()
    d = os.path.join(out, f"cas-seg-{h}")
    os.makedirs(d, exist_ok=True)
    blobs = [hashlib.sha256(f"{i}.{j}".encode()).hexdigest() for j in range(20)]
    with open(os.path.join(d, "meta.json"), "w") as f:
        json.dump({"name": f"cas-seg-{h}", "bytes": 1000, "blobs": 20,
                   "prefixes": h[0]}, f)
    with open(os.path.join(d, "blobs.txt"), "w") as f:
        f.write("\n".join(sorted(blobs)) + "\n")
PY
for d in "$T/segs6"/cas-seg-*/; do zstd -q --rm "$d/blobs.txt"; done
start=$SECONDS
$BANK write_manifest lin-b gen-1 - - 1006 - "$T/segs6" "$T/m6"
elapsed=$((SECONDS - start))
[ "$(jq '.segments | length' "$T/m6/manifest.json")" -eq 600 ] \
  || fail "scale manifest segment count"
[ "$(zstd -dq -c "$T/m6/blobs.txt.zst" | wc -l | tr -d ' ')" -eq 12000 ] \
  || fail "scale manifest blob union"
[ "$elapsed" -lt 60 ] || fail "scale manifest took ${elapsed}s"
start=$SECONDS
hits=$($BANK segments_to_fetch "$T/m6/manifest.json" "01" | wc -l | tr -d ' ')
elapsed=$((SECONDS - start))
[ "$hits" -gt 0 ] || fail "scale fetch matched nothing"
[ "$elapsed" -lt 10 ] || fail "scale segments_to_fetch took ${elapsed}s"
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

echo "PASS: $pass groups"
