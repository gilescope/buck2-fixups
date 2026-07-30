#!/usr/bin/env bash
# Stage this node's new/changed AC rows for the federated AC bank.
#   ci/ac-bank-publish.sh <store_dir> <role>
# Every node banks the rows it AUTHORED into its own role manifest -
# no ranges, no spill: an unbanked row is simply a cache miss next lap.
# Env: CAS_LINEAGE (required), GITHUB_RUN_ID, SEG_MAX_MB,
# AC_COMPACT_MIN_MB, AC_COMPACT_MAX_SEGMENTS, REWARM_DAYS, BANK_WORK.
# Produces (in $BANK_WORK):
#   ac-container/       new/changed row segments -> artifact
#                       "cas-ac-segs-<lineage>-<run>-<role>"
#   ac-manifest-out/    this role's NEW manifest -> artifact
#                       "cas-manifest-<lineage>-ac-<role>". Upload the
#                       container FIRST and gate this on it: the same
#                       self-verification-by-step-order as the blob
#                       bank - a manifest can never reference a
#                       container that did not land.
# GITHUB_OUTPUT: have=1 when there is anything to upload.
set -euo pipefail
mkdir -p "$1"
STORE_DIR=$(cd "$1" && pwd); ROLE="$2"
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}"
export BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
exec ci/cas-bank.sh _tool ac-publish \
  "$STORE_DIR" "$ROLE" "$CAS_LINEAGE" "${GITHUB_RUN_ID:-local}" \
  "${CAS_PARENT_LINEAGE:--}"
