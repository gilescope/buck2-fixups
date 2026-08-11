# Local 3-container rebuck2 sweep rig (driver + 2 workers) — see compose/README.md.
# Deliberately mirrors the CI runners: pinned buck2, pinned rust, python3.
FROM rust:1.92-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 zstd curl ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*

# Keep in sync with the repo's BUCK2_VERSION (ci.yml / Earthfile).
ARG BUCK2_VERSION=2026-06-01
ARG TARGETARCH
RUN arch=$([ "$TARGETARCH" = "arm64" ] && echo aarch64 || echo x86_64) \
    && curl -fsSL "https://github.com/facebook/buck2/releases/download/${BUCK2_VERSION}/buck2-${arch}-unknown-linux-gnu.zst" \
       | zstd -d > /usr/local/bin/buck2 \
    && chmod +x /usr/local/bin/buck2 \
    && buck2 --version

# rebuck2 from the engine branch; bump the rev to bust the layer cache.
ARG REBUCK2_REV=8cbaf46
RUN cargo install --locked --git https://github.com/gilescope/rebuck --rev "$REBUCK2_REV" rebuck2 \
    && rebuck2 driver --help 2>&1 | head -1 || true

WORKDIR /work
