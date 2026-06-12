VERSION 0.8
# CI targets, runnable locally: earthly +ci · earthly +build-all
# Works on amd64 and arm64 (TARGETARCH picks the right release binaries).
# trixie: the prelude's buildscript shims need python >= 3.12
# (PurePath.relative_to walk_up); bookworm ships 3.11.
FROM rust:1.92-trixie
WORKDIR /repo

tools:
    # Prebuilt buck2 + reindeer (building them from source takes ~30 min).
    # buck2 ships its prelude bundled in the binary, so the pair can't drift.
    ARG TARGETARCH
    ARG BUCK2_VERSION=2026-06-01
    ARG REINDEER_VERSION=v2026.04.27.00
    RUN apt-get update && apt-get install -y --no-install-recommends \
        clang lld cmake protobuf-compiler zstd rsync python3 \
        && rm -rf /var/lib/apt/lists/*
    RUN case "$TARGETARCH" in \
          amd64) TRIPLE=x86_64-unknown-linux-gnu ;; \
          arm64) TRIPLE=aarch64-unknown-linux-gnu ;; \
          *) echo "unsupported arch: $TARGETARCH" && exit 1 ;; \
        esac \
        && curl -fsSL "https://github.com/facebook/buck2/releases/download/${BUCK2_VERSION}/buck2-${TRIPLE}.zst" | zstd -d > /usr/local/bin/buck2 \
        && curl -fsSL "https://github.com/facebookincubator/reindeer/releases/download/${REINDEER_VERSION}/reindeer-${TRIPLE}.zst" | zstd -d > /usr/local/bin/reindeer \
        && chmod +x /usr/local/bin/buck2 /usr/local/bin/reindeer \
        && buck2 --version && reindeer --help >/dev/null

src:
    FROM +tools
    COPY --dir fixups win third-party toolchains ci ./
    COPY .buckconfig .buckroot reindeer.toml build-all.sh test-cell.sh ./

# `reindeer buckify` must be warning-free AND must not change the committed
# third-party/BUCK (catches PRs that forgot to re-run buckify).
buckify-check:
    FROM +src
    RUN cp third-party/BUCK /tmp/BUCK.committed; \
        output=$(reindeer buckify 2>&1); rc=$?; \
        if [ $rc -ne 0 ] || [ -n "$output" ]; then echo "buckify (exit $rc):"; echo "$output"; exit 1; fi; \
        diff -u /tmp/BUCK.committed third-party/BUCK || { echo "committed third-party/BUCK is stale — re-run reindeer buckify"; exit 1; }

# Prove the repo works as a buck2 cell named `fixups` (README contract).
test-cell:
    FROM +src
    RUN ./test-cell.sh

# Build specific crates by bare name, e.g. the ones whose fixups changed:
#   earthly +build-crates --crates="serde ring"
# Names without a top-level rig target are skipped (a fixup can exist for a
# crate the test rig doesn't depend on).
build-crates:
    FROM +src
    ARG --required crates
    RUN available=$(buck2 uquery "kind('^alias\$', //third-party:)" | sed 's|.*:||'); \
        to_build=""; \
        for c in $crates; do \
          if echo "$available" | grep -qx "$c"; then to_build="$to_build //third-party:$c"; \
          else echo "skipping $c - no rig target"; fi; \
        done; \
        if [ -n "$to_build" ]; then buck2 build $to_build; else echo "nothing to build"; fi

# Sweep every crate; failure set must match ci/expected-failures-<platform>.txt
build-all:
    FROM +src
    RUN ./build-all.sh

ci:
    BUILD +buckify-check
    BUILD +test-cell
