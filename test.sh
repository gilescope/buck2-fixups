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
# by every rig via shared_fixups; a changed rig override
# (third-party/conflict-rigs/<rig>/fixups/<crate>) affects just that rig.
# Either way we build the crate in every rig that has it — matching both the
# bare alias (direct deps) and the versioned rust_library `:crate-<ver>` (crates
# only transitive in a rig, e.g. conflict rigs, get no bare alias), skipping
# crates with no rig target and known platform failures (the sweep +
# expected-failures lists track those).
# Snapshots are deliberately OUT of scope here: a dated snapshot is a ~1900-crate
# era mirror in which many crates don't build standalone (featureless transitive
# deps, old build scripts, native-lib stubs); those failures are only knowable —
# and catalogued in expected-failures — by the weekly matrix sweep, not at PR
# time. At PR time snapshots are still validated by buckify-all --check (BUCK
# freshness + warning-free). So the universe below is main rig + conflict rigs.
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
  # Full labels (across main + conflict rigs) so a crate present in several rigs
  # builds in each; expected-failures carries full labels too, so the match is
  # exact. alias|rust_library + the `(-<ver>)?` suffix catch a crate whether it's
  # a direct dep (bare `:crate` alias) or only transitive in a rig (`:crate-<ver>`
  # library) — the `-[0-9]` guard stops `:serde` matching `:serde_derive`. The
  # universe excludes snapshots (sweep-only — see above).
  available=$(buck2 uquery "kind('^(alias|rust_library)\$', //third-party: + //third-party/conflict-rigs/...)" | sort -u)
  expected=$(sed '/^#/d;/^$/d' "ci/expected-failures-${os}-${arch}.txt" 2>/dev/null | sort -u || true)
  want=$(for c in $changed; do echo "$available" | grep -E ":${c}(-[0-9][0-9.]*)?\$" || true; done
         for r in $changed_rigs; do echo "$available" | grep -E "^fixups//${r}:" || true; done)
  # Drop known failures by CRATE STEM (label minus trailing -<ver>): expected
  # lists the bare alias (e.g. :backtrace) but lever-1's matcher may build the
  # versioned library (:backtrace-0.3) of the same crate — an exact-match filter
  # would miss it and try to build a known-broken crate. Stem-strip both sides.
  exp_stems=$(echo "$expected" | sed -E 's/-[0-9][0-9.]*$//' | sort -u)
  # Tag expected stems (E) and candidates (W), feed both to one awk: bad[] from
  # E lines, then keep W labels whose stem isn't bad. (awk -v can't carry the
  # newline-separated list; concatenation avoids it and stays POSIX for the
  # Earthfile copy of this logic.)
  crates=$( { printf '%s\n' "$exp_stems" | sed 's/^/E /'; \
              echo "$want" | sed '/^$/d' | sort -u | sed 's/^/W /'; } \
    | awk '$1=="E"{bad[$2]=1;next} {s=$2;sub(/-[0-9][0-9.]*$/,"",s);if(!(s in bad))print $2}' | tr '\n' ' ')
  # shellcheck disable=SC2086
  if [ -n "${crates// /}" ]; then buck2 build $crates; else echo "no changed fixups with rig targets"; fi
fi

# Prove the repo works as a buck2 cell:
./test-cell.sh
