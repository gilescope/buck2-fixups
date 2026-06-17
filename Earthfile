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
# Builds the crate in every rig that has it (main + conflict + snapshot rigs),
# matching both the bare `:crate` alias (direct deps) and the versioned
# `:crate-<ver>` rust_library (crates that are only transitive in a rig, e.g.
# typenum in the dated snapshots, get no bare alias).
# --rigs additionally builds every alias of the named rig(s), for when a rig
# override targets a crate that's only transitive there:
#   earthly +build-crates --crates="quote" --rigs="third-party/conflict-rigs/sqlx"
# Skipped: names with no rig target anywhere (a fixup can exist for a crate no
# rig depends on) and full labels in the platform's expected-failures list
# (known-broken; the sweep tracks those).
build-crates:
    FROM +src
    ARG crates
    ARG rigs
    # NB: Earthly RUN executes under /bin/sh, so this stays POSIX (no process
    # substitution or bash parameter-expansion tricks).
    # The `(-[0-9]…)?` suffix matches transitive `:crate-<ver>` libraries while
    # the `-[0-9]` guard stops `:serde` catching `:serde_derive`/`:serde-json`.
    # Universe is main rig + conflict rigs only: snapshots are sweep-only (their
    # ~1900-crate era mirrors have many standalone-build failures that only the
    # matrix sweep catalogs; at PR time buckify-all --check still covers them).
    RUN available=$(buck2 uquery "kind('^(alias|rust_library)\$', //third-party: + //third-party/conflict-rigs/...)" | sort -u); \
        expected=$(sed '/^#/d;/^$/d' "ci/expected-failures-$(uname -s)-$(uname -m).txt" 2>/dev/null | sort -u || true); \
        want=""; \
        for c in $crates; do \
          hits=$(echo "$available" | grep -E ":${c}(-[0-9][0-9.]*)?\$" || true); \
          [ -z "$hits" ] && { echo "skipping $c - no rig target"; continue; }; \
          want="$want $hits"; \
        done; \
        for r in $rigs; do want="$want $(echo "$available" | grep -E "^fixups//${r}:" || true)"; done; \
        want=$(echo "$want" | tr ' ' '\n' | sed '/^$/d' | sort -u); \
        if [ -n "$expected" ]; then to_build=$(printf '%s\n' "$want" | grep -vxF "$expected" || true); else to_build="$want"; fi; \
        if [ -n "$to_build" ]; then buck2 build $to_build; else echo "nothing to build"; fi

# Sweep crates under --pattern (default: whole tree); failure set must match the
# in-scope entries of ci/expected-failures-<platform>.txt. The sweep CI passes a
# pattern per matrix leg so the big dated-snapshot rigs build in parallel:
#   earthly +build-all --pattern="//third-party/snapshots/2025-11/..."
build-all:
    FROM +src
    ARG pattern="//third-party/..."
    # word-split intentional: --pattern may hold several space-separated patterns
    # (e.g. main + conflict rigs). /bin/sh splits $pattern into argv for build-all.sh.
    # shellcheck disable=SC2086
    RUN ./build-all.sh $pattern

ci:
    BUILD +buckify-check
    BUILD +test-cell
