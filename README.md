# buck2-fixups

[Reindeer](https://github.com/facebookincubator/reindeer) fixups for buck2.

411 and counting... (please feel free to contribute!)

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
fixups/        the product - one dir per crate
win/           shared targets fixups reference (Windows SDK import libs)
third-party/   CI test rig (Cargo.toml + generated BUCK; fixups -> ../fixups)
```

The root is kept clean because a git external cell mounts the whole repo.

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
