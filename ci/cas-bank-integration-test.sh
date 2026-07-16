#!/usr/bin/env bash
# End-to-end CAS bank choreography without GitHub: a fake `gh` serves
# artifacts from $FAKE_ART. Simulates two laps + a straggler worker
# whose container never landed.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export FAKE_ART="$T/artifacts"
mkdir -p "$FAKE_ART" "$T/bin"

# fake gh: understands the three shapes the bank scripts use.
cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${GH_CALL_LOG:-}" ]; then printf '%s\n' "$*" >> "$GH_CALL_LOG"; fi
[ "$1" = "api" ] || { echo "fake gh: not api: $*" >&2; exit 1; }
url="$2"
case "$url" in
  *artifacts\?name=*)
    name="${url#*artifacts\?name=}"; name="${name%%\&*}"
    jq_expr=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--jq" ]; then jq_expr="$a"; fi
      prev="$a"
    done
    if [[ "$jq_expr" == *length* ]]; then # banker verification: count
      if [ -d "$FAKE_ART/$name" ]; then echo 1; else echo 0; fi
    else                                  # restore: newest id (id == name)
      if [ -d "$FAKE_ART/$name" ]; then echo "$name"; fi
    fi ;;
  *artifacts/*/zip)
    id="${url#*artifacts/}"; id="${id%/zip}"
    (cd "$FAKE_ART/$id" && zip -qr - .) ;;
  *)
    echo "fake gh: unhandled $url" >&2; exit 1 ;;
esac
FAKE
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export CAS_LINEAGE=test-lineage GITHUB_REPOSITORY=fake/fake
publish_to_fake() { # stand-in for actions/upload-artifact
  local name="$1" src="$2"
  rm -rf "${FAKE_ART:?}/$name"
  cp -R "$src" "$FAKE_ART/$name"
}

# ── lap 1: cold bank, two workers produce blobs ─────────────────────
W1="$T/lap1-w1"; W2="$T/lap1-w2"
mkb() { mkdir -p "$1/cas/${2:0:2}"; printf '%s' "$3" > "$1/cas/${2:0:2}/$2"; }
mkb "$W1" 11aabb01 "one"
mkb "$W1" 99ffee02 "two"
mkb "$W2" eedd0304 "three"

work() { # <store> <role> <run>  - restore, then publish into FAKE_ART
  local store="$1" role="$2" run="$3" rc=0
  local wk="$T/wk-$run-$role"
  rc=0; BANK_WORK="$wk" ci/cas-bank-restore.sh "$store" '*' || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || fail "restore rc=$rc"
  BANK_WORK="$wk" GITHUB_RUN_ID=$run ci/cas-bank-publish.sh "$store" "$role"
  if [ -d "$wk/bank-container" ]; then
    publish_to_fake "cas-segs-$CAS_LINEAGE-$run-$role" "$wk/bank-container"
    rm -rf "$T/reports-$run-$role"
    cp -R "$wk/bank-report" "$T/reports-$run-$role"
  fi
}
bank() { # <run> - banker over all reports of that run
  local run="$1"
  local merged="$T/merged-$run"
  rm -rf "$merged"; mkdir -p "$merged"
  local r
  for r in "$T/reports-$run-"*; do
    [ -d "$r" ] || continue
    cp -R "$r"/cas-seg-* "$merged/" 2>/dev/null || true
  done
  local wk="$T/bank-$run"
  BANK_WORK="$wk" GITHUB_RUN_ID=$run ci/cas-bank-banker.sh "$merged"
  publish_to_fake "cas-manifest-$CAS_LINEAGE" "$wk/bank-manifest-out"
}

work "$W1" w1 100
work "$W2" w2 100
bank 100
n=$(zstd -dq -c "$FAKE_ART/cas-manifest-$CAS_LINEAGE/blobs.txt.zst" | wc -l)
[ "$n" -eq 3 ] || fail "lap1 bank should hold 3 blobs, has $n"
echo "ok - lap1: cold bank built from two workers"

# ── lap 2: fresh worker restores, adds one blob; straggler drops ────
W3="$T/lap2-w3"
work "$W3" w3 200
for b in 11aabb01 99ffee02 eedd0304; do
  [ -f "$W3/cas/${b:0:2}/$b" ] || fail "lap2 restore missing $b"
done
mkb "$W3" 55cc0607 "four"
BANK_WORK="$T/wk-200-w3" GITHUB_RUN_ID=200 ci/cas-bank-publish.sh "$W3" w3
publish_to_fake "cas-segs-$CAS_LINEAGE-200-w3" "$T/wk-200-w3/bank-container"
rm -rf "$T/reports-200-w3"
cp -R "$T/wk-200-w3/bank-report" "$T/reports-200-w3"

# Straggler: packed + reported but container upload never landed.
W4="$T/lap2-w4"
mkb "$W4" aa119999 "ghost"
BANK_WORK="$T/wk-200-w4" GITHUB_RUN_ID=200 ci/cas-bank-publish.sh "$W4" w4
rm -rf "$T/reports-200-w4"
cp -R "$T/wk-200-w4/bank-report" "$T/reports-200-w4"
# note: NOT published to FAKE_ART - the death.

bank 200
n=$(zstd -dq -c "$FAKE_ART/cas-manifest-$CAS_LINEAGE/blobs.txt.zst" | wc -l)
[ "$n" -eq 4 ] || fail "lap2 bank should hold 4 blobs (ghost dropped), has $n"
zstd -dq -c "$FAKE_ART/cas-manifest-$CAS_LINEAGE/blobs.txt.zst" \
  | grep -q aa119999 && fail "ghost blob banked despite missing container"
echo "ok - lap2: incremental bank; straggler's segment dropped, not lied about"

# ── lap 3: subset restore by prefix ────────────────────────────────
W5="$T/lap3-w5"
BANK_WORK="$T/wk-300-w5" ci/cas-bank-restore.sh "$W5" "59"
[ -f "$W5/cas/55/55cc0607" ] || fail "prefix 5 blob not restored"
[ -f "$W5/cas/99/99ffee02" ] || fail "prefix 9 blob not restored"
echo "ok - lap3: prefix-subset restore"

# ── lap 4: banker probes each CONTAINER once, not once per segment ──
# Live lap 29441912158 carried 476 segments in 13 containers; the
# per-segment probe shape was 476 gh calls a lap.
W6="$T/lap4-w6"
pad="beef0000000000000000000000000000000000000000000000000000000000" # 62 hex -> 64 with the %02x
for i in 0 1 2 3 4 5 6 7 8 9 10 11; do
  name="$(printf '%02x' "$i")$pad"
  mkdir -p "$W6/cas/${name:0:2}"
  head -c $((700 * 1024)) /dev/zero | tr '\0' "$(printf '%x' "$i")" \
    > "$W6/cas/${name:0:2}/$name"
done
BANK_WORK="$T/wk-400-w6" GITHUB_RUN_ID=400 SEG_MAX_MB=1 \
  ci/cas-bank-publish.sh "$W6" w6
publish_to_fake "cas-segs-$CAS_LINEAGE-400-w6" "$T/wk-400-w6/bank-container"
rm -rf "$T/reports-400-w6"
cp -R "$T/wk-400-w6/bank-report" "$T/reports-400-w6"
segs=$(find "$T/reports-400-w6" -mindepth 1 -maxdepth 1 -name 'cas-seg-*' | wc -l | tr -d ' ')
[ "$segs" -ge 6 ] || fail "lap4 wants many segments in one container, got $segs"
export GH_CALL_LOG="$T/gh-calls.log"
: > "$GH_CALL_LOG"
bank 400
unset GH_CALL_LOG
probes=$(grep -c "cas-segs-" "$T/gh-calls.log" || true)
[ "$probes" -eq 1 ] \
  || fail "banker made $probes container probes for 1 container ($segs segments)"
n=$(zstd -dq -c "$FAKE_ART/cas-manifest-$CAS_LINEAGE/blobs.txt.zst" | wc -l | tr -d ' ')
[ "$n" -eq 16 ] || fail "lap4 bank should hold 16 blobs, has $n"
echo "ok - lap4: $segs segments, one container, one probe"

echo "PASS: integration"
