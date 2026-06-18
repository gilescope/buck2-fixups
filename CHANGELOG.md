2026-06-18
Snapshot librocksdb-sys uses its real overlay (replaces the stub). A shared
`overlay` fixup's files live outside the rig, so reindeer would emit a
`../../../fixups/...` source path that buck2 refuses to parse. Fixed in reindeer
(gilescope/reindeer, shared_fixups branch): external overlays are emitted
through a fixed `.shared-fixups` in-rig anchor; each snapshot carries a
`.shared-fixups -> ../../../fixups` symlink (deliberately NOT named `fixups` —
that would land in reindeer's local fixup search and trip the unused-fixup check
that shared_fixups exempts). librocksdb-sys now builds on Linux exactly like the
main rig instead of being stubbed (run=false). REINDEER_REV bumped to pick up
the fix. mint-snapshot.sh creates the anchor symlink.

2026-06-16
Dated snapshot rigs (issue #45): third-party/snapshots/<yyyy-mm>/ mirror the
main rig's WHOLE dep set at a point in time so version-gated fixups get
exercised against the versions older consumers still resolve, not just the main
rig's latest. Four slots on the NixOS YY.05/YY.11 cadence: 2024-11, 2025-05,
2025-11, 2026-05 (~1837-2064 crates each). New mint-snapshot.sh era-resolver:
*-izes the main-rig deps, prunes crates absent/unsatisfiable at the slot's
frozen index until consistent (logging drops), writes the rig + lock, buckifies.
Slots straddle the semver 1.0.27 build.rs-drop boundary (1.0.23 vs 1.0.27), so
the semver <1.0.27 gate is tested both sides. The wide mirror surfaced ~17
silent build-script gaps now version-gated (typenum <1.20, backtrace <0.3.74,
libloading <0.6, moka <0.12.12, schemafy >=0.6, html5ever/markup5ever codegen,
wit-bindgen, crc32fast, async-io, ...) - each matching nothing in the main rig's
version, so main stays clean. librocksdb-sys can't be shared (its overlay of
vendored C++ won't path-normalize at snapshot depth -> buck2 won't parse the
rig), so each slot stubs it locally (run=false); it then fails to build and is
tracked in expected-failures. The weekly sweep is now a MATRIX: a base leg
(main + conflict rigs) + one leg per slot, so the wide rigs build in parallel;
build-all.sh takes a target pattern and scopes its failure-diff to the leg. The
PR-time changed-fixup build (test.sh + Earthfile build-crates) matches kind
alias|rust_library and a :crate-<ver> suffix so transitive-only crates are
reached, but its universe is main rig + conflict rigs ONLY - snapshots are
sweep-only at build time (a ~1900-crate era mirror has many crates that don't
build standalone; only the sweep catalogs them). At PR time snapshots are still
gated by buckify-all --check (BUCK freshness + warning-free). Because each slot
is ~1900 crates, the full per-platform build-failure
set is populated by the matrix sweep (pre-seeded: librocksdb-sys cascade +
windows-sys <0.60 raw-dylib-on-non-Windows). Locks minted via a registry time
machine - gilescope/crates.io-index carries snapshot-<yyyy-mm> branches (the
index frozen that month, reconstructed from abandoned forks after upstream
squashed its history) and slot-<yyyy-mm> tags. See README "Dated snapshots".

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
