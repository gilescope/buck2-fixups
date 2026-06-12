# Draft upstream issue for facebook/buck2 (not yet filed)

Title: prelude: from_any_dir.py uses os.execl, breaking buildscripts with
system_cxx_toolchain's bare compiler names

## Problem

`prelude/rust/tools/from_any_dir.py` execs the wrapped tool with:

```python
os.execl(cc[0], cc[0], *cc[1:])
```

`os.execl` performs no PATH lookup. `system_cxx_toolchain` defaults to bare
tool names (`clang`, `clang++`, `ar`), so every cargo buildscript that
shells out via cc-rs fails:

```text
error occurred in cc-rs: command did not execute successfully (status code exit status: 1): .../__cc_shim.sh ...
exec failed: ['clang', '--ld-path=.../__ld_shim.sh', '-fno-sanitize=all', ...]
FileNotFoundError: [Errno 2] No such file or directory
```

The inner FileNotFoundError is swallowed by cc-rs, making this painful to
diagnose. Affects cc shim, cxx shim, ar shim and ld shim alike. Observed
with buck2 2026-06-01 (bundled prelude) on macOS and Linux; reproduced in
gilescope/buck2-fixups with crates lz4-sys, psm, sha1-asm, lzma-sys, xz2,
aws-lc-sys.

## Expected

PATH lookup, e.g.:

```python
os.execvp(cc[0], cc)
```

## Workaround

Pass absolute paths in the toolchain:

```python
system_cxx_toolchain(
    name = "cxx",
    compiler = "/usr/bin/clang",
    cxx_compiler = "/usr/bin/clang++",
    linker = "/usr/bin/clang++",
    archiver = "/usr/bin/ar",
)
```

Possibly related to the unexplained TODO above the exec call referencing
aws-lc-sys failures.

## Second issue in the same file

```python
interim_cwd = interim_cwd.relative_to(original_cwd, walk_up=True)
```

`walk_up=` requires Python >= 3.12 (https://docs.python.org/3/library/pathlib.html#pathlib.PurePath.relative_to).
On Debian bookworm (python 3.11) every shim dies with:

```text
TypeError: PurePath.relative_to() got an unexpected keyword argument 'walk_up'
```

Either document a python >= 3.12 requirement for the prelude or implement
the walk-up manually (os.path.relpath has no such restriction).
