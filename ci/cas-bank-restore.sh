#!/usr/bin/env bash
# Restore from the federated CAS bank (8 per-range manifests, one per
# shard, each published only by its range's primary owner).
#   ci/cas-bank-restore.sh <store_dir> <shard|->
# shard: this worker's shard number (owns hex prefixes 2n,2n+1); '-'
# fetches only the blob-list union (driver/co-worker: no seeding).
# Env: CAS_LINEAGE (required), CAS_PARENT_LINEAGE (optional: the trunk
# a branch/PR lineage inherits from - its bank seeds this store and
# joins the union, so a branch's first lap is warm and only its OWN new
# blobs are banked, under its OWN manifest), GH_TOKEN,
# GITHUB_REPOSITORY, ABSORB_SPILLS=1 (primaries only: also seed recent
# spill artifacts' own-range blobs so the next publish banks them
# properly).
# Side effects in $BANK_WORK (set it to a persistent NON-REPO dir in
# CI - stray files in the repo root churn buck2's file watcher):
#   bank-blobs.txt      union blob list of every manifest found
#   bank-manifest-rN.json  each range manifest found
#   own-range/          own manifest + blob list (publish's head dir)
# Exit 3 = no range manifests for this lineage (caller may fall back
# to the legacy monolithic shard artifacts for bootstrap).
set -euo pipefail
mkdir -p "$1"
STORE_DIR=$(cd "$1" && pwd); SHARD="$2"
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}"
export BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
exec ci/cas-bank.sh _tool cas-restore \
  "$STORE_DIR" "$SHARD" "$CAS_LINEAGE" "${CAS_PARENT_LINEAGE:--}"
