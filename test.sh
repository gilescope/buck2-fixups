#!/usr/bin/env bash
set -e -x

# Git Bash/MSYS rewrites args that look like POSIX paths, mangling buck2
# target patterns (//third-party:foo -> /third-party:foo). Disable it.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' ;; esac

# Buckify the main rig and every conflict rig; all must be warning- and
# drift-free.
./buckify-all.sh --check

# Rather than build all targets with `buck2 build //...`, build only each
# crate whose fixup changed. A changed root fixup (fixups/<crate>) is shared
# by every rig that symlinks it; a changed rig override
# (third-party/conflict-rigs/<rig>/fixups/<crate>) affects just that rig.
# Either way we build the matching alias in every rig that has it, skipping
# crates with no rig target and known platform failures (the sweep +
# expected-failures lists track those).
# SKIP_CRATE_BUILDS=1 skips this where the prelude can't link (windows-arm:
# its msvc discovery is x64-only).
if [ -z "${SKIP_CRATE_BUILDS:-}" ]; then
  diff=$(git diff --name-only origin/main...HEAD)
  changed=$( { echo "$diff" | sed -n 's#^fixups/\([^/]*\)/.*#\1#p'; \
               echo "$diff" | sed -n 's#^third-party/conflict-rigs/[^/]*/fixups/\([^/]*\)/.*#\1#p'; } | sort -u )
  # A rig override often targets a crate that's only transitive in that rig
  # (no alias to build directly), so also build the whole rig when any of its
  # own fixups change. Rigs are tiny, so this is cheap.
  changed_rigs=$(echo "$diff" | sed -n 's#^\(third-party/conflict-rigs/[^/]*\)/fixups/.*#\1#p' | sort -u)
else
  changed=""; changed_rigs=""
fi
if [ -n "$changed" ] || [ -n "$changed_rigs" ]; then
  os="$(uname -s)"; case "$os" in MINGW*|MSYS*|CYGWIN*) os=Windows ;; esac
  arch="$(uname -m)"
  if [ "$os" = Windows ]; then case "${RUNNER_ARCH:-}" in ARM64) arch=aarch64 ;; X64) arch=x86_64 ;; esac; fi
  # Full labels (across all rigs) so a crate present in several rigs builds in
  # each; expected-failures carries full labels too, so the match is exact.
  available=$(buck2 uquery "kind('^alias\$', //third-party/...)" | sort -u)
  expected=$(sed '/^#/d;/^$/d' "ci/expected-failures-${os}-${arch}.txt" 2>/dev/null | sort -u || true)
  want=$(for c in $changed; do echo "$available" | grep -E ":${c}\$" || true; done
         for r in $changed_rigs; do echo "$available" | grep -E "^fixups//${r}:" || true; done)
  crates=$(echo "$want" | sed '/^$/d' | sort -u | comm -23 - <(echo "$expected") | tr '\n' ' ')
  # shellcheck disable=SC2086
  if [ -n "${crates// /}" ]; then buck2 build $crates; else echo "no changed fixups with rig targets"; fi
fi

# Prove the repo works as a buck2 cell:
./test-cell.sh
