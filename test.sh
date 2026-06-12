#!/usr/bin/env bash
set -e -x

# Test:
output=$(reindeer buckify 2>&1)
if [[ -n "$output" ]]; then
  echo "Expected reindeer buckify to produced no output if all good but produced: $output"
  echo ""
  echo "Please fix above buckify warnings..."
  exit 1
fi

# Rather than build all targets with:
# buck2 build //...
# build only each crate whose fixup changed, skipping fixups for crates the
# test rig doesn't depend on (no top-level alias) and known platform
# failures (the sweep + expected-failures lists track those).
# SKIP_CRATE_BUILDS=1 skips this on platforms where the prelude can't link
# (windows-arm: its msvc discovery is x64-only).
changed=$([ -z "${SKIP_CRATE_BUILDS:-}" ] && git diff --name-only origin/main...HEAD | grep '^fixups/' | cut -d/ -f2 | sort -u || true)
if [ -n "$changed" ]; then
  available=$(buck2 uquery "kind('^alias\$', //third-party:)" | sed 's|.*:||' | sort -u)
  os="$(uname -s)"; case "$os" in MINGW*|MSYS*|CYGWIN*) os=Windows ;; esac
  arch="$(uname -m)"
  if [ "$os" = Windows ]; then case "${RUNNER_ARCH:-}" in ARM64) arch=aarch64 ;; X64) arch=x86_64 ;; esac; fi
  expected=$(sed '/^#/d;/^$/d;s|.*:||' "ci/expected-failures-${os}-${arch}.txt" 2>/dev/null | sort -u || true)
  crates=$(comm -12 <(echo "$changed") <(echo "$available") | comm -23 - <(echo "$expected") | sed 's|^|//third-party:|' | tr '\n' ' ')
  # shellcheck disable=SC2086
  if [ -n "${crates// /}" ]; then buck2 build $crates; else echo "no changed fixups with rig targets"; fi
fi

# Prove the repo works as a buck2 cell:
./test-cell.sh
