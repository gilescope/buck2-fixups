#!/usr/bin/env bash
# End-to-end federated CAS bank choreography without GitHub: a fake
# `gh` serves artifacts from $FAKE_ART and runs the caller's REAL --jq
# expression over constructed JSON, so the scripts' queries are tested
# verbatim. Covers: migration from a global manifest, per-range
# manifest publish, spill + absorb-on-read, a straggler whose manifest
# never landed, and prefix-subset restore.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export FAKE_ART="$T/artifacts"
mkdir -p "$FAKE_ART/.meta" "$T/bin"

cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${GH_CALL_LOG:-}" ]; then printf '%s\n' "$*" >> "$GH_CALL_LOG"; fi
[ "$1" = "api" ] || { echo "fake gh: not api: $*" >&2; exit 1; }
url="$2"
if [ -n "${FAKE_FAIL_NAME:-}" ] \
   && [[ "$url" == *"artifacts?name=$FAKE_FAIL_NAME"* ]]; then
  echo "fake gh: injected failure for $FAKE_FAIL_NAME" >&2
  exit 1
fi
jq_expr=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then jq_expr="$a"; fi
  prev="$a"
done
_rows() { # emit artifact JSON rows for names on stdin
  while IFS= read -r n; do
    [ -d "$FAKE_ART/$n" ] || continue
    cat "$FAKE_ART/.meta/$n.json"
  done
}
case "$url" in
  *artifacts\?name=*)
    name="${url#*artifacts\?name=}"; name="${name%%\&*}"
    json=$(echo "$name" | _rows | jq -s '{artifacts: .}')
    ;;
  *artifacts\?per_page=*)
    json=$(ls "$FAKE_ART" | grep -v '^\.' | _rows | jq -s '{artifacts: .}')
    ;;
  *artifacts/*/zip)
    id="${url#*artifacts/}"; id="${id%/zip}"
    (cd "$FAKE_ART/$id" && zip -qr - .)
    exit 0
    ;;
  *)
    echo "fake gh: unhandled $url" >&2; exit 1 ;;
esac
if [ -n "$jq_expr" ]; then echo "$json" | jq -r "$jq_expr"; else echo "$json"; fi
FAKE
chmod +x "$T/bin/gh"

# The artifact verbs are rebuck2's now, so the fake moves to that
# boundary too: serve gh-list/gh-download from $FAKE_ART and delegate
# every store verb to the real binary, so the code under test is real
# except for the network.
cat > "$T/bin/bank" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
REAL="${REBUCK2_BIN:-rebuck2}"
_meta() { jq -r "$2" "$FAKE_ART/.meta/$1.json" 2>/dev/null || true; }
case "${1:-}" in
  gh-list)
    name="$2"; lineage="$3"
    # Injected lookup failure: a flake must not read as "absent".
    [ -z "${FAKE_FAIL_NAME:-}" ] || [ "$name" != "$FAKE_FAIL_NAME" ] || {
      echo "fake bank: injected failure for $name" >&2; exit 1; }
    [ -d "$FAKE_ART/$name" ] || exit 0
    # '-' = any lineage: containers are trusted via the manifest naming
    # them, not on their own provenance.
    [ "$lineage" = "-" ] \
      || [ "$(_meta "$name" .workflow_run.head_branch)" = "$lineage" ] || exit 0
    printf '%s\t%s\t%s\n' "$name" "$name" "$(_meta "$name" .created_at)" ;;
  gh-list-prefix)
    prefix="$2"; lineage="$3"
    for d in "$FAKE_ART"/*/; do
      n=$(basename "$d")
      case "$n" in "$prefix"*) ;; *) continue ;; esac
      [ "$(_meta "$n" .workflow_run.head_branch)" = "$lineage" ] || continue
      printf '%s\t%s\t%s\n' "$n" "$n" "$(_meta "$n" .created_at)"
    done ;;
  gh-download)
    rm -rf "${3:?}" && mkdir -p "$3" && cp -R "$FAKE_ART/$2/." "$3/" ;;
  *) exec "$REAL" bank "$@" ;;
esac
SHIM
chmod +x "$T/bin/bank"
export CAS_BANK_TOOL="$T/bin/bank"
export PATH="$T/bin:$PATH"
export CAS_LINEAGE=test-lineage GITHUB_REPOSITORY=fake/fake

publish_to_fake() { # <name> <src_dir> - stand-in for actions/upload-artifact
  local name="$1" src="$2" seq
  seq=$(( $(cat "$FAKE_ART/.seq" 2>/dev/null || echo 0) + 1 ))
  echo "$seq" > "$FAKE_ART/.seq"
  rm -rf "${FAKE_ART:?}/$name"
  cp -R "$src" "$FAKE_ART/$name"
  jq -n --arg name "$name" \
    --arg created "$(printf '%sT00:00:00.%06dZ' "$(date -u +%Y-%m-%d)" "$seq")" \
    --arg branch "$CAS_LINEAGE" \
    '{id: $name, name: $name, created_at: $created, expired: false,
      workflow_run: {id: 1, repository_id: 1, head_repository_id: 1,
                     head_branch: $branch}}' > "$FAKE_ART/.meta/$name.json"
}

mkb() { mkdir -p "$1/cas/${2:0:2}"; printf '%s' "$3" > "$1/cas/${2:0:2}/$2"; }

# work <store> <role> <run> <shard|-> [absorb] - restore then publish
work() {
  local store="$1" role="$2" run="$3" shard="$4" absorb="${5:-}" rc=0
  local wk="$T/wk-$run-$role"
  rc=0; ABSORB_SPILLS="$absorb" BANK_WORK="$wk" \
    ci/cas-bank-restore.sh "$store" "$shard" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || fail "restore rc=$rc"
  BANK_WORK="$wk" GITHUB_RUN_ID="$run" \
    ci/cas-bank-publish.sh "$store" "$role" "$shard"
}
up() { # up <run> <role> <what...> - "upload" publish outputs to FAKE_ART
  local run="$1" role="$2"
  local wk="$T/wk-$run-$role"; shift 2
  local w
  for w in "$@"; do
    case "$w" in
      container) publish_to_fake "cas-segs-$CAS_LINEAGE-$run-$role" \
        "$wk/bank-container" ;;
      spill) publish_to_fake "cas-spill-$CAS_LINEAGE-$run-$role" \
        "$wk/bank-spill" ;;
    esac
  done
}
up_manifest() { # <run> <role> <shard>
  publish_to_fake "cas-manifest-$CAS_LINEAGE-r$3" \
    "$T/wk-$1-$2/bank-manifest-out"
}

# ── lap 0: an established r0 bank (this run's bootstrap source) ─────
G="$T/lap0-r0"
mkb "$G" 00go1d99 "gold"
ci/cas-bank.sh pack_segments "$G" /dev/null "$T/gsegs" > "$T/gsegs.names"
gseg=$(cat "$T/gsegs.names")
mkdir -p "$T/gcontainer/$gseg"
cp "$T/gsegs/$gseg/bulk.tar.zst" "$T/gcontainer/$gseg/"
jq -c --arg a "cas-segs-$CAS_LINEAGE-50-w0" '. + {artifact: $a}' \
  "$T/gsegs/$gseg/meta.json" > "$T/gsegs/$gseg/meta.json.tmp" \
  && mv "$T/gsegs/$gseg/meta.json.tmp" "$T/gsegs/$gseg/meta.json"
ci/cas-bank.sh write_manifest "$CAS_LINEAGE" 50-1 - - 50 - "$T/gsegs" "$T/gman"
publish_to_fake "cas-segs-$CAS_LINEAGE-50-w0" "$T/gcontainer"
publish_to_fake "cas-manifest-$CAS_LINEAGE-r0" "$T/gman"
echo "ok - lap0: r0 manifest staged (bootstrap source)"

# ── lap 1: w1 owns shard 0; in-range blobs bank, out-of-range spills ─
W1="$T/lap1-w1"
work "$W1" w1 100 0   # seeds 00go1d99 from r0's established manifest
[ -f "$W1/cas/00/00go1d99" ] || fail "lap1: banked blob not seeded"
mkb "$W1" 0aaa0001 "in-a"
mkb "$W1" 1bbb0002 "in-b"
mkb "$W1" 2ccc0003 "out-of-range"
BANK_WORK="$T/wk-100-w1" GITHUB_RUN_ID=100 ci/cas-bank-publish.sh "$W1" w1 0
up 100 w1 container spill; up_manifest 100 w1 0
r0=$(jq -r .generation "$FAKE_ART/cas-manifest-$CAS_LINEAGE-r0/manifest.json")
[ "$r0" = "100-1" ] || fail "lap1: r0 generation $r0"
zstd -dq -c "$FAKE_ART/cas-manifest-$CAS_LINEAGE-r0/blobs.txt.zst" \
  | grep -q 0aaa0001 || fail "lap1: in-range blob not in r0 manifest"
zstd -dq -c "$FAKE_ART/cas-manifest-$CAS_LINEAGE-r0/blobs.txt.zst" \
  | grep -q 2ccc0003 && fail "lap1: out-of-range blob leaked into r0"
zstd -dq -c "$FAKE_ART/cas-spill-$CAS_LINEAGE-100-w1"/cas-seg-*/blobs.txt.zst \
  | grep -q 2ccc0003 || fail "lap1: spill missing out-of-range blob"
echo "ok - lap1: range banked, foreign blob spilled"

# ── lap 2: w2 owns shard 1 (prefixes 2,3) - absorbs w1's spill ──────
W2="$T/lap2-w2"
work "$W2" w2 200 1 1  # ABSORB_SPILLS=1
[ -f "$W2/cas/2c/2ccc0003" ] || fail "lap2: spill blob not absorbed"
up 200 w2 container; up_manifest 200 w2 1
zstd -dq -c "$FAKE_ART/cas-manifest-$CAS_LINEAGE-r1/blobs.txt.zst" \
  | grep -q 2ccc0003 || fail "lap2: absorbed blob not banked in r1"
echo "ok - lap2: spill absorbed on read, banked by its range owner"

# ── lap 3: straggler - container lands, manifest upload never runs ──
W3="$T/lap3-w1"
work "$W3" w1 300 0
mkb "$W3" 0ddd0004 "straggle"
BANK_WORK="$T/wk-300-w1" GITHUB_RUN_ID=300 ci/cas-bank-publish.sh "$W3" w1 0
up 300 w1 container   # NOT manifest - death between the two steps
r0=$(jq -r .generation "$FAKE_ART/cas-manifest-$CAS_LINEAGE-r0/manifest.json")
[ "$r0" = "100-1" ] || fail "lap3: torn publish moved r0 HEAD to $r0"
rc=0; BANK_WORK="$T/wk-check" ci/cas-bank-restore.sh "$(mktemp -d)" "-" || rc=$?
[ "$rc" -eq 0 ] || fail "lap3: check restore rc=$rc"
grep -q 0ddd0004 "$T/wk-check/bank-blobs.txt" \
  && fail "lap3: unreferenced straggler blob in the union"
echo "ok - lap3: torn publish leaves old manifest as HEAD, blob re-packs"

# ── lap 4: subset restore - own range only ──────────────────────────
W4="$T/lap4-w1"
work "$W4" w1b 400 0
for b in 00go1d99 0aaa0001 1bbb0002; do
  [ -f "$W4/cas/${b:0:2}/$b" ] || fail "lap4: missing own-range blob $b"
done
[ -f "$W4/cas/2c/2ccc0003" ] && fail "lap4: foreign range blob seeded"
[ -f "$W4/cas/0d/0ddd0004" ] && fail "lap4: unreferenced straggler blob seeded"
echo "ok - lap4: prefix-subset restore, referenced blobs only"

# ── lap 5: ordinary delta lap - history chains, new blob banks ──────
W5="$T/lap5-w1"
work "$W5" w1c 500 0
[ -f "$W5/cas/00/00go1d99" ] || fail "lap5: bootstrap blob lost from r0"
mkb "$W5" 0e5e0005 "new"
BANK_WORK="$T/wk-500-w1c" GITHUB_RUN_ID=500 ci/cas-bank-publish.sh "$W5" w1c 0
jq -e --arg s "$gseg" '.segments[] | select(.name == $s)' \
  "$T/wk-500-w1c/bank-manifest-out/manifest.json" > /dev/null \
  || fail "lap5: delta manifest dropped an inherited segment"
zstd -dq -c "$T/wk-500-w1c/bank-manifest-out/blobs.txt.zst" \
  | grep -q 0e5e0005 || fail "lap5: new blob missing from the new manifest"
up 500 w1c container; up_manifest 500 w1c 0
echo "ok - lap5: delta lap chains history and banks the new blob"

# ── lap 6: own-manifest lookup FAILURE demotes to spill-only ────────
# A flake must not read as "absent": a thin manifest would clobber the
# fat one via newest-wins.
W6="$T/lap6-w1"
FAKE_FAIL_NAME="cas-manifest-$CAS_LINEAGE-r0" work "$W6" w1d 600 0
mkb "$W6" 0f0f0006 "flaky-lap"
FAKE_FAIL_NAME="cas-manifest-$CAS_LINEAGE-r0" BANK_WORK="$T/wk-600-w1d" \
  GITHUB_RUN_ID=600 ci/cas-bank-publish.sh "$W6" w1d 0
[ ! -d "$T/wk-600-w1d/bank-manifest-out" ] \
  || fail "lap6: staged a manifest despite unknown own-range state"
zstd -dq -c "$T/wk-600-w1d/bank-spill"/cas-seg-*/blobs.txt.zst \
  | grep -q 0f0f0006 || fail "lap6: new blob not spilled on demotion"
r0gen=$(jq -r .generation "$FAKE_ART/cas-manifest-$CAS_LINEAGE-r0/manifest.json")
[ "$r0gen" = "500-1" ] || fail "lap6: r0 HEAD moved to $r0gen"
echo "ok - lap6: lookup flake -> spill-only, fat manifest stands"

# ── lap 7: dice bank round-trip (bootstrap + delta + reload) ────────
export DICE_SEED="rev1-sweep-treehash1"
DS="$T/dice-sweep"
mkdir -p "$DS/db"
sqlite3 "$DS/db/pagable.2.db" \
  "CREATE TABLE pagable_data (key_lo INTEGER NOT NULL,
     key_hi INTEGER NOT NULL, value BLOB NOT NULL,
     UNIQUE(key_hi, key_lo));
   INSERT INTO pagable_data VALUES(18, 7, X'AA11');"
printf 'skeleton-gen-1' > "$DS/graph.meta"
rc=0; BANK_WORK="$T/dwk1" ci/dice-bank-restore.sh "$T/dice-cold" || rc=$?
[ "$rc" -eq 3 ] || fail "dice lap7: expected cold bank, rc=$rc"
BANK_WORK="$T/dwk1" GITHUB_RUN_ID=700 ci/dice-bank-publish.sh "$DS"
publish_to_fake "cas-dice-segs-$CAS_LINEAGE-700" "$T/dwk1/dice-container"
dm="cas-manifest-$CAS_LINEAGE-dice-$(printf '%s' "$DICE_SEED" | shasum -a 256 | cut -c1-8)"
publish_to_fake "$dm" "$T/dwk1/dice-manifest-out"

DS2="$T/dice-sweep2"
BANK_WORK="$T/dwk2" ci/dice-bank-restore.sh "$DS2"
[ "$(cat "$DS2/graph.meta")" = "skeleton-gen-1" ] \
  || fail "dice lap7: graph.meta did not round-trip"
got=$(sqlite3 "$DS2/db/pagable.2.db" "SELECT hex(value) FROM pagable_data;")
[ "$got" = "AA11" ] || fail "dice lap7: row did not round-trip: $got"
# delta lap: one new row, publish, reload sees both
sqlite3 "$DS2/db/pagable.9.db" \
  "INSERT INTO pagable_data VALUES(25, 8, X'BB22');"
printf 'skeleton-gen-2' > "$DS2/graph.meta"
BANK_WORK="$T/dwk2" GITHUB_RUN_ID=701 ci/dice-bank-publish.sh "$DS2"
n=$(zstd -dq -c "$T/dwk2/dice-container"/cas-seg-*/rows.txt.zst | wc -l | tr -d ' ')
[ "$n" -eq 1 ] || fail "dice lap7: delta should be 1 row, got $n"
publish_to_fake "cas-dice-segs-$CAS_LINEAGE-701" "$T/dwk2/dice-container"
publish_to_fake "$dm" "$T/dwk2/dice-manifest-out"
DS3="$T/dice-sweep3"
BANK_WORK="$T/dwk3" ci/dice-bank-restore.sh "$DS3"
[ "$(cat "$DS3/graph.meta")" = "skeleton-gen-2" ] \
  || fail "dice lap7: newest skeleton should win"
total=$(( $(sqlite3 "$DS3/db/pagable.2.db" "SELECT count(*) FROM pagable_data;") \
        + $(sqlite3 "$DS3/db/pagable.9.db" "SELECT count(*) FROM pagable_data;") ))
[ "$total" -eq 2 ] || fail "dice lap7: reload row count $total"
unset DICE_SEED
echo "ok - lap7: dice bank bootstrap, delta, and reload"

# ── lap 8: the range owner compacts in its own teardown ─────────────
# No separate workflow: the owner's store already holds the range's
# full view, so compaction = publish-with-empty-diff-base, stamped
# full, manifest referencing only the fresh packs. Then the trigger
# must quiesce.
W8="$T/lap8-w1"
work "$W8" w1e 800 0
pre=$(zstd -dq -c "$FAKE_ART/cas-manifest-$CAS_LINEAGE-r0/blobs.txt.zst" | sort -u)
BANK_WORK="$T/wk-800-w1e" GITHUB_RUN_ID=800 COMPACT_MIN_MB=0 \
  ci/cas-bank-publish.sh "$W8" w1e 0
jq -e '[.segments[] | .full == true] | all' \
  "$T/wk-800-w1e/bank-manifest-out/manifest.json" > /dev/null \
  || fail "lap8: compacted manifest has non-full segments"
post=$(zstd -dq -c "$T/wk-800-w1e/bank-manifest-out/blobs.txt.zst" | sort -u)
[ "$pre" = "$post" ] || fail "lap8: compaction changed the blob set"
up 800 w1e container; up_manifest 800 w1e 0
res=$(COMPACT_MIN_MB=0 ci/cas-bank.sh needs_compaction \
  "$FAKE_ART/cas-manifest-$CAS_LINEAGE-r0/manifest.json")
[ "$res" = "no" ] || fail "lap8: trigger did not quiesce: $res"
# And the compacted range still restores whole - WITHOUT re-merging
# the global slice (a full-packed range is self-sufficient; the slice
# re-merge re-fired compaction every lap and doubled seed downloads).
W8b="$T/lap8-verify"
BANK_WORK="$T/wk-801" ci/cas-bank-restore.sh "$W8b" 0
for b in 00go1d99 0aaa0001 1bbb0002 0e5e0005; do
  [ -f "$W8b/cas/${b:0:2}/$b" ] || fail "lap8: post-compact restore missing $b"
done
nd=$(jq '[.segments[] | select(.full != true)] | length' \
  "$T/wk-801/own-range/manifest.json")
[ "$nd" -eq 0 ] \
  || fail "lap8: $nd delta segments re-merged into a full-packed head"
echo "ok - lap8: owner-side compaction, blob set preserved, trigger quiesces"

# ── lap 9: autotuned trigger - measured delta overhead over budget ──
W9="$T/lap9-w1"
BANK_WORK="$T/wk-900" ci/cas-bank-restore.sh "$W9" 0
echo 999 > "$T/wk-900/.delta-restore-secs"
out=$(BANK_WORK="$T/wk-900" GITHUB_RUN_ID=900 \
  ci/cas-bank-publish.sh "$W9" w1f 0)
echo "$out" | grep -q 'COMPACTING (restore-overhead 999s' \
  || fail "lap9: measured overhead did not trigger compaction: $out"
# and under budget stays quiet
W9b="$T/lap9b-w1"
BANK_WORK="$T/wk-901" ci/cas-bank-restore.sh "$W9b" 0
echo 3 > "$T/wk-901/.delta-restore-secs"
out=$(BANK_WORK="$T/wk-901" GITHUB_RUN_ID=901 \
  ci/cas-bank-publish.sh "$W9b" w1g 0)
echo "$out" | grep -q 'COMPACTING' \
  && fail "lap9: under-budget overhead compacted anyway"
echo "ok - lap9: restore-overhead autotune fires over budget, quiet under"

# ── lap 10: AC bank - role-authored publish, union restore, order ───
# Every node banks the rows it authored; the driver reads the union.
acrow() { # <store> <relpath> <content>
  mkdir -p "$(dirname "$1/$2")"; printf '%s' "$3" > "$1/$2"
}
# AC RESTORE now lives in rebuck2 and talks to the artifact API directly,
# so it is covered by rebuck2/tests/ac_restore.rs against a stub server -
# including the (lineage, run, role) apply order and inheritance, which
# is what the laps below used to prove. What remains shell is PUBLISH, so
# these laps fabricate the state a restore would have left instead.
ac_restored() { # <store> <work> <own-head|-> <rows-from|-> - fake a restore
  # own-head is THIS role's manifest (publish chains its generation from
  # it); rows-from is the union the diff base is built out of, which for
  # the driver includes every other role's. Conflating them makes the
  # driver inherit a worker's segments as if it had packed them.
  local store="$1" work="$2" head="$3" rows="$4"
  mkdir -p "$work" "$store"
  rm -rf "$work/own-ac" "$work/.ac-own-unknown"
  if [ "$head" != "-" ] && [ -d "$FAKE_ART/$head" ]; then
    mkdir -p "$work/own-ac"
    cp "$FAKE_ART/$head/manifest.json" "$FAKE_ART/$head/blobs.txt.zst" \
      "$work/own-ac/"
  fi
  : > "$work/ac-banked-rows.txt"
  local m seg c
  for m in $rows; do
    [ "$m" != "-" ] && [ -d "$FAKE_ART/$m" ] || continue
    zstd -dqc "$FAKE_ART/$m/blobs.txt.zst" >> "$work/ac-banked-rows.txt"
    for seg in $(jq -r '.segments[].name' "$FAKE_ART/$m/manifest.json"); do
      c=$(jq -r --arg s "$seg" '.segments[]|select(.name==$s)|.artifact' \
        "$FAKE_ART/$m/manifest.json")
      [ -d "$FAKE_ART/$c/$seg" ] || continue
      zstd -dqc "$FAKE_ART/$c/$seg/bulk.tar.zst" | tar -x -C "$store"
    done
  done
  sort -u "$work/ac-banked-rows.txt" -o "$work/ac-banked-rows.txt"
}
A1=$(printf 'a%.0s' $(seq 64)); A2=$(printf 'b%.0s' $(seq 64))
AC_W="$T/ac-w0"
ac_restored "$AC_W" "$T/acwk-w0" - -
acrow "$AC_W" "ac/$A1" "worker-row-v1"
acrow "$AC_W" "ac/$A2" "worker-only-row"
BANK_WORK="$T/acwk-w0" GITHUB_RUN_ID=1000 \
  ci/ac-bank-publish.sh "$AC_W" linux-w0
publish_to_fake "cas-ac-segs-$CAS_LINEAGE-1000-linux-w0" "$T/acwk-w0/ac-container"
publish_to_fake "cas-manifest-$CAS_LINEAGE-ac-linux-w0" \
  "$T/acwk-w0/ac-manifest-out"
echo "ok - lap10: worker banked its authored rows"

# Driver, same lap: it normalizes A1, so its row must WIN on restore.
AC_D="$T/ac-driver"
ac_restored "$AC_D" "$T/acwk-drv" - "cas-manifest-$CAS_LINEAGE-ac-linux-w0"
[ "$(cat "$AC_D/ac/$A1")" = "worker-row-v1" ] \
  || fail "ac: driver did not seed the worker's row"
acrow "$AC_D" "ac/$A1" "driver-normalized"
acrow "$AC_D" "acn/cd/$(printf 'c%.0s' $(seq 64))" "canon-row"
BANK_WORK="$T/acwk-drv" GITHUB_RUN_ID=1000 \
  ci/ac-bank-publish.sh "$AC_D" driver
n=$(zstd -dq -c "$T/acwk-drv/ac-segs"/cas-seg-*/blobs.txt.zst 2>/dev/null \
  | wc -l | tr -d ' ' || true)
publish_to_fake "cas-ac-segs-$CAS_LINEAGE-1000-driver" "$T/acwk-drv/ac-container"
publish_to_fake "cas-manifest-$CAS_LINEAGE-ac-driver" \
  "$T/acwk-drv/ac-manifest-out"
zstd -dq -c "$T/acwk-drv/ac-manifest-out/blobs.txt.zst" | grep -q "^ac/$A2 " \
  && fail "ac: driver re-banked a row the worker already banked"
echo "ok - lap10: driver banked only what no role had (union diff)"

# Next lap's driver: union restore, driver-last order resolves the clash.
AC_D2="$T/ac-driver2"
ac_restored "$AC_D2" "$T/acwk-drv2" "cas-manifest-$CAS_LINEAGE-ac-driver" "cas-manifest-$CAS_LINEAGE-ac-linux-w0 cas-manifest-$CAS_LINEAGE-ac-driver"
[ "$(cat "$AC_D2/ac/$A1")" = "driver-normalized" ] \
  || fail "ac: driver row not restored from its own manifest"
[ -f "$AC_D2/acn/cd/$(printf 'c%.0s' $(seq 64))" ] \
  || fail "ac: canonical row missing"
echo "ok - lap10: driver rows round-trip (ordering covered in rust)"

# Warm lap: nothing changed -> nothing staged.
BANK_WORK="$T/acwk-drv2" GITHUB_RUN_ID=1001 \
  ci/ac-bank-publish.sh "$AC_D2" driver
[ ! -d "$T/acwk-drv2/ac-container" ] \
  || fail "ac: unchanged AC staged a container anyway"
echo "ok - lap10: unchanged AC publishes nothing"

# Mutation lap: same name, new content re-banks and wins on reload.
acrow "$AC_D2" "ac/$A1" "driver-v3"
BANK_WORK="$T/acwk-drv2" GITHUB_RUN_ID=1002 \
  ci/ac-bank-publish.sh "$AC_D2" driver
publish_to_fake "cas-ac-segs-$CAS_LINEAGE-1002-driver" "$T/acwk-drv2/ac-container"
publish_to_fake "cas-manifest-$CAS_LINEAGE-ac-driver" \
  "$T/acwk-drv2/ac-manifest-out"
AC_D3="$T/ac-driver3"
ac_restored "$AC_D3" "$T/acwk-drv3" "cas-manifest-$CAS_LINEAGE-ac-driver" "cas-manifest-$CAS_LINEAGE-ac-linux-w0 cas-manifest-$CAS_LINEAGE-ac-driver"
[ "$(cat "$AC_D3/ac/$A1")" = "driver-v3" ] \
  || fail "ac: mutated row did not win: $(cat "$AC_D3/ac/$A1")"
rows=$(zstd -dq -c "$T/acwk-drv2/ac-manifest-out/blobs.txt.zst" \
  | grep -c "^ac/$A1 ")
[ "$rows" -eq 1 ] || fail "ac: row list kept $rows entries for one path"
echo "ok - lap10: content mutation re-banks, newest wins, list stays flat"

# Failure rows never reach the pool (the poison class), flat ac/ too.
acrow "$AC_D3" "ac/$(printf 'f%.0s' $(seq 64))" "$(printf '\x20\x01')"
BANK_WORK="$T/acwk-drv3" GITHUB_RUN_ID=1003 \
  ci/ac-bank-publish.sh "$AC_D3" driver
[ ! -d "$T/acwk-drv3/ac-container" ] \
  || fail "ac: a failure row was staged for banking"
echo "ok - lap10: failure rows purged before they can be banked"

# Torn publish: container lands, manifest upload never runs.
AC_W2="$T/ac-w0b"
ac_restored "$AC_W2" "$T/acwk-w0b" "cas-manifest-$CAS_LINEAGE-ac-linux-w0" "cas-manifest-$CAS_LINEAGE-ac-linux-w0"
acrow "$AC_W2" "ac/$(printf 'd%.0s' $(seq 64))" "straggler"
BANK_WORK="$T/acwk-w0b" GITHUB_RUN_ID=1100 \
  ci/ac-bank-publish.sh "$AC_W2" linux-w0
publish_to_fake "cas-ac-segs-$CAS_LINEAGE-1100-linux-w0" "$T/acwk-w0b/ac-container"
gen=$(jq -r .generation \
  "$FAKE_ART/cas-manifest-$CAS_LINEAGE-ac-linux-w0/manifest.json")
[ "$gen" = "1000-1" ] || fail "ac: torn publish moved the role HEAD to $gen"
echo "ok - lap10: torn AC publish leaves the old role manifest as HEAD"

# Lookup flake on the own manifest: stage nothing at all.
AC_W3="$T/ac-w0c"
ac_restored "$AC_W3" "$T/acwk-w0c" "cas-manifest-$CAS_LINEAGE-ac-linux-w0" "cas-manifest-$CAS_LINEAGE-ac-linux-w0"
# A lookup flake leaves the own state UNKNOWN; publish must not stage.
touch "$T/acwk-w0c/.ac-own-unknown"
acrow "$AC_W3" "ac/$(printf 'e%.0s' $(seq 64))" "flaky-lap"
BANK_WORK="$T/acwk-w0c" GITHUB_RUN_ID=1200 \
  ci/ac-bank-publish.sh "$AC_W3" linux-w0
[ ! -d "$T/acwk-w0c/ac-manifest-out" ] \
  || fail "ac: staged a manifest despite unknown own state"
echo "ok - lap10: own-manifest flake -> stage nothing, fat manifest stands"

# ── lap 11: a child lineage inherits its parent's blob bank ─────────
# A branch/PR is its own lineage. Without inheritance its first lap is
# a full cold re-derivation; with it, the trunk's bank is warm and only
# the branch's own new blobs are banked - under the CHILD's manifest,
# never the parent's (the cache-poisoning boundary).
PARENT="$CAS_LINEAGE"
export CAS_PARENT_LINEAGE="$PARENT"
export CAS_LINEAGE=child-branch
W11="$T/lap11-child"
rc=0; BANK_WORK="$T/wk-1100" ci/cas-bank-restore.sh "$W11" 0 || rc=$?
[ "$rc" -eq 0 ] || fail "lap11: child restore rc=$rc (cold - no inheritance?)"
for b in 00go1d99 0aaa0001 0e5e0005; do
  [ -f "$W11/cas/${b:0:2}/$b" ] || fail "lap11: parent blob $b not inherited"
done
grep -q 0aaa0001 "$T/wk-1100/bank-blobs.txt" \
  || fail "lap11: parent blob missing from the child's union"
mkb "$W11" 0c1d0007 "child-only"
BANK_WORK="$T/wk-1100" GITHUB_RUN_ID=1100 ci/cas-bank-publish.sh "$W11" c0 0
# The staged manifest IS what gets published, so assert there: a child
# with no own history should reference exactly its own new blob.
got=$(zstd -dq -c "$T/wk-1100/bank-manifest-out/blobs.txt.zst" | tr -d '[:space:]')
[ "$got" = "0c1d0007" ] || fail "lap11: child re-banked inherited blobs: $got"
[ "$(jq '.segments|length' "$T/wk-1100/bank-manifest-out/manifest.json")" -eq 1 ] \
  || fail "lap11: child manifest references inherited segments"
[ "$(jq -r .parent_lineage "$T/wk-1100/bank-manifest-out/manifest.json")" \
  = "$PARENT" ] || fail "lap11: child manifest records no parent"
pgen=$(jq -r .generation "$FAKE_ART/cas-manifest-$PARENT-r0/manifest.json")
[ "$pgen" = "800-1" ] || fail "lap11: child publish moved the PARENT head to $pgen"
echo "ok - lap11: child lineage inherits, banks only its own, parent untouched"

# ── lap 12: AC parentage, and the child's row wins ──────────────────
# Deliberately give the child a LOWER run id than the parent's last AC
# lap: ordering must be (lineage, run), not run alone, or the trunk's
# stale row would beat the branch's rebuild of the same action.
AC_C="$T/ac-child"
# Inheritance itself is covered in rust; here the child simply starts
# from the parent's banked state and must publish only its own change.
ac_restored "$AC_C" "$T/acwk-child" - "cas-manifest-$PARENT-ac-linux-w0 cas-manifest-$PARENT-ac-driver"
grep -q "^ac/$A1 " "$T/acwk-child/ac-banked-rows.txt" \
  || fail "lap12: parent rows missing from the child's diff base"
acrow "$AC_C" "ac/$A1" "child-v1"
BANK_WORK="$T/acwk-child" GITHUB_RUN_ID=900 \
  ci/ac-bank-publish.sh "$AC_C" driver
rows=$(zstd -dq -c "$T/acwk-child/ac-manifest-out/blobs.txt.zst")
n=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
[ "$n" -eq 1 ] || fail "lap12: child banked $n rows, expected just the changed one: $rows"
printf '%s' "$rows" | grep -q "^ac/$A1 " \
  || fail "lap12: child banked the wrong row: $rows"
[ "$(jq -r .parent_lineage "$T/acwk-child/ac-manifest-out/manifest.json")" \
  = "$PARENT" ] || fail "lap12: child AC manifest records no parent"
publish_to_fake "cas-ac-segs-$CAS_LINEAGE-900-driver" "$T/acwk-child/ac-container"
publish_to_fake "cas-manifest-$CAS_LINEAGE-ac-driver" "$T/acwk-child/ac-manifest-out"
AC_C2="$T/ac-child2"
ac_restored "$AC_C2" "$T/acwk-child2" "cas-manifest-$CAS_LINEAGE-ac-driver" "cas-manifest-$CAS_LINEAGE-ac-driver"
[ "$(cat "$AC_C2/ac/$A1")" = "child-v1" ] \
  || fail "lap12: the child's own banked row did not round-trip"
echo "ok - lap12: child banks only its change (ordering covered in rust)"
export CAS_LINEAGE="$PARENT"
unset CAS_PARENT_LINEAGE

echo "PASS: integration"
