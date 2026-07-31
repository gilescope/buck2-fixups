#!/usr/bin/env bash
# Prepare this node's new blobs for the federated bank.
#   ci/cas-bank-publish.sh <store_dir> <role> <shard|->
# shard: the range this node is PRIMARY for (owns hex prefixes
# 2n,2n+1); '-' = spill-only (secondaries, driver, co-worker).
# Env: CAS_LINEAGE (required), GITHUB_RUN_ID, SEG_MAX_MB.
# Produces (in $BANK_WORK):
#   bank-container/     own-range segments -> artifact
#                       "cas-segs-<lineage>-<run>-<role>"
#   bank-manifest-out/  the range's NEW manifest (head from restore's
#                       own-range/ + these segments) -> artifact
#                       "cas-manifest-<lineage>-r<shard>". The caller
#                       uploads the container FIRST and gates this on
#                       that step succeeding: self-verification by
#                       step order - no banker, no reports.
#   bank-spill/         out-of-range new segments -> artifact
#                       "cas-spill-<lineage>-<run>-<role>", absorbed
#                       by range owners on later restores.
# GITHUB_OUTPUT: have=1 (container), manifest=1, spill=1.
# Diffs against bank-blobs.txt if the restore step produced one.
set -euo pipefail
mkdir -p "$1"
STORE_DIR=$(cd "$1" && pwd); ROLE="$2"; SHARD="$3"
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}"
export BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
exec ci/cas-bank.sh _tool cas-publish \
  "$STORE_DIR" "$ROLE" "$SHARD" "$CAS_LINEAGE" "${GITHUB_RUN_ID:-local}" \
  "${CAS_PARENT_LINEAGE:--}"
