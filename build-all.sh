#!/usr/bin/env bash
set -e

# Build every crate in the test rig in one buck2 invocation (parallel,
# --keep-going) and diff the failure set against the per-platform expected
# list in ci/expected-failures-<os>-<arch>.txt. Fails on NEW failures and on
# stale entries (crates that started passing), so the lists stay honest.

# Git Bash reports e.g. MINGW64_NT-10.0-20348; fold to a stable name.
os="$(uname -s)"
case "$os" in MINGW*|MSYS*|CYGWIN*) os=Windows ;; esac
arch="$(uname -m)"
if [ "$os" = Windows ]; then
  # Git Bash may itself run x64-emulated on arm64, making uname -m lie
  # (and PROCESSOR_ARCHITEW6432 is WOW64-32-only, so it lies too).
  # RUNNER_ARCH is GitHub's job-level truth.
  case "${RUNNER_ARCH:-}" in
    ARM64) arch=aarch64 ;;
    X64) arch=x86_64 ;;
  esac
fi
platform="${os}-${arch}"
expected="ci/expected-failures-${platform}.txt"
report=$(mktemp)
trap 'rm -f "$report"' EXIT

# Every top-level crate alias reindeer generated (one per Cargo.toml dep).
targets=$(buck2 uquery "kind('^alias\$', //third-party:)" 2>/dev/null)
echo "Building $(echo "$targets" | wc -l | tr -d ' ') crates for ${platform}..."

buildlog=$(mktemp)
# shellcheck disable=SC2086
buck2 build --keep-going --build-report "$report" $targets 2>&1 | tee "$buildlog" || true
# A concurrent buck2 command or a BUCK rewrite mid-build cancels DICE keys;
# the report then marks unbuilt targets as failures. Don't diff bogus data.
if grep -q "evaluation of this key was cancelled" "$buildlog"; then
  echo "✗ build was cancelled mid-flight (concurrent buck2/buckify?) — rerun on a quiescent tree"
  rm -f "$buildlog"; exit 2
fi
rm -f "$buildlog"

# Windows runners ship `python`, not `python3`.
python="$(command -v python3 || command -v python)"
failed=$("$python" - "$report" <<'EOF'
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
# The lists track the GitHub-runner environment; local toolchains (extra
# brew/apt packages) legitimately make some entries pass, so stale entries
# only fail in CI.
if [ -n "$fixed" ]; then
  echo "⚠ Stale entries in $expected (now passing — remove them):"
  echo "$fixed"
  [ -n "$GITHUB_ACTIONS" ] && status=1
fi
[ "$status" = 0 ] && echo "OK: failure set matches $expected ($(echo "$expected_content" | sed '/^$/d' | wc -l | tr -d ' ') known)"
exit $status
