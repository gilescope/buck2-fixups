#!/usr/bin/env bash
# Store-snapshot helpers shared by the sweep drivers (windows / mac / hetero).
#
#   store-snapshot.sh manifest <store-dir> [subdirs]
#     Emit a digest of the store's entry list (default subdirs: "ac cas").
#     CAS filenames ARE content digests and AC entries only change when an
#     action re-executes, so the sorted name list is an honest change
#     detector — no content hashing of multi-GB stores. `git hash-object`
#     is the one hasher present on all three runner OSes.
#
#   store-snapshot.sh unchanged <store-dir> <seeded-manifest-file> [subdirs]
#     Exit 0 iff the store matches the manifest recorded at seed time —
#     warm runs skip the tar + cache upload entirely (~3-7 min).
set -euo pipefail

cmd="${1:?usage: store-snapshot.sh manifest|unchanged <store-dir> [seeded-file] [subdirs]}"
store="${2:?store dir required}"

manifest() {
  # Cold store (dirs absent) hashes as the empty list, not an error.
  # shellcheck disable=SC2086 # $1 intentionally word-splits (subdir list)
  ( (cd "$store" 2>/dev/null && find $1 -type f 2>/dev/null | LC_ALL=C sort) || true ) \
    | git hash-object --stdin
}

case "$cmd" in
  manifest)
    manifest "${3:-ac cas}"
    ;;
  unchanged)
    seeded="${3:?seeded manifest file required}"
    [ -f "$seeded" ] || exit 1
    [ "$(manifest "${4:-ac cas}")" = "$(cat "$seeded")" ]
    ;;
  *)
    echo "unknown subcommand: $cmd" >&2
    exit 2
    ;;
esac
