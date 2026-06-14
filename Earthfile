VERSION 0.8
# CI targets, runnable locally: earthly +ci · earthly +build-all
# Works on amd64 and arm64 (TARGETARCH picks the right release binaries).
# trixie: the prelude's buildscript shims need python >= 3.12
# (PurePath.relative_to walk_up); bookworm ships 3.11.
FROM rust:1.94-trixie
WORKDIR /repo

tools:
    # Prebuilt buck2 (building it from source takes ~30 min); buck2 ships its
    # prelude bundled, so the binary can't drift. reindeer is built from the
    # shared_fixups PR branch (facebookincubator/reindeer#107) until it ships in
    # a release; pinned by commit for reproducibility. libssl-dev/pkg-config are
    # for reindeer's git2 dependency.
    ARG TARGETARCH
    ARG BUCK2_VERSION=2026-06-01
    ARG REINDEER_GIT=https://github.com/gilescope/reindeer
    ARG REINDEER_REV=a5a9f711abbdeafcd1e5750fb577d62d88a71edf
    RUN apt-get update && apt-get install -y --no-install-recommends \
        clang lld cmake protobuf-compiler zstd rsync python3 pkg-config libssl-dev \
        && rm -rf /var/lib/apt/lists/*
    RUN case "$TARGETARCH" in \
          amd64) TRIPLE=x86_64-unknown-linux-gnu ;; \
          arm64) TRIPLE=aarch64-unknown-linux-gnu ;; \
          *) echo "unsupported arch: $TARGETARCH" && exit 1 ;; \
        esac \
        && curl -fsSL "https://github.com/facebook/buck2/releases/download/${BUCK2_VERSION}/buck2-${TRIPLE}.zst" | zstd -d > /usr/local/bin/buck2 \
        && chmod +x /usr/local/bin/buck2 && buck2 --version
    RUN cargo install --locked --git "$REINDEER_GIT" --rev "$REINDEER_REV" reindeer \
        && reindeer --help >/dev/null

src:
    FROM +tools
    COPY --dir fixups win third-party toolchains ci ./
    COPY .buckconfig .buckroot reindeer.toml build-all.sh buckify-all.sh test-cell.sh ./

# `reindeer buckify` must be warning-free AND must not change any committed
# BUCK (main rig + every conflict rig), catching PRs that forgot to buckify.
buckify-check:
    FROM +src
    RUN ./buckify-all.sh --check

# Regenerate every rig's BUCK and write them back to the host. Used by the
# dependabot-helper workflow to fix bot PRs that bump third-party deps
# without re-running reindeer; also handy locally.
buckify:
    FROM +src
    RUN ./buckify-all.sh
    SAVE ARTIFACT third-party/BUCK AS LOCAL third-party/BUCK
    SAVE ARTIFACT third-party/conflict-rigs AS LOCAL third-party/conflict-rigs

# Prove the repo works as a buck2 cell named `fixups` (README contract).
test-cell:
    FROM +src
    RUN ./test-cell.sh

# Build specific crates by bare name, e.g. the ones whose fixups changed:
#   earthly +build-crates --crates="serde ring"
# Builds the matching alias in every rig that has it (main + conflict rigs).
# --rigs additionally builds every alias of the named conflict rig(s), for
# when a rig override targets a crate that's only transitive there:
#   earthly +build-crates --crates="quote" --rigs="third-party/conflict-rigs/sqlx"
# Skipped: names with no rig target anywhere (a fixup can exist for a crate no
# rig depends on) and full labels in the platform's expected-failures list
# (known-broken; the sweep tracks those).
build-crates:
    FROM +src
    ARG crates
    ARG rigs
    RUN available=$(buck2 uquery "kind('^alias\$', //third-party/...)" | sort -u); \
        expected=$(sed '/^#/d;/^$/d' "ci/expected-failures-$(uname -s)-$(uname -m).txt" 2>/dev/null | sort -u || true); \
        want=""; \
        for c in $crates; do \
          hits=$(echo "$available" | grep -E ":${c}\$" || true); \
          [ -z "$hits" ] && { echo "skipping $c - no rig target"; continue; }; \
          want="$want $hits"; \
        done; \
        for r in $rigs; do want="$want $(echo "$available" | grep -E "^fixups//${r}:" || true)"; done; \
        to_build=$(echo "$want" | tr ' ' '\n' | sed '/^$/d' | sort -u | comm -23 - <(echo "$expected") | tr '\n' ' '); \
        if [ -n "${to_build// /}" ]; then buck2 build $to_build; else echo "nothing to build"; fi

# Sweep every crate; failure set must match ci/expected-failures-<platform>.txt
build-all:
    FROM +src
    RUN ./build-all.sh

ci:
    BUILD +buckify-check
    BUILD +test-cell
