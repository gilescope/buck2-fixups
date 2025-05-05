#!/usr/bin/env bash
set -e -x

# Test:
reindeer buckify

# Rather than build all targets with:
# buck2 build //...
# build only each package where the fixup has changed:
git diff --name-only origin/main...HEAD | cut -d/ -f2 | grep -vE 'CHANGELOG\.md|README\.md|BUCK|Cargo\.lock|Cargo\.toml|workflows|test\.sh' | xargs -I{} sh -c 'echo buck2 build //:{}; buck2 build //:{}'
