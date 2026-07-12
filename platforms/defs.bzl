# Execution platform for rebuck2 (distributed RE over iroh — see
# gilescope/rebuck). remote_enabled=True activates buck2's RE client against
# the rebuck2 driver on localhost; local_enabled=False forces every action
# through the Execution service, which is the whole point: compiles happen on
# worker runners, not on the box running buck2 (the windows-sweep OOM fix).

def _re_execution_platform_impl(ctx: AnalysisContext) -> list[Provider]:
    constraints = dict()
    constraints.update(ctx.attrs.cpu_configuration[ConfigurationInfo].constraints)
    constraints.update(ctx.attrs.os_configuration[ConfigurationInfo].constraints)
    for c in ctx.attrs.extra_constraints:
        info = c[ConstraintValueInfo]
        constraints[info.setting.label] = info
    cfg = ConfigurationInfo(constraints = constraints, values = {})

    name = ctx.label.raw_target()
    platform = ExecutionPlatformInfo(
        label = name,
        configuration = cfg,
        executor_config = CommandExecutorConfig(
            local_enabled = ctx.attrs.local_enabled,
            use_limited_hybrid = ctx.attrs.use_limited_hybrid,
            remote_enabled = True,
            remote_cache_enabled = True,
            remote_execution_use_case = "buck2-default",
            remote_execution_properties = ctx.attrs.remote_execution_properties,
            use_windows_path_separators = ctx.attrs.use_windows_path_separators,
        ),
    )

    return [
        DefaultInfo(),
        platform,
        PlatformInfo(label = str(name), configuration = cfg),
        ExecutionPlatformRegistrationInfo(platforms = [platform]),
    ]

re_execution_platform = rule(
    impl = _re_execution_platform_impl,
    attrs = {
        "cpu_configuration": attrs.dep(providers = [ConfigurationInfo]),
        "os_configuration": attrs.dep(providers = [ConfigurationInfo]),
        # False = every action must go through the RE Execution service.
        "local_enabled": attrs.bool(default = True),
        # True + local_enabled: remote preferred, local reserved for
        # local_only actions (msvc discovery/vswhere cannot run remotely).
        "use_limited_hybrid": attrs.bool(default = False),
        "use_windows_path_separators": attrs.bool(default = False),
        # REAPI platform properties: rebuck2 routes actions to matching
        # workers on OSFamily/Arch (empty = any worker; single-OS sweeps).
        "remote_execution_properties": attrs.dict(
            key = attrs.string(),
            value = attrs.string(),
            default = {},
        ),
        # Marker constraint values baked into this platform's configuration
        # (e.g. the archive-unpack pin, so exec_compatible_with can select
        # exactly this platform out of a multi-platform registration).
        "extra_constraints": attrs.list(
            attrs.dep(providers = [ConstraintValueInfo]),
            default = [],
        ),
    },
)

def _re_execution_platforms_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        ExecutionPlatformRegistrationInfo(
            platforms = [d[ExecutionPlatformInfo] for d in ctx.attrs.platforms],
        ),
    ]

# Ordered multi-platform registration: resolution picks the FIRST platform
# compatible with a target's exec constraints. Legs list their own platform
# first (business as usual for unconstrained actions) and the shared unpack
# platform after it (reached only via exec_compatible_with pinning).
re_execution_platforms = rule(
    impl = _re_execution_platforms_impl,
    attrs = {
        "platforms": attrs.list(attrs.dep(providers = [ExecutionPlatformInfo])),
    },
)
