#!/usr/bin/env bash
# TEMPORARY: with the from_any_dir + cmd_script prelude fixes, check which
# windows expected-failures were only blocked by the cc-rs C-compile bug and now
# build. Bounded to the leaf native crates (+ backtrace, the other substrate
# blocker) so it can't OOM the runner like a full-rig sweep. Remove after the
# shrink is applied.
set -x
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

leaves="secp256k1-sys zstd-sys lz4-sys lzma-sys openssl-sys libgit2-sys libsqlite3-sys aws-lc-sys ring backtrace psm onig_sys rdkafka-sys"
targets=""
for c in $leaves; do
  t=$(buck2 uquery "//third-party:$c" 2>/dev/null | head -1)
  [ -n "$t" ] && targets="$targets $t"
done
echo "targets:$targets"

report="$(mktemp)"
# shellcheck disable=SC2086
buck2 build --keep-going --build-report "$report" $targets 2>&1 | tail -8 || true

python - "$report" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
res = r.get("results", {})
print("=== per-crate result (SUCCESS => remove from expected-failures) ===")
for k in sorted(res):
    print(f"{res[k].get('success')}\t{k.split('#')[0]}")
EOF
exit 0
