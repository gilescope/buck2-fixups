#!/usr/bin/env bash
# TEMPORARY: with the from_any_dir + cmd_script prelude fixes, check which
# windows expected-failures were only blocked by the cc-rs C-compile bug and now
# build. Bounded to the leaf native crates (+ backtrace, the other substrate
# blocker) so it can't OOM the runner like a full-rig sweep. Remove after the
# shrink is applied.
set -x
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

# round 2: dependents of the now-building C leaves + the wasmtime layer, to see
# which un-exclude vs which stay (via backtrace/aws-lc/openssl).
leaves="lz4 xz2 zip zstd zstd-safe rusqlite git2 onig aes-soft cpuid-bool"
vers="wasmtime-internal-cache-36 ittapi-sys-0.4 ittapi-0.4 sc-executor-wasmtime-0.45 sp-virtualization-0.2 sp-maybe-compressed-blob-11 sp-wasm-interface-25 sp-runtime-interface-35 sp-api-42 sp-inherents-42 sp-staking-44 sp-genesis-builder-0.23"
targets=""
for c in $leaves; do
  t=$(buck2 uquery "//third-party:$c" 2>/dev/null | head -1)
  [ -n "$t" ] && targets="$targets $t"
done
for t in $vers; do targets="$targets fixups//third-party:$t"; done
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
