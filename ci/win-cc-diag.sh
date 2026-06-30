#!/usr/bin/env bash
# TEMPORARY diagnostic (windows x86_64): capture WHY cc-rs fails to produce the
# static lib when a buildscript compiles C under buck2's MSVC toolchain
# (wasmtime helpers.c / secp256k1 / zstd / aws-lc all share this). Remove once
# the prelude shim bug is pinned + fixed. Never fails the job (informational).
set -x
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

echo "::group::buck2 build wasmtime-36 (-v5, expected to fail)"
buck2 build fixups//third-party:wasmtime-36 -v5 2>&1 | tee /tmp/wasmtime.log || true
echo "::endgroup::"

echo "::group::generated shim .bat files for the wasmtime buildscript"
# from_any_dir-wrapped CC/CXX/AR/LD shims: the suspected culprit (marker rewrite
# / clang flags reaching cl.exe). Print verbatim.
find buck-out -name '__*_shim.bat' -path '*wasmtime-36*' 2>/dev/null | while read -r f; do
  echo "==== $f ===="; cat "$f"; echo
done
echo "::endgroup::"

echo "::group::buildscript-run OUT_DIR — did the archive get created?"
# DECISIVE: if libwasmtime-helpers.a is absent, the archiver never produced it
# (problem is the cl.exe/lib.exe invocation upstream). If present, the
# hard_link/copy to .lib is what's failing (permissions / path translation).
find buck-out -path '*wasmtime-36-build-script-run*' \
     \( -name '*.a' -o -name '*.lib' -o -name '*.o' -o -name '*.obj' \) 2>/dev/null
echo "---- full OUT_DIR tree ----"
find buck-out -type d -path '*wasmtime-36-build-script-run*OUT_DIR*' 2>/dev/null | while read -r d; do
  echo "==== $d ===="; ls -laR "$d" 2>/dev/null
done
echo "::endgroup::"

echo "::group::host MSVC sanity (what cc-rs/buck2 would discover)"
which cl.exe lib.exe 2>/dev/null || true
echo "::endgroup::"
exit 0
