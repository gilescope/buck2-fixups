#!/usr/bin/env bash
set -e -x

# Install dependencies:
rustup install nightly-2025-05-09
cargo +nightly-2025-05-09 install --git https://github.com/facebook/buck2.git buck2
# reindeer from the shared_fixups PR branch (facebookincubator/reindeer#107)
# until it ships in a release; pinned by commit. Its `cargo` dependency needs a
# newer rustc, so build it with a recent stable toolchain.
rustup toolchain install 1.94.0 --profile minimal
cargo +1.94.0 install --locked --git https://github.com/gilescope/reindeer --rev 53dfaa818c8dbd8403b084863f02676dec70370e reindeer

# Test:
./test.sh
