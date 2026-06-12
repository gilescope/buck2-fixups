2026-06-12
CI extended to windows-x86_64 and windows-aarch64 (native buck2 msvc
binaries under Git Bash; reindeer x86_64-emulated on arm) plus windows
weekly sweeps. test-cell.sh copies via
git ls-files | tar (no rsync on windows runners); .gitattributes forces LF.

2026-06-12
Top-100 crates.io coverage: rustls added to the rig (ring provider; the
default aws-lc-rs chains into the known prelude ld-shim failure on linux) —
the only top-100 crate previously absent. ring fixup modernised to
cfg(version) syntax and pinned =0.17.5 (RING_CORE_PREFIX embeds the exact
version). parity-scale-codec bumped to 3.7.5. Stripped the Meta license
header from 38 fixups that were authored here, not copied from the
facebook/buck2 or ocamlrep shims (template copy-paste artifact). Added
.github/dependabot.yml (cargo now lives in /third-party) with a 7-day
cooldown. build-all.sh now detects mid-build DICE cancellation instead of
reporting unbuilt targets as failures.

2026-06-11
Expected-failure lists cut to one entry (aws-lc-sys on linux; macOS empty).

- Two prelude bugs found in the buildscript shims (from_any_dir.py), see
  ci/upstream-bug-from_any_dir.md: os.execl does no PATH lookup (fixed by
  absolute tool paths in toolchains/BUCK) and PurePath.relative_to(...,
  walk_up=True) needs python >= 3.12 (Earthfile base moved to trixie).
- windows_raw_dylib cfg now gated to windows only: raw-dylib is unstable
  on ELF under stable rustc (rust-lang/rust#135694).
- lzma-sys fixup referenced the buildscript-run target by full version
  (0.1.20) but reindeer names targets by major.minor — corrected, fixing
  lzma-sys + xz2.
- radium bumped 1.1.0 -> 1.1.1 (clash with rustc >= 1.89's
  core::sync::atomic::Atomic alias).
- mach + system-configuration fixups mark them target_compatible_with
  macos; wrong-OS crates removed from the test-rig Cargo.toml (their
  top-level aliases fail buck2's compat check when built cross-OS).

2026-06-11
CI extended: linux-x86_64 + linux-aarch64 + macos-aarch64 matrix; Linux jobs
run via Earthfile (locally reproducible: earthly +ci / +build-all). Weekly
full-crate sweep (build-all.sh, ~950 crates in one --keep-going build)
checked against `ci/expected-failures-<platform>.txt`. Pinned buck2
2026-06-01 and reindeer v2026.04.27.00 (now canonical for generating
third-party/BUCK).
Newer reindeer flushed out 57 stale buildscript fixups (crates that dropped
their build.rs) — removed; windows_*​ static_libs now glob lib versions.

2026-06-11
Repo now usable as a buck2 cell named `fixups` (`fixups//win:*` Windows SDK
import-lib targets, ported from the facebook/buck2 shim). `winapi` fixup
wired to them (closes #3). Restructured: test rig moved to third-party/
(fixups/ stays at root, symlinked in), root cell renamed `fixups`,
LICENSE-APACHE/LICENSE-MIT added, test-cell.sh proves cell consumption in
CI. README documents the three consumption modes: copy scripts,
submodule+symlink, external cell.

2025-07-20
Upgraded to latest reindeer ( https://github.com/facebookincubator/reindeer#322a5b27 ).

2025-05-03
Upgraded to latest reindeer ( https://github.com/facebookincubator/reindeer#c9ac4746 ).
