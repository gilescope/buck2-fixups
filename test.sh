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
# build only each package where the fixup has changed:
git diff --name-only origin/main...HEAD | grep fixups | cut -d/ -f2 | sort | uniq | xargs -I{} sh -c 'echo buck2 build //:{}; buck2 build //:{}'
