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
