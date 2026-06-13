#!/usr/bin/env bash
set -e -x

# Install dependencies:
rustup install nightly-2025-05-09
cargo +nightly-2025-05-09 install --git https://github.com/facebook/buck2.git buck2
# reindeer from the shared_fixups PR branch (facebookincubator/reindeer#107)
# until it ships in a release; pinned by commit.
cargo +nightly-2025-05-09 install --locked --git https://github.com/gilescope/reindeer --rev a5a9f711abbdeafcd1e5750fb577d62d88a71edf reindeer

# Test:
./test.sh
