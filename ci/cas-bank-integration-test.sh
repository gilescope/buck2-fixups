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
#!/usr/bin/env python3
import io, json, os, re, sys, zipfile
root = os.environ["FAKE_ART"]
argv = sys.argv[1:]
assert argv[0] == "api", argv
url = argv[1]
m = re.search(r"artifacts\?name=([^&]+)", url)
if m:
    name = m.group(1)
    d = os.path.join(root, name)
    jq = argv[argv.index("--jq") + 1] if "--jq" in argv else ""
    if "length" in jq:  # banker verification: count for this run
        print(1 if os.path.isdir(d) else 0)
    else:               # restore: newest artifact id (id == name here)
        if os.path.isdir(d):
            print(name)
    sys.exit(0)
m = re.search(r"artifacts/([^/]+)/zip", url)
if m:
    d = os.path.join(root, m.group(1))
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for base, _, files in os.walk(d):
            for f in files:
                p = os.path.join(base, f)
                z.write(p, os.path.relpath(p, d))
    sys.stdout.buffer.write(buf.getvalue())
    sys.exit(0)
sys.exit(f"fake gh: unhandled {url}")
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

echo "PASS: integration"
