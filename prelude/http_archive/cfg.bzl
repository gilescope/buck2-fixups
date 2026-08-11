# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

# An http_archive's output is a pure function of its download attributes
# (urls, sha256, type, strip_prefix, excludes) — target configuration never
# reaches the bytes. Yet every target platform that depends on an archive
# re-downloads and re-unpacks it under a distinct configuration hash: N
# platforms, N identical downloads, N identical unpack actions, N cache
# entries. This transition collapses every incoming configuration to one
# canonical unpack configuration so the download and unpack actions (and
# their cache hits) dedupe across target platforms.
#
# Policy lives in buckconfig, not the prelude (same pattern as
# constraint_overrides.bzl): `buck2.archive_unpack_constraints` is a
# comma-separated list of constraint-value targets that make up the
# canonical configuration. Unset (the default) disables the transition —
# archives stay in their inherited configuration and nothing changes.
#
# Repos that pin archive unpacking to one execution OS list a constraint
# their execution-platform setup keys on, e.g.
#
#   [buck2]
#   archive_unpack_constraints = myrepo//platforms:unpack-exec-linux
#
# The canonical configuration is shared by every target platform of the
# invocation, so a multi-platform build (win/linux/mac legs against one
# action cache) unpacks each archive once instead of once per platform.

def _fully_qualified(target: str) -> str:
    message = "buck2.archive_unpack_constraints entries must be fully qualified (cell//package:name), got: {}".format(target)
    if target.count("//") != 1:
        fail(message)
    cell, path = target.split("//")
    if len(cell) == 0 or path.count(":") != 1:
        fail(message)
    return target

_UNPACK_CONSTRAINTS = [
    _fully_qualified(value.strip())
    for value in read_root_config("buck2", "archive_unpack_constraints", "").split(",")
    if value.strip()
]

def _ref_name(target: str) -> str:
    return "constraint_" + "".join([c if c.isalnum() else "_" for c in target.elems()])

def _archive_unpack_impl(platform: PlatformInfo, refs: struct) -> PlatformInfo:
    if not _UNPACK_CONSTRAINTS:
        # Disabled: identity — the archive keeps its inherited configuration.
        return platform
    constraints = {}
    for target in _UNPACK_CONSTRAINTS:
        info = getattr(refs, _ref_name(target))[ConstraintValueInfo]
        constraints[info.setting.label] = info
    return PlatformInfo(
        label = "archive-unpack",
        configuration = ConfigurationInfo(constraints = constraints, values = {}),
    )

archive_unpack_transition = transition(
    impl = _archive_unpack_impl,
    refs = {_ref_name(target): target for target in _UNPACK_CONSTRAINTS},
)

def archive_unpack_constraints() -> list[str]:
    """The configured canonical-unpack constraint values (empty = off).

    tools/BUCK uses this as `target_compatible_with` for the pinned
    exec-deps target — see archive_exec_deps_default.
    """
    return _UNPACK_CONSTRAINTS

def archive_exec_deps_default():
    """Default for http_archive's `exec_deps` attr.

    Unifying the action digest across target platforms needs the SAME
    execution platform chosen in every invocation, not just the same target
    configuration. The builtin `exec_compatible_with` can't be defaulted
    from a rule decl, but exec-platform resolution also honours an exec
    dep's `target_compatible_with` — so when the transition is on, a select
    keyed on the canonical configuration's own constraints (which only the
    transitioned archive nodes carry) swaps in a tools target pinned to
    those constraints. Execution then resolves to the one registered
    platform whose configuration carries them (the repo's canonical unpack
    platform), in every leg.
    """
    if not _UNPACK_CONSTRAINTS:
        return "prelude//http_archive/tools:exec_deps"
    return select({
        "DEFAULT": "prelude//http_archive/tools:exec_deps",
        _UNPACK_CONSTRAINTS[0]: "prelude//http_archive/tools:exec_deps_unpack_pinned",
    })
