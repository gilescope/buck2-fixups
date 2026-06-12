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
# test rig doesn't depend on (no top-level alias):
changed=$(git diff --name-only origin/main...HEAD | grep '^fixups/' | cut -d/ -f2 | sort -u || true)
if [ -n "$changed" ]; then
  available=$(buck2 uquery "kind('^alias\$', //third-party:)" | sed 's|.*:||' | sort -u)
  crates=$(comm -12 <(echo "$changed") <(echo "$available") | sed 's|^|//third-party:|' | tr '\n' ' ')
  # shellcheck disable=SC2086
  if [ -n "${crates// /}" ]; then buck2 build $crates; else echo "no changed fixups with rig targets"; fi
fi

# Prove the repo works as a buck2 cell:
./test-cell.sh
