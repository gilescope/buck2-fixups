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
PARENT="$CAS_LINEAGE"

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

# ── laps 0-6 moved to rebuck2/tests/cas_bank.rs ─────────────────────
# The CAS restore/publish choreography lives in `rebuck2 bank` now, so a
# fake `gh` on PATH can no longer intercept it - the API call happens
# inside the binary. Those laps are Rust tests against a stub server,
# which drive the real client, the real zip reader and the real ordering:
# range-vs-spill split, the own-lookup flake demoting to spill-only, and
# a child lineage inheriting the trunk. What is left here is what is
# still shell.

# ── lap 7: dice pack/merge round-trip (publish staging) ─────────────
# Restore moved into `rebuck2 bank dice-restore` and talks to the
# artifact API from inside the binary, so a fake `gh` cannot intercept
# it. The pack/merge halves are covered by ci/cas-bank-test.sh against
# the same Rust; what is worth keeping here is that a publish stages a
# container and a manifest a restore could actually read.
export DICE_SEED="rev1-sweep-treehash1"
DS="$T/dice-sweep"
mkdir -p "$DS/db"
sqlite3 "$DS/db/pagable.2.db" \
  "CREATE TABLE pagable_data (key_lo INTEGER NOT NULL,
     key_hi INTEGER NOT NULL, value BLOB NOT NULL,
     UNIQUE(key_hi, key_lo));
   INSERT INTO pagable_data VALUES(18, 7, X'AA11');"
printf 'skeleton-gen-1' > "$DS/graph.meta"
BANK_WORK="$T/dwk1" ci/cas-bank.sh _tool dice-publish \
  "$DS" "$CAS_LINEAGE" "$DICE_SEED" 700 "${CAS_PARENT_LINEAGE:--}"
[ -d "$T/dwk1/dice-container" ] || fail "dice lap7: no container staged"
[ -f "$T/dwk1/dice-manifest-out/manifest.json" ] \
  || fail "dice lap7: no manifest staged"
[ -f "$T/dwk1/dice-manifest-out/graph.meta.zst" ] \
  || fail "dice lap7: the skeleton must ride the manifest"
rows=$(zstd -dqc "$T/dwk1/dice-container"/cas-seg-*/rows.txt.zst | wc -l | tr -d ' ')
[ "$rows" -eq 1 ] || fail "dice lap7: staged $rows rows, expected 1"
# And a fresh store merges that segment back to the same key set.
ci/cas-bank.sh dice_merge "$T/dice-back/db" "$T/dwk1/dice-container"/cas-seg-*
diff <(ci/cas-bank.sh dice_keys "$DS/db") \
     <(ci/cas-bank.sh dice_keys "$T/dice-back/db") \
  || fail "dice lap7: merged key set diverged"
unset DICE_SEED
echo "ok - lap7: dice publish stages a readable container + manifest"

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
BANK_WORK="$T/acwk-w0" ci/cas-bank.sh _tool ac-publish \
  "$AC_W" linux-w0 "$CAS_LINEAGE" 1000 "${CAS_PARENT_LINEAGE:--}"
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
BANK_WORK="$T/acwk-drv" ci/cas-bank.sh _tool ac-publish \
  "$AC_D" driver "$CAS_LINEAGE" 1000 "${CAS_PARENT_LINEAGE:--}"
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
BANK_WORK="$T/acwk-drv2" ci/cas-bank.sh _tool ac-publish \
  "$AC_D2" driver "$CAS_LINEAGE" 1001 "${CAS_PARENT_LINEAGE:--}"
[ ! -d "$T/acwk-drv2/ac-container" ] \
  || fail "ac: unchanged AC staged a container anyway"
echo "ok - lap10: unchanged AC publishes nothing"

# Mutation lap: same name, new content re-banks and wins on reload.
acrow "$AC_D2" "ac/$A1" "driver-v3"
BANK_WORK="$T/acwk-drv2" ci/cas-bank.sh _tool ac-publish \
  "$AC_D2" driver "$CAS_LINEAGE" 1002 "${CAS_PARENT_LINEAGE:--}"
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
BANK_WORK="$T/acwk-drv3" ci/cas-bank.sh _tool ac-publish \
  "$AC_D3" driver "$CAS_LINEAGE" 1003 "${CAS_PARENT_LINEAGE:--}"
[ ! -d "$T/acwk-drv3/ac-container" ] \
  || fail "ac: a failure row was staged for banking"
echo "ok - lap10: failure rows purged before they can be banked"

# Torn publish: container lands, manifest upload never runs.
AC_W2="$T/ac-w0b"
ac_restored "$AC_W2" "$T/acwk-w0b" "cas-manifest-$CAS_LINEAGE-ac-linux-w0" "cas-manifest-$CAS_LINEAGE-ac-linux-w0"
acrow "$AC_W2" "ac/$(printf 'd%.0s' $(seq 64))" "straggler"
BANK_WORK="$T/acwk-w0b" ci/cas-bank.sh _tool ac-publish \
  "$AC_W2" linux-w0 "$CAS_LINEAGE" 1100 "${CAS_PARENT_LINEAGE:--}"
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
BANK_WORK="$T/acwk-w0c" ci/cas-bank.sh _tool ac-publish \
  "$AC_W3" linux-w0 "$CAS_LINEAGE" 1200 "${CAS_PARENT_LINEAGE:--}"
[ ! -d "$T/acwk-w0c/ac-manifest-out" ] \
  || fail "ac: staged a manifest despite unknown own state"
echo "ok - lap10: own-manifest flake -> stage nothing, fat manifest stands"

# ── lap 12: AC parentage, and the child's row wins ──────────────────
# Deliberately give the child a LOWER run id than the parent's last AC
# lap: ordering must be (lineage, run), not run alone, or the trunk's
# stale row would beat the branch's rebuild of the same action.
export CAS_PARENT_LINEAGE="$PARENT"
export CAS_LINEAGE=child-branch
AC_C="$T/ac-child"
# Inheritance itself is covered in rust; here the child simply starts
# from the parent's banked state and must publish only its own change.
ac_restored "$AC_C" "$T/acwk-child" - "cas-manifest-$PARENT-ac-linux-w0 cas-manifest-$PARENT-ac-driver"
grep -q "^ac/$A1 " "$T/acwk-child/ac-banked-rows.txt" \
  || fail "lap12: parent rows missing from the child's diff base"
acrow "$AC_C" "ac/$A1" "child-v1"
BANK_WORK="$T/acwk-child" ci/cas-bank.sh _tool ac-publish \
  "$AC_C" driver "$CAS_LINEAGE" 900 "${CAS_PARENT_LINEAGE:--}"
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
