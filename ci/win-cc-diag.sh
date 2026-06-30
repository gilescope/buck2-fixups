#!/usr/bin/env bash
# TEMPORARY diagnostic (windows x86_64): pin WHY cc-rs fails to produce the
# static lib when a buildscript compiles C under buck2's MSVC toolchain.
# Replays cc-rs's compile+archive through the real shims OUTSIDE the buildscript
# runner (which swallows stdout on failure), so we see everything. Remove once
# the prelude shim bug is fixed. Never fails the job.
set -x
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

echo "::group::buck2 build wasmtime-36 (-v5) — should SUCCEED with the from_any_dir fix"
buck2 build fixups//third-party:wasmtime-36 -v5 2>&1 | tee /tmp/wasmtime.log; rc=${PIPESTATUS[0]}
echo "WASMTIME-36 BUILD EXIT: $rc  (0 == fix works)"
echo "::endgroup::"

root="$(buck2 root --kind project 2>/dev/null)"; echo "buck root: $root"

cc_shim="$(find buck-out -name __cc_shim.bat -path '*wasmtime-36*' 2>/dev/null | head -1)"
ar_shim="$(find buck-out -name __ar_shim.bat -path '*wasmtime-36*' 2>/dev/null | head -1)"
cl_bat="$(find buck-out -name cl.bat -path '*__msvc_tools__*' 2>/dev/null | head -1)"
lib_bat="$(find buck-out -name lib.bat -path '*__msvc_tools__*' 2>/dev/null | head -1)"
echo "cc_shim=$cc_shim"; echo "ar_shim=$ar_shim"; echo "cl_bat=$cl_bat"; echo "lib_bat=$lib_bat"

echo "::group::wrapper .bat contents (cl.bat / lib.bat + the msvc tool json)"
for f in "$cl_bat" "$lib_bat"; do [ -n "$f" ] && { echo "==== $f ===="; cat "$f"; echo; }; done
find buck-out \( -name 'cl.exe.json' -o -name 'lib.exe.json' \) 2>/dev/null | head -2 | while read -r j; do
  echo "==== $j ===="; cat "$j"; echo
done
echo "::endgroup::"

# cc-rs hands the tools absolute paths (OUT_DIR is absolutized). Mirror that.
# PWD is the repo (buck) root during this CI step; keep paths relative to it.
mkdir -p diag
src="$(cygpath -w "$PWD/diag/t.c")"
obj="$(cygpath -w "$PWD/diag/t.obj")"
a="$(cygpath -w "$PWD/diag/libt.a")"
printf 'int diag_fn(void){return 7;}\n' > diag/t.c
echo "src=$src obj=$obj a=$a"

echo "::group::TEST A — inner cl.bat /c then lib.bat /out (bypass from_any_dir shim)"
"$cl_bat" /nologo /c /Fo"$obj" "$src"; echo "cl.bat exit=$?"
ls -la diag/t.obj 2>&1 || echo "NO t.obj"
"$lib_bat" /nologo /out:"$a" "$obj"; echo "lib.bat exit=$?"
ls -la diag/libt.a 2>&1 || echo "NO libt.a"
echo "::endgroup::"

echo "::group::TEST B — full shim chain: __cc_shim.bat then __ar_shim.bat (as cc-rs invokes)"
rm -f diag/t.obj diag/libt.a
"$cc_shim" /nologo /c /Fo"$obj" "$src"; echo "__cc_shim exit=$?"
ls -la diag/t.obj 2>&1 || echo "NO t.obj (shim compile failed)"
"$ar_shim" /nologo /out:"$a" "$obj"; echo "__ar_shim exit=$?"
ls -la diag/libt.a 2>&1 || echo "NO libt.a (shim archive failed)"
echo "::endgroup::"

echo "::group::TEST C — replay cc-rs family detection (why does it fall back to GNU?)"
# cc-rs detect_family_inner runs '$CC -E <probe.c>' and reads stdout for
# __clang__/__GNUC__ pragmas; accepts_cl_style_flags runs '$CC -?'. For cl.exe
# both should succeed -> Msvc. Capture exit + output of each through the shim.
printf '#ifdef __clang__\n#pragma message "clang"\n#endif\n#ifdef __GNUC__\n#pragma message "gcc"\n#endif\n' > diag/detect.c
probe="$(cygpath -w "$PWD/diag/detect.c")"
echo "--- C1: __cc_shim.bat -E <probe>  (detect_family_inner) ---"
"$cc_shim" -E "$probe" > diag/E.out 2> diag/E.err; echo "cc_shim -E exit=$?"
echo "  stdout bytes=$(wc -c < diag/E.out)  stderr bytes=$(wc -c < diag/E.err)"
echo "  --- stdout (first 25 lines) ---"; head -25 diag/E.out
echo "  --- stderr (first 25 lines) ---"; head -25 diag/E.err
echo "--- C2: __cc_shim.bat -?  (accepts_cl_style_flags) ---"
"$cc_shim" '-?' > diag/help.out 2> diag/help.err; echo "cc_shim -? exit=$?"
echo "  stdout bytes=$(wc -c < diag/help.out)  stderr bytes=$(wc -c < diag/help.err)"
echo "  --- stdout (first 5 lines) ---"; head -5 diag/help.out
echo "  --- stderr (first 5 lines) ---"; head -5 diag/help.err
echo "::endgroup::"

echo "::group::host MSVC sanity"
which cl.exe lib.exe python.exe 2>/dev/null || true
echo "::endgroup::"
rm -rf diag
exit 0
