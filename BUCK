# @generated by `reindeer buckify`

load("@prelude//rust:cargo_buildscript.bzl", "buildscript_run")
load("@prelude//rust:cargo_package.bzl", "cargo")

alias(
    name = "assert_matches",
    actual = ":assert_matches-1.5.0",
    visibility = ["PUBLIC"],
)

http_archive(
    name = "assert_matches-1.5.0.crate",
    sha256 = "9b34d609dfbaf33d6889b2b7106d3ca345eacad44200913df5ba02bfd31d2ba9",
    strip_prefix = "assert_matches-1.5.0",
    urls = ["https://static.crates.io/crates/assert_matches/1.5.0/download"],
    visibility = [],
)

cargo.rust_library(
    name = "assert_matches-1.5.0",
    srcs = [":assert_matches-1.5.0.crate"],
    crate = "assert_matches",
    crate_root = "assert_matches-1.5.0.crate/src/lib.rs",
    edition = "2015",
    visibility = [],
)

alias(
    name = "cc",
    actual = ":cc-1.2.19",
    visibility = ["PUBLIC"],
)

http_archive(
    name = "cc-1.2.19.crate",
    sha256 = "8e3a13707ac958681c13b39b458c073d0d9bc8a22cb1b2f4c8e55eb72c13f362",
    strip_prefix = "cc-1.2.19",
    urls = ["https://static.crates.io/crates/cc/1.2.19/download"],
    visibility = [],
)

cargo.rust_library(
    name = "cc-1.2.19",
    srcs = [":cc-1.2.19.crate"],
    crate = "cc",
    crate_root = "cc-1.2.19.crate/src/lib.rs",
    edition = "2018",
    visibility = [],
    deps = [":shlex-1.3.0"],
)

http_archive(
    name = "portable-atomic-1.11.0.crate",
    sha256 = "350e9b48cbc6b0e028b0473b114454c6316e57336ee184ceab6e53f72c178b3e",
    strip_prefix = "portable-atomic-1.11.0",
    urls = ["https://static.crates.io/crates/portable-atomic/1.11.0/download"],
    visibility = [],
)

cargo.rust_library(
    name = "portable-atomic-1.11.0",
    srcs = [":portable-atomic-1.11.0.crate"],
    crate = "portable_atomic",
    crate_root = "portable-atomic-1.11.0.crate/src/lib.rs",
    edition = "2018",
    env = {
        "CARGO_MANIFEST_DIR": "portable-atomic-1.11.0.crate",
        "CARGO_PKG_AUTHORS": "",
        "CARGO_PKG_DESCRIPTION": "Portable atomic types including support for 128-bit atomics, atomic float, etc.\n",
        "CARGO_PKG_NAME": "portable-atomic",
        "CARGO_PKG_REPOSITORY": "https://github.com/taiki-e/portable-atomic",
        "CARGO_PKG_VERSION": "1.11.0",
        "CARGO_PKG_VERSION_MAJOR": "1",
        "CARGO_PKG_VERSION_MINOR": "11",
        "CARGO_PKG_VERSION_PATCH": "0",
    },
    features = ["require-cas"],
    rustc_flags = ["@$(location :portable-atomic-1.11.0-build-script-run[rustc_flags])"],
    visibility = [],
)

cargo.rust_binary(
    name = "portable-atomic-1.11.0-build-script-build",
    srcs = [":portable-atomic-1.11.0.crate"],
    crate = "build_script_build",
    crate_root = "portable-atomic-1.11.0.crate/build.rs",
    edition = "2018",
    env = {
        "CARGO_MANIFEST_DIR": "portable-atomic-1.11.0.crate",
        "CARGO_PKG_AUTHORS": "",
        "CARGO_PKG_DESCRIPTION": "Portable atomic types including support for 128-bit atomics, atomic float, etc.\n",
        "CARGO_PKG_NAME": "portable-atomic",
        "CARGO_PKG_REPOSITORY": "https://github.com/taiki-e/portable-atomic",
        "CARGO_PKG_VERSION": "1.11.0",
        "CARGO_PKG_VERSION_MAJOR": "1",
        "CARGO_PKG_VERSION_MINOR": "11",
        "CARGO_PKG_VERSION_PATCH": "0",
    },
    features = ["require-cas"],
    visibility = [],
)

buildscript_run(
    name = "portable-atomic-1.11.0-build-script-run",
    package_name = "portable-atomic",
    buildscript_rule = ":portable-atomic-1.11.0-build-script-build",
    features = ["require-cas"],
    version = "1.11.0",
)

alias(
    name = "portable-atomic-util",
    actual = ":portable-atomic-util-0.2.4",
    visibility = ["PUBLIC"],
)

http_archive(
    name = "portable-atomic-util-0.2.4.crate",
    sha256 = "d8a2f0d8d040d7848a709caf78912debcc3f33ee4b3cac47d73d1e1069e83507",
    strip_prefix = "portable-atomic-util-0.2.4",
    urls = ["https://static.crates.io/crates/portable-atomic-util/0.2.4/download"],
    visibility = [],
)

cargo.rust_library(
    name = "portable-atomic-util-0.2.4",
    srcs = [":portable-atomic-util-0.2.4.crate"],
    crate = "portable_atomic_util",
    crate_root = "portable-atomic-util-0.2.4.crate/src/lib.rs",
    edition = "2018",
    features = ["default"],
    visibility = [],
    deps = [":portable-atomic-1.11.0"],
)

http_archive(
    name = "shlex-1.3.0.crate",
    sha256 = "0fda2ff0d084019ba4d7c6f371c95d8fd75ce3524c3cb8fb653a3023f6323e64",
    strip_prefix = "shlex-1.3.0",
    urls = ["https://static.crates.io/crates/shlex/1.3.0/download"],
    visibility = [],
)

cargo.rust_library(
    name = "shlex-1.3.0",
    srcs = [":shlex-1.3.0.crate"],
    crate = "shlex",
    crate_root = "shlex-1.3.0.crate/src/lib.rs",
    edition = "2015",
    features = [
        "default",
        "std",
    ],
    visibility = [],
)

alias(
    name = "typeid",
    actual = ":typeid-1.0.3",
    visibility = ["PUBLIC"],
)

http_archive(
    name = "typeid-1.0.3.crate",
    sha256 = "bc7d623258602320d5c55d1bc22793b57daff0ec7efc270ea7d55ce1d5f5471c",
    strip_prefix = "typeid-1.0.3",
    urls = ["https://static.crates.io/crates/typeid/1.0.3/download"],
    visibility = [],
)

cargo.rust_library(
    name = "typeid-1.0.3",
    srcs = [":typeid-1.0.3.crate"],
    crate = "typeid",
    crate_root = "typeid-1.0.3.crate/src/lib.rs",
    edition = "2018",
    visibility = [],
)

alias(
    name = "winapi",
    actual = ":winapi-0.3.9",
    visibility = ["PUBLIC"],
)

http_archive(
    name = "winapi-0.3.9.crate",
    sha256 = "5c839a674fcd7a98952e593242ea400abe93992746761e38641405d28b00f419",
    strip_prefix = "winapi-0.3.9",
    urls = ["https://static.crates.io/crates/winapi/0.3.9/download"],
    visibility = [],
)

cargo.rust_library(
    name = "winapi-0.3.9",
    srcs = [":winapi-0.3.9.crate"],
    crate = "winapi",
    crate_root = "winapi-0.3.9.crate/src/lib.rs",
    edition = "2015",
    platform = {
        "windows-gnu": dict(
            deps = [":winapi-x86_64-pc-windows-gnu-0.4.0"],
        ),
    },
    rustc_flags = ["@$(location :winapi-0.3.9-build-script-run[rustc_flags])"],
    visibility = [],
)

cargo.rust_binary(
    name = "winapi-0.3.9-build-script-build",
    srcs = [":winapi-0.3.9.crate"],
    crate = "build_script_build",
    crate_root = "winapi-0.3.9.crate/build.rs",
    edition = "2015",
    visibility = [],
)

buildscript_run(
    name = "winapi-0.3.9-build-script-run",
    package_name = "winapi",
    buildscript_rule = ":winapi-0.3.9-build-script-build",
    version = "0.3.9",
)

http_archive(
    name = "winapi-x86_64-pc-windows-gnu-0.4.0.crate",
    sha256 = "712e227841d057c1ee1cd2fb22fa7e5a5461ae8e48fa2ca79ec42cfc1931183f",
    strip_prefix = "winapi-x86_64-pc-windows-gnu-0.4.0",
    sub_targets = [
        "lib/libwinapi_ole32.a",
        "lib/libwinapi_shell32.a",
    ],
    urls = ["https://static.crates.io/crates/winapi-x86_64-pc-windows-gnu/0.4.0/download"],
    visibility = [],
)

cargo.rust_library(
    name = "winapi-x86_64-pc-windows-gnu-0.4.0",
    srcs = [":winapi-x86_64-pc-windows-gnu-0.4.0.crate"],
    crate = "winapi_x86_64_pc_windows_gnu",
    crate_root = "winapi-x86_64-pc-windows-gnu-0.4.0.crate/src/lib.rs",
    edition = "2015",
    platform = {
        "windows-gnu": dict(
            deps = [
                ":winapi-x86_64-pc-windows-gnu-0.4.0-extra_libraries-libwinapi_ole32.a",
                ":winapi-x86_64-pc-windows-gnu-0.4.0-extra_libraries-libwinapi_shell32.a",
            ],
        ),
        "windows-msvc": dict(
            deps = [
                ":winapi-x86_64-pc-windows-gnu-0.4.0-extra_libraries-libwinapi_ole32.a",
                ":winapi-x86_64-pc-windows-gnu-0.4.0-extra_libraries-libwinapi_shell32.a",
            ],
        ),
    },
    visibility = [],
)

prebuilt_cxx_library(
    name = "winapi-x86_64-pc-windows-gnu-0.4.0-extra_libraries-libwinapi_ole32.a",
    static_lib = ":winapi-x86_64-pc-windows-gnu-0.4.0.crate[lib/libwinapi_ole32.a]",
    visibility = [],
)

prebuilt_cxx_library(
    name = "winapi-x86_64-pc-windows-gnu-0.4.0-extra_libraries-libwinapi_shell32.a",
    static_lib = ":winapi-x86_64-pc-windows-gnu-0.4.0.crate[lib/libwinapi_shell32.a]",
    visibility = [],
)
