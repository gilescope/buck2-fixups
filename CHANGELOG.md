2026-06-12
CI extended to windows-x86_64 and windows-aarch64 (native buck2 msvc
binaries under Git Bash; reindeer x86_64-emulated on arm) plus windows
weekly sweeps. test-cell.sh copies via
git ls-files | tar (no rsync on windows runners); .gitattributes forces LF.

2026-06-11
CI extended: linux-x86_64 + linux-aarch64 + macos-aarch64 matrix; Linux jobs
run via Earthfile (locally reproducible: earthly +ci / +build-all). Weekly
full-crate sweep (build-all.sh, ~950 crates in one --keep-going build)
checked against `ci/expected-failures-<platform>.txt`. Pinned buck2 2026-06-01
and reindeer v2026.04.27.00 (now canonical for generating third-party/BUCK).
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
