#!/usr/bin/env bash
set -e -x

# Install dependencies:
rustup install nightly-2025-05-09
cargo +nightly-2025-05-09 install --git https://github.com/facebook/buck2.git buck2
cargo +nightly-2025-05-09 install --locked --git https://github.com/facebookincubator/reindeer reindeer

# Test:
./test.sh
