#!/usr/bin/env bash
set -e

# Build every crate in the test rig in one buck2 invocation (parallel,
# --keep-going) and diff the failure set against the per-platform expected
# list in ci/expected-failures-<os>-<arch>.txt. Fails on NEW failures and on
# stale entries (crates that started passing), so the lists stay honest.

platform="$(uname -s)-$(uname -m)"
expected="ci/expected-failures-${platform}.txt"
report=$(mktemp)
trap 'rm -f "$report"' EXIT

# Every top-level crate alias reindeer generated (one per Cargo.toml dep).
targets=$(buck2 uquery "kind('^alias\$', //third-party:)" 2>/dev/null)
echo "Building $(echo "$targets" | wc -l | tr -d ' ') crates for ${platform}..."

# shellcheck disable=SC2086
buck2 build --keep-going --build-report "$report" $targets || true

failed=$(python3 - "$report" <<'EOF'
import json, sys
report = json.load(open(sys.argv[1]))
for label, result in sorted(report.get("results", {}).items()):
    if result.get("success") != "SUCCESS":
        print(label.split("#")[0])
EOF
)
failed=$(echo "$failed" | sed '/^$/d' | sort -u)

expected_content=""
[ -f "$expected" ] && expected_content=$(sed '/^#/d;/^$/d' "$expected" | sort -u)

new_failures=$(comm -23 <(echo "$failed") <(echo "$expected_content"))
fixed=$(comm -13 <(echo "$failed") <(echo "$expected_content"))

status=0
if [ -n "$new_failures" ]; then
  echo "✗ NEW failures (not in $expected):"
  echo "$new_failures"
  status=1
fi
if [ -n "$fixed" ]; then
  echo "✗ Stale entries in $expected (now passing — remove them):"
  echo "$fixed"
  status=1
fi
[ "$status" = 0 ] && echo "OK: failure set matches $expected ($(echo "$expected_content" | sed '/^$/d' | wc -l | tr -d ' ') known)"
exit $status
