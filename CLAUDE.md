# buck2-fixups — notes for future sessions

This cell build-tests crates.io crates across platforms from reindeer-generated
BUCK. Test locally with Earthly (`earthly +ci`, `earthly +build-all`); per-platform
known failures live in `ci/expected-failures-*.txt`; per-crate fixups live in
`fixups/<crate>/fixups.toml` (keyed by crate name, not version).

## Lesson: non-determinism breaks buck2 rlib pipelining → a bogus E0463

If a **proc-macro consumer** fails with a *bare* `error[E0463]: can't find crate
for X` while X is clearly passed via `--extern`, it is almost never a missing dep.
It is buck2's pipelining tripping over a **non-deterministic crate**:

- buck2 builds an rlib's codegen against its dependencies' **metadata** builds, not
  their codegen rlibs (prelude `rust/build.bzl`, the `crate_type == rlib` branch
  that downgrades a dep's `MetadataKind` from `link` to `full`). This is sound only
  if a crate's metadata build and codegen build are byte-identical.
- A proc-macro or build script with **non-deterministic output** (random idents,
  `HashMap` iteration order, embedded absolute paths/timestamps) makes the two
  diverge. An rlib built against the metadata then references a dep version the
  codegen rlib can't satisfy. The true error is a masked
  `E0460: found possibly newer version of crate ... which X depends on`; the
  consumer just sees the bare E0463. Cargo never hits this because it never
  cross-uses metadata builds for codegen. Ref: facebook/buck2#1206.

### Diagnose

1. Add `extern crate <dep>;` at the top of the consumer's source to surface the
   real E0460 naming the mismatched crate.
2. Confirm non-determinism:
   `buck2 build :<crate>[expand] --out a.rs; buck2 clean; \
    buck2 build :<crate>[expand] --out b.rs; diff a.rs b.rs`
   A non-empty diff is the culprit (and shows the exact differing line).

### Fix

Make the crate **deterministic at the source** — preferred, because it keeps
pipelining (a real wall-clock win) and advances byte-reproducible builds. Usually a
`[env]` fixup pinning a seed/knob.

Worked example: `fixups/const-random-macro/fixups.toml` pins `CONST_RANDOM_SEED`.
`const-random-macro` reads it via `option_env!`, which bakes the seed at *its own*
compile time, so every `const_random!()` (e.g. macro_magic's `COMPILATION_TAG`) is
reproducible. That one fixup unblocked the entire macro_magic / FRAME proc-macro
chain — no prelude fork, no speed cost. Note the seed must sit on the crate that
*reads* `option_env!`, not the crate that *uses* the macro.

`[env]` fixups land on the rust rule's `env` attr and reach the rustc compile
environment, so they are the lever for compile-time `env!` / `option_env!` knobs.

## Lesson: when a crate builds in cargo but not buck2, diff the rustc invocations

`third-party/Cargo.toml` is a real cargo manifest with the same lockfile, so cargo
is a known-good baseline. `cd third-party && cargo build -v -p <crate>` prints the
exact working `rustc` command; diff its `--cfg` / `--extern` / features against
buck2's `*.args` file. Identical features but a cargo-only success usually means a
**derive/proc-macro needs an env var cargo sets implicitly** — most often
`CARGO_MANIFEST_DIR`, read by `proc-macro-crate` to resolve a renamed dependency
(e.g. substrate crates rename `parity-scale-codec` to `codec`; without the var the
`#[derive(Encode/Decode)]` can't find it and the type silently never implements
`Encode` -> `E0277 ...: WrapperTypeEncode is not satisfied`). Fix: `cargo_env = true`
in the crate's fixup. Worked examples: `fixups/frame-support/`, `fixups/frame-system/`,
and most of the `sp-*` layer.
