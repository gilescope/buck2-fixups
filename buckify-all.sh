#!/usr/bin/env bash
set -e

# Buckify the main rig (third-party/) and every conflict rig
# (third-party/conflict-rigs/*/) with one consistent set of rules.
#
#   ./buckify-all.sh          regenerate every rig's BUCK in place
#   ./buckify-all.sh --check  CI mode: fail on ANY reindeer output (warnings
#                             included) or on a BUCK that drifts from the
#                             committed copy (a PR that forgot to buckify)
#
# Conflict rigs reuse the canonical root fixups/ via `shared_fixups` in their
# reindeer.toml (needs reindeer with facebookincubator/reindeer#107); each rig
# keeps only the few overrides whose resolved versions differ from the main rig.

reindeer="${REINDEER:-reindeer}"
check=0
[ "${1:-}" = "--check" ] && check=1

# Git Bash/MSYS mangles buck2 target patterns; harmless for reindeer but the
# rigs share the tree, so keep it consistent with test.sh.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' ;; esac

# Main rig first (reads root reindeer.toml -> third_party_dir = third-party),
# then each conflict rig (override third_party_dir at the rig).
rigs=("")  # empty arg = main rig
for d in third-party/conflict-rigs/*/; do
  [ -f "$d/Cargo.toml" ] && rigs+=("$d")
done

status=0
for rig in "${rigs[@]}"; do
  if [ -z "$rig" ]; then label="third-party (main)"; buck="third-party/BUCK"; args=(); else
    label="${rig%/}"; buck="${rig%/}/BUCK"; args=(--third-party-dir "${rig%/}"); fi

  committed=""
  [ "$check" = 1 ] && [ -f "$buck" ] && committed="$(mktemp)" && cp "$buck" "$committed"

  out=$("$reindeer" "${args[@]}" buckify 2>&1) || { echo "✗ $label: reindeer failed:"; echo "$out"; status=1; continue; }
  if [ "$check" = 1 ] && [ -n "$out" ]; then
    echo "✗ $label: buckify is not clean (fix warnings):"; echo "$out"; status=1
  fi
  if [ "$check" = 1 ] && [ -n "$committed" ]; then
    if ! diff -u "$committed" "$buck" >/dev/null; then
      echo "✗ $label: committed BUCK is stale — re-run ./buckify-all.sh"; diff -u "$committed" "$buck" | head -20; status=1
    fi
    rm -f "$committed"
  fi
  [ "$status" = 0 ] && echo "◈ $label: ok"
done
exit $status
