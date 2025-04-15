#!/usr/bin/env bash
set -e -x

# Install dependencies:
rustup install nightly-2025-02-16
cargo +nightly-2025-02-16 install --git https://github.com/facebook/buck2.git buck2
cargo +nightly-2025-02-16 install --locked --git https://github.com/facebookincubator/reindeer reindeer

# Test:
reindeer buckify
buck2 build //...
