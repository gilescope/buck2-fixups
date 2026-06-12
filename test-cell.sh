#!/usr/bin/env bash
set -e -x

# Prove this repo works as a buck2 cell named `fixups`, the way a downstream
# project consumes it (README "External cell" section). Copies the working
# tree into a scratch consumer project and resolves the targets that fixups
# reference (e.g. winapi's extra_deps on fixups//win:*).

scratch=$(mktemp -d)
trap 'buck2 killall 2>/dev/null || true; rm -rf "$scratch"' EXIT

consumer="$scratch/consumer"
mkdir -p "$consumer/fixups-src"
# Tracked files only (skips buck-out, target, .git, .cargo). tar instead of
# rsync: Git Bash on Windows runners has no rsync. Earthly containers get the
# repo without .git, so fall back to find there.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git ls-files -z
else
  find . \( -name buck-out -o -name buck-out-docker -o -name .git \
            -o -name target -o -name .cargo \) -prune \
         -o \( -type f -o -type l \) -print0
fi | tar -cf - --null -T - | tar -xf - -C "$consumer/fixups-src"

cd "$consumer"
touch .buckroot BUCK
mkdir toolchains
touch toolchains/BUCK
cat > .buckconfig <<'EOF'
[cells]
root = .
fixups = fixups-src
prelude = prelude
toolchains = toolchains
none = none

[cell_aliases]
config = prelude
fbcode = none
fbsource = none
buck = none

[external_cells]
prelude = bundled

[parser]
target_platform_detector_spec = target:root//...->prelude//platforms:default
EOF

# The labels fixups bake into consumers' generated BUCK files must resolve.
buck2 uquery fixups//win:ws2_32.lib | grep -q "fixups//win:ws2_32.lib"
buck2 uquery 'fixups//win:' | wc -l
echo "cell consumption OK"
