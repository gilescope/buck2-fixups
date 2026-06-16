# buck2-fixups

[Reindeer](https://github.com/facebookincubator/reindeer) fixups for buck2.

448 and counting... (please feel free to contribute!)

CI-tested on linux-x86_64, linux-aarch64, macos-aarch64, windows-x86_64
and windows-aarch64 (buckify + cell consumption only on windows-arm:
buck2's prelude msvc discovery is x64-only, so aarch64 links fail —
see issue #42): `reindeer
buckify` must be warning-free, the committed `third-party/BUCK` must be
up to date, changed fixups must `buck2 build`, and cell consumption is
verified (`test-cell.sh`). A weekly sweep builds **every** crate
(`build-all.sh`); per-platform known failures live in
`ci/expected-failures-<os>-<arch>.txt` and the sweep fails on new failures
or stale entries.

The Linux jobs run inside [Earthly](https://earthly.dev) targets so they can
be reproduced locally: `earthly +ci` (checks) or `earthly +build-all`
(full sweep). The canonical reindeer/buck2 versions are pinned in the
`Earthfile` ARGs — regenerate `third-party/BUCK` with that reindeer version
or CI will flag it stale.

## Using these fixups

Reindeer hardcodes the fixup location to `<third-party-dir>/fixups/`
([src/fixups.rs](https://github.com/facebookincubator/reindeer/blob/main/src/fixups.rs)),
so the files must exist at that path on disk. Three ways to get them there:

### 1. Copy what you need (simplest)

Copy `fixups/<crate>/` directories into your `third-party/fixups/`.
Two helper scripts:

```sh
./update.sh <your_fixups_dir>          # refresh fixups you already have
./extend.sh fixups <your_fixups_dir>   # add ones you don't (no overwrite)
```

### 2. Submodule / subtree (trackable)

```sh
git submodule add https://github.com/gilescope/buck2-fixups third-party/buck2-fixups
ln -s buck2-fixups/fixups third-party/fixups
```

The whole collection, pinned to a commit, updatable with
`git submodule update --remote`. Unused fixups are ignored by reindeer.

### 3. External cell (needed for Windows system libs)

Some fixups (currently `winapi`) reference targets in this repo, e.g.
`fixups//win:ws2_32.lib`. For those to resolve, define a `fixups` cell in
your project's `.buckconfig`:

```ini
[cells]
fixups = third-party/buck2-fixups   # if you used the submodule above

# OR let buck2 fetch it - no submodule needed:
[external_cells]
fixups = git

[external_cell_fixups]
git_origin = https://github.com/gilescope/buck2-fixups.git
commit_hash = <40-char commit SHA>
```

Note: a git external cell is only visible to buck2 (it materialises under
`buck-out/`), so reindeer still needs mode 1 or 2 for the fixup files
themselves. See the
[buck2 external cells docs](https://buck2.build/docs/users/advanced/external_cells/).

The cell **must** be named `fixups` — that name is baked into the labels
fixups emit (this repo's own root cell is named `fixups` for the same
reason). `./test-cell.sh` proves cell consumption works in CI.

## Repo layout

```text
fixups/                      the product - one dir per crate
win/                         shared targets fixups reference (Windows SDK import libs)
third-party/                 main CI test rig (Cargo.toml + generated BUCK; fixups -> ../fixups)
third-party/conflict-rigs/   extra rigs for crates that can't share one graph (see below)
third-party/snapshots/       dated rigs pinning OLDER version constellations (see below)
```

The root is kept clean because a git external cell mounts the whole repo.

## Conflicting crates

Cargo permits only one claimant of a given `links = "..."` key per dependency
graph, so two crates that bind the same native library at incompatible
versions can't both live in the main rig — e.g. `rusqlite` (libsqlite3-sys
^0.33) and `sqlx-sqlite` (libsqlite3-sys ^0.30) both declare
`links = "sqlite3"`. The same trap awaits any `links` pair (openssl vs aws-lc,
jemalloc flavours, zstd majors).

Each losing side gets its own **conflict rig** under
`third-party/conflict-rigs/<name>/` — a tiny manifest holding one side of the
clash, swept alongside the main rig. Not separate branches (drift) and not
Cargo features (features add deps, they can't drop a conflicting `links`
crate).

Fixups stay shared via reindeer's `shared_fixups` (see
[facebookincubator/reindeer#107][pr107]): the rig's `reindeer.toml` points at
the repo's own `fixups/`, so the rig only carries a local override for the few
crates whose resolved version needs a different build than the main rig's
(reindeer keys buildscript directives by version) — see the comments in
`third-party/conflict-rigs/sqlx/fixups/{quote,thiserror,libsqlite3-sys}`:

```toml
# third-party/conflict-rigs/<name>/reindeer.toml
shared_fixups = ["../../../fixups"]
```

[pr107]: https://github.com/facebookincubator/reindeer/pull/107

Regenerate a rig after bumping its deps:

```sh
reindeer --third-party-dir third-party/conflict-rigs/<name> buckify
```

`./buckify-all.sh --check` (run by CI) buckifies the main rig and every
conflict rig and fails on any warning or BUCK drift. The sweep
(`./build-all.sh`) covers all rigs via the recursive `//third-party/...`
target pattern; rig failures appear in the per-platform expected-failures
files under their full label (`fixups//third-party/conflict-rigs/<name>:X`).

Until #107 ships in a reindeer release, CI builds reindeer from the PR branch
(pinned by commit).

## Dated snapshots

The main rig pins each crate to one version, so reindeer resolves exactly **one**
constellation. A version-gated fixup that only fires on an *older* version is
therefore never exercised — it silently rots until that single resolution
happens to move. Consumers pinned to older locks (e.g. a polkadot-sdk release)
get fixups we never test (issue [#45]).

**Dated snapshot rigs** fix this. Each `third-party/snapshots/<yyyy-mm>/` is a
rig like a conflict rig, but it **mirrors the main rig's whole dependency set at
a point in time**: the same crate names, floated to `*`, resolved against the
crates.io index **as it stood that month** (~1900 crates per slot). Each slot
finds its *own* consistent era pin-set — crates not yet published (or
unsatisfiable) at that date are pruned, since an era consumer wouldn't have had
them either. They straddle real boundaries: `semver` resolves `1.0.23` (build
script present) in older slots and `1.0.27` (dropped) in newer, so the `semver`
`cfg(version = "<1.0.27")` fixup is exercised on both sides.

Current slots follow the NixOS `YY.05`/`YY.11` cadence: **`2024-11`, `2025-05`,
`2025-11`, `2026-05`**.

Fixups stay shared (`shared_fixups`); the older versions resurface build scripts
the shared fixup is silent about — **version-gate** them
(`['cfg(version = ">=X, <Y")']` with `buildscript.run`) so one fixup serves the
main rig *and* every snapshot (a version cfg matching no resolved version is
exempt). Wiring the wide mirror surfaced and fixed ~17 such gaps (typenum,
backtrace, libloading, moka, schemafy, …) — that drift is exactly what #45
hunts. One crate can't be shared: `librocksdb-sys` uses an `overlay` of vendored
C++ whose path can't normalize at the snapshot's depth, so each slot stubs it
locally (`fixups/librocksdb-sys/`, `run=false`) — it then fails to build and is
tracked in expected-failures.

### Minting / re-minting a snapshot (the registry time machine)

`crates.io-index` squashes its git history, so you can't `git checkout` an old
index directly. Instead, [`gilescope/crates.io-index`][idx] carries
`snapshot-<yyyy-mm>` branches (the index frozen that month, reconstructed from
the object stores of abandoned forks) and `slot-<yyyy-mm>` tags (the May/Nov
grid → closest faithful index). `mint-snapshot.sh` does the rest — flatten the
frozen index into a local registry, `*`-ize the main-rig deps, prune to a
consistent era set, write the rig + lock, buckify:

```sh
./mint-snapshot.sh 2025-11 snapshot-2025-10   # <slot> <index-branch>
```

The committed `Cargo.lock` is the durable artifact (crates.io sources +
checksums; tarballs are immutable), so **buckify and CI never touch the index
fork** — only re-minting does. Deps stay `*`; the lock is the pin. Going
forward, mint a new slot from the *live* index each cadence step (it stays
reachable ~6 weeks before the next squash).

### CI

`./buckify-all.sh --check` covers every snapshot (warning-free + no drift) on
each PR. At **PR time**, the changed-fixup build also reaches every snapshot
containing the crate — matching the bare `:crate` alias (direct deps) *and* the
versioned `:crate-<ver>` library (crates only transitive in a snapshot, which
get no bare alias) — so a fixup change is tested against the older
constellations immediately. The weekly **sweep is a matrix**: a `base` leg
(main + conflict rigs) plus one leg per snapshot slot, so the wide rigs build in
parallel rather than serially blowing the timeout (`build-all.sh` takes a target
pattern and scopes its failure-diff to that leg). Failures carry the label
`fixups//third-party/snapshots/<yyyy-mm>:X`.

Because each slot is ~1900 crates, the **complete** per-platform failure set is
populated by the matrix sweep, not by hand: run it (`workflow_dispatch`), then
add the new failures to `ci/expected-failures-<platform>.txt`. The lists ship
pre-seeded with the confident, platform-class failures (the `librocksdb-sys`
stub cascade and the `windows-sys <0.60` `raw-dylib`-on-non-Windows class).

[#45]: https://github.com/gilescope/buck2-fixups/issues/45
[idx]: https://github.com/gilescope/crates.io-index

## Windows

`fixups//win:*` are header-only `prebuilt_cxx_library` targets that export
the linker flag for each Windows SDK import library (the `.lib` itself is
supplied by the MSVC environment). Ported from the
[facebook/buck2 shim][win-shim].

[win-shim]: https://github.com/facebook/buck2/tree/main/shim/third-party/toolchains/win

If rustc emits unresolvable `-l` flags from `#[link(...)]` attributes, pass
`-Z link-native-libraries=no` and add the std libs
(`msvcrt.lib ws2_32.lib ntdll.lib userenv.lib` ...) to your toolchain's
`rustc_flags`. See [issue #3](https://github.com/gilescope/buck2-fixups/issues/3).

## Licensing

Each fixups.toml has the license and attribution at the top.
If there is no attribution as it's contributed directly to this repo then the license is Apache 2.0 license.

Please use at your own risk. No warrent is given for the use of these fixups.
They may not be quite what you need. PRs welcome!

Everything is licensed as Apache 2.0. Some are MIT duel licensed.

Thanks to all the fixup sources:

https://github.com/facebook/buck2/tree/main/shim/third-party - MIT / Apache-2.0

https://github.com/crates-pro/crates-pro-infra/tree/main/third-party/fixups
MIT / Apache-2.0

https://github.com/dtolnay/cxx/tree/master/third-party/fixups - MIT / Apache-2.0
https://github.com/dtolnay/buck2-rustc-bootstrap/tree/master/fixups - MIT / Apache-2.0

https://github.com/web3infra-foundation/mega/tree/main/third-party/fixups - MIT / Apache-2.0

https://github.com/systeminit/si/tree/main/third-party/rust - Apache 2.0

https://github.com/suiwombat/sui/tree/buck_sui_up_rc1 - Apache 2.0

https://github.com/theoparis/bevy-os - Apache 2.0

Other rust buck2 projects:
https://github.com/search?q=load%28%22%40prelude%2F%2Ftoolchains%3Arust.bzl%22%2C+%22system_rust_toolchain%22%29&type=code

Related upstream discussions: shared fixup repositories
([reindeer#73](https://github.com/facebookincubator/reindeer/issues/73)),
fixup gallery ([reindeer#19](https://github.com/facebookincubator/reindeer/issues/19)).

## TODO

https://github.com/pulanski/rcc/tree/main/third-party/rust/fixups

https://github.com/benbrittain/my-react-router-app/tree/main/third-party/rust/fixups

https://github.com/c00t/Bubble/tree/main/third-party/rust/fixups

https://github.com/thoughtpolice/a/tree/main/buck/third-party
