#!/usr/bin/env bash
# Restore action-cache rows from the federated AC bank (one manifest
# per ROLE - every node banks the rows it authored; see
# ci/ac-bank-plan.md).
#   ci/ac-bank-restore.sh <store_dir> <role> [all|own]
# all = lay down every role's rows (the driver: it is the only reader).
# own = lay down only this role's own history (workers: enough for a
#       compaction re-pack, and they never read the AC).
# Env: CAS_LINEAGE (required), CAS_PARENT_LINEAGE (optional trunk to
# inherit from - "all" mode lays its rows down UNDER this lineage's),
# GH_TOKEN, GITHUB_REPOSITORY, BANK_WORK.
# Side effects in $BANK_WORK:
#   ac-banked-rows.txt   union "<path> <sha256>" list (the publish diff)
#   own-ac/              own role manifest + row list (publish's head)
#   .ac-own-unknown      own-manifest lookup FAILED (publish must not
#                        stage a thin manifest over the fat one)
#   .ac-oldest-container created_at of the oldest container fetched
# Exit 3 = no AC manifests for this lineage (cold bank).
set -euo pipefail
mkdir -p "$1"
STORE_DIR=$(cd "$1" && pwd); ROLE="$2"; MODE="${3:-own}"
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}"
export BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
exec ci/cas-bank.sh _tool ac-restore \
  "$STORE_DIR" "$ROLE" "$MODE" "$CAS_LINEAGE" "${CAS_PARENT_LINEAGE:--}"
