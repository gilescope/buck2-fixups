#!/usr/bin/env bash
# Restore the dice value store + graph skeleton from the dice bank.
#   ci/dice-bank-restore.sh <dice_sweep_dir>
# Produces <dice_sweep_dir>/{db/pagable.N.db, graph.meta}.
# Env: CAS_LINEAGE, CAS_PARENT_LINEAGE (optional trunk to inherit a
# dice bank from when this lineage has none), DICE_SEED (must equal
# BUCK2_DICE_SNAPSHOT_SEED -
# banked rows are only valid within one fork-rev+seed), GH_TOKEN,
# GITHUB_REPOSITORY, BANK_WORK.
# Side effects in $BANK_WORK: dice-banked-keys.txt (for the publish
# diff), dice-head/ (manifest head dir). Exit 3 = no dice manifest for
# this lineage+seed (caller may fall back to the actions/cache dice
# snapshot for bootstrap).
set -euo pipefail
mkdir -p "$1"
DICE_DIR=$(cd "$1" && pwd)
cd "$(dirname "$0")/.."
: "${CAS_LINEAGE:?}" "${DICE_SEED:?}"
export BANK_WORK="${BANK_WORK:-$(mktemp -d)}"
exec ci/cas-bank.sh _tool dice-restore \
  "$DICE_DIR" "$CAS_LINEAGE" "$DICE_SEED" "${CAS_PARENT_LINEAGE:--}"
