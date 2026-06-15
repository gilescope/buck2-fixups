2026-06-15
Substrate-lock import: 250 non-substrate crates.io deps from polkadot-sdk's
Cargo.lock surfaced as direct deps (pinned to latest, matching the rest of the
rig), e.g. the alloy/ruint/ethabi EVM stack, scale-* codec family, libp2p,
trie-db, jsonrpsee, multiaddr. New buildscript fixups: arrayvec/erased-serde/
quote/parity-util-mem/static_init/thiserror-core/zmij (run=false probes),
ssz_rs (run=true, include!s OUT_DIR), static_init (run=true for elf/mach_o/coff
cfgs). The bulk add transitively bumped shared crates and broke their fixups:
thiserror 2.0.12->2.0.18 now include!s OUT_DIR/private.rs keyed on
CARGO_PKG_VERSION_PATCH, so fixups/thiserror needs cargo_env + buildscript.run
(was run=false). semver's buildscript fixup went unused once the rig moved past
1.0.26 (semver dropped build.rs at 1.0.27) - now version-gated to
'cfg(version = ">=1.0.0, <1.0.27")' so it keeps serving consumers pinned to
older semver while reindeer's unused-buildscript check skips a version-only cfg
that matches no resolved version. quinn (build.rs / cfg_aliases) left the tree
with libp2p-quic/smoldot; its run=true is kept for consumers (reindeer skips
fixups for absent crates). aquamarine's doc/js glob lost its leading-slash
match. 59 crates deferred with reasons inline: the wasmtime+cranelift+wasmi
native/codegen toolchain, wasm-opt, isahc/curl, subxt, kube/k8s-openapi,
keccak-asm/sha3-asm, reed-solomon-novelpoly, network-interface, pyroscope
(all need cxx_library/codegen fixups - follow-up); plus 9 links/feature
conflicts (smoldot{,-light} libsqlite3-sys clash, libp2p-quic/tls, gloo-*,
jemalloc - re-enable if resolvable).

2026-06-12
Graveyard excavation: ~70 commented-out crates revived (crypto matrix moved
from stale pre-release pins to the now-stabilised RustCrypto 0.11/0.2 line;
vendored openssl 3.5 with DEP_OPENSSL_VERSION_NUMBER cfg pairing; bundled
rusqlite; git2 sans ssh/https; zstd/lzma/libgit2/libssh2/rdkafka fixups had
stale full-version $(location) refs - reindeer names targets major.minor).
All 234 platform-neutral transitive-only crates surfaced as direct deps so
sweeps build them (beware: the manifest's [target] table - new deps must land
in [dependencies]). Sweep now covers ~1250 crates per platform. Still buried,
with reasons inline: sqlx (links clash, #36), test-fuzz family, rdrand,
dwrote, gloo-timers, wit-bindgen.

2026-06-12
CI extended to windows-x86_64 and windows-aarch64 (native buck2 msvc
binaries under Git Bash; reindeer x86_64-emulated on arm) plus a
windows-x86_64 weekly sweep. Crate builds skipped on windows-arm: the
prelude's msvc discovery hardcodes x64 lib paths so aarch64 links fail.
Fixed two latent windows breaks from main: unix-only absolute compiler
paths in toolchains/BUCK (now select()ed per OS) and missing vcruntime.lib
(__CxxFrameHandler3) on msvc targets. test-cell.sh copies via
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
reporting unbuilt targets as failures. Added dependabot-helper workflow:
dependabot can't run reindeer, so its third-party bumps always failed
buckify-check; the helper regenerates third-party/BUCK (new earthly
+buckify target), pushes the fix to the PR branch, and re-dispatches CI
(workflow_dispatch with sweep=false now runs the normal PR jobs, since
GITHUB_TOKEN pushes don't retrigger pull_request workflows). Helper
hardened after first contact: gate on PR author rather than event actor
(so maintainer "Update branch" still heals), and build with main's
Earthfile (dependabot branches fork from an older main that may predate
the +buckify target), plus a workflow_dispatch trigger to force a run on
any PR number.

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
