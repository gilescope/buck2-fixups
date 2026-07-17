# CAS bank: segments + manifests

Replaces the monolithic per-shard tarballs (`cas-shard-N`, ~1.1GB each,
re-uploaded every lap) with an append-only pool of small immutable
segments and a tiny atomic manifest per lineage. Design driven by two
laps of forensics (runs 29281833627/29291513144): the shard tarball was
the wrong atom - one torn upload staled a whole shard, the pack window
was minutes long, and lost blobs surfaced a lap later as "unservable"
mysteries.

## Objects

All artifacts live in this repo's GitHub Actions artifact pool, which
is already cross-workflow and cross-branch (restore-by-name queries all
runs). Everything except the manifest name is content-addressed.

- **Segment** `cas-seg-<sha256>`: tar.zst of store-relative blob files
  (`cas/<xx>/...`), target size `SEG_MAX_MB` (default 64). Sealed on
  write, never edited. Sidecar in the same artifact: `blobs.txt.zst`
  (sorted blob hashes inside) and `meta.json` (bytes, blob count,
  prefix bitmap).
- **Manifest** artifact `cas-manifest-<lineage>`: newest-by-created is
  HEAD for that lineage. Contains `manifest.json`:

```json
{
  "version": 1,
  "lineage": "giles-rebuck2-sweep",
  "generation": "29398083498-1",
  "parent_lineage": null,
  "parent_generation": null,
  "created_by_run": 29398083498,
  "segments": [
    {"name": "cas-seg-ab12...", "bytes": 47110000,
     "blobs": 812, "prefixes": "289af"}
  ]
}
```

  plus `blobs.txt.zst`: the full sorted blob list of the whole bank at
  this generation (union of all segments). ~2MB at today's 158k blobs.

- **Prefix bitmap** (`prefixes`): the first hex char of every blob in
  the segment, deduped, sorted - 16 possible ticks. Absence is a
  guarantee (no blob in that range), presence is a maybe. Restore
  skips segments with no overlap; over-fetch on overlap is accepted
  (compaction re-bins by prefix to pay it down).

## Lap flow (federated: no banker)

Each of the 8 ranges (shard n owns hex prefixes 2n, 2n+1) has ONE
manifest, `cas-manifest-<lineage>-r<n>`, written only by that range's
PRIMARY worker. There is no banker job: a worker verifies only itself,
by step order - the manifest upload step is gated on the container
upload step succeeding, so a manifest can never reference a container
that didn't land.

```text
restore (per worker, parallel):
  fetch all 8 range manifests (provenance-checked); union their blob
    lists -> "already banked"
  seed own range from own manifest's segments
  primaries also absorb recent cas-spill-* artifacts' own-range blobs

build: as today.

publish (per worker, post-build, always()):
  new = store blobs - union                 # exact diff, no sync
  own-range new -> segments + container + NEW range manifest
    (head = restored range manifest; uploaded container-first)
  everything else -> cas-spill-<lineage>-<run>-<role>; its range
    owner absorbs it on a later restore, where the ordinary diff
    banks it properly - absorption is a side effect of the pack,
    not machinery

driver / co-worker / secondaries: spill-only (owns nothing).
```

Failure containment: a worker dying anywhere leaves its range's
previous manifest as HEAD - stale by one lap, self-healing, and no
other range is affected. There is no job whose failure loses the whole
lap's banking (the banker had exactly that mode), and the mesh plays
no part (this deletes the finalize ack/assignment failure class
observed in the field: 5/8 and 6/8 "banked" with ack loss and an
orphaned shard).

Blast radius comparison:

| failure                 | shards (old)        | bank (new)              |
| ----------------------- | ------------------- | ----------------------- |
| worker leaves mid-pack  | whole shard stale   | one <=64MB segment      |
| torn upload             | shard stale/corrupt | segment absent, retried |
| 1 blob of churn         | ~1.1GB re-upload    | one small segment       |
| loss discovered         | next lap, mystery   | banker, before publish  |

## Lineages (main + PR layering)

A lineage is a branch's chain of manifests. PR/branch lineages set
`parent_lineage`; restore walks child-then-parent and unions. Rules:

- **Write isolation**: a lap only ever publishes to its own lineage's
  manifest. PR blobs never enter the target lineage's manifest - on
  merge, the target rebuilds and re-derives everything under its own
  trust (cache-poisoning boundary; the healing lap is the price, and
  byte-stable outputs post-/Brepro make it cheap).
- **Monotonicity**: a lineage's blob list only grows between
  compactions, and compaction only re-bins live content into new
  segments - it never removes blobs from `blobs.txt` in v1. Parent
  loss for a stale child degrades to re-execution (self-healing),
  never corruption.
- **Provenance check** (restore-time): the manifest artifact's
  creating workflow run must have `head_branch == lineage`, else it is
  ignored (one `gh api` call; blocks a hostile branch publishing under
  another lineage's name).

## Compaction (the 20% rule, owner-side)

No separate workflow: each range's PRIMARY owner compacts in its own
teardown. Its store already holds the range's full compacted view
(seeded segments + absorbed spills + the lap's new blobs), so a full
re-pack is just publish-with-empty-diff-base - segments stamped
`full`, manifest referencing only the fresh packs. The 8-way
partitioning is free: one primary per range, so the single-writer
invariant IS the work split. Fires when, for the owner's range:

- `delta_bytes > COMPACT_DELTA_PCT` (default 20) percent of
  `full_bytes`, with `COMPACT_HYSTERESIS_PCT` (default 5) so hovering
  at the boundary does not compact alternate laps, and
- `delta_bytes > COMPACT_MIN_MB` (default 256) - absolute floor so
  small ranges do not churn, or
- `delta segments > COMPACT_MAX_SEGMENTS` (default 64; FULL packs
  never count - a big range legitimately needs many, and counting
  them re-fired the trigger every lap, run 29589478222), or
- MEASURED delta-container fetch time from this lap's restore exceeds
  `COMPACT_RESTORE_BUDGET` (default 30s) - the autotuned trigger: the
  static thresholds are proxies, this is the reclaimable cost itself,
  adapting to API latency and lap cadence for free, or
- any referenced container is older than `REWARM_DAYS` (default 60) -
  the retention rewarm, using ages captured during restore's fetches.

Monotonicity gate: if the full pack would SHED blobs relative to the
old manifest (a referenced container failed to restore), the lap falls
back to a delta - newest-wins never loses history. Old segments become
unreferenced and age out with artifact retention. A child lineage
never compacts its parent's segments (that would fork shared history).

## Retention & GC

Artifacts expire (90d) - that is the pool's GC. Consequences:

- Segments referenced by a live manifest must not silently expire:
  the owner-side rewarm trigger re-packs any range whose oldest
  referenced container passes `REWARM_DAYS`. Caveat: rewarm only
  happens while laps RUN - a repo quiet for ~90d loses the bank to
  retention (the legacy shards had the same property).
- Dead lineages (closed PRs) clean themselves up by expiry.
- v2 option if expiry ever bites the hot path: move the compacted
  full packs of the default lineage to rolling release assets
  (eviction-proof, the fork-binary trick). Format unchanged.

## Migration

One-off bootstrap job: restore the current `cas-shard-0..7` artifacts,
treat the union as generation 0 (pack into prefix-binned segments,
publish the first manifest). Keeps the fleet warm through the
transition. The old shard save path is deleted in the same change -
two banking systems running together would double upload time and
confuse restores.

## Out of scope (recorded, not built)

- git-ref CAS ledger for HEAD (v1 relies on the workflow-level
  `concurrency` group serializing writers per lineage; newest-artifact
  is then race-free). Revisit if lineages ever gain parallel writers.
- Liveness-pruning GC (dropping superseded blobs at compaction) -
  needs an authoritative live set from the AC snapshot; v1 grows
  monotonically and relies on retention.
- Engine-native write-through (rebuck2 store backend speaking
  segment/manifest directly); this format is designed so that can
  adopt it unchanged.

## Implementation status (2026-07-15)

Done (committed `4c80786`, all tested locally - `ci/cas-bank-test.sh`
unit groups + `ci/cas-bank-integration-test.sh` end-to-end against a
faked `gh`, including a straggler whose container never lands):

- [x] `ci/cas-bank.sh` - pack/manifest/fetch-matching/seed/compaction
      library (deterministic USTAR via `ci/cas-bank-tool`, a zero-dep
      rust bin that owns every per-blob hot path - index/tar/link -
      so mac/win/linux packs agree; segments named by raw-tar sha so
      zstd version bumps cannot fork names)
- [x] `ci/cas-bank-restore.sh` - manifest fetch (provenance-checked) +
      prefix-subset segment restore; exit 3 = cold bank
- [x] `ci/cas-bank-publish.sh` - pack store-minus-bank into container +
      report dirs for upload
- [x] `ci/cas-bank-banker.sh` - verify containers landed, assemble +
      stage the new manifest

Wired (same commit as this note; `actionlint` clean, both local test
suites green):

- [x] `sweep-hetero.yml`: the 3x restore/seed and 3x read/pack/publish
      shard blocks replaced with `cas-bank-restore.sh` +
      `cas-bank-publish.sh` + two uploads per node (win differs only by
      the cygpath STORE/BANK_WORK lines); role =
      `<runner.os>-w<matrix.n>`; `BANK_WORK` = `$RUNNER_TEMP/bank`
      (never the repo root - watcher churn)
- [x]   legacy fallback in the restore step: on exit 3, seed from the
      old `cas-shard-N` artifact so the first bank lap bootstraps warm
- [x] driver job: publishes `$STORE/driver` and `$STORE/co-worker` as
      roles `driver`/`co-worker` (empty-range restore up front for the
      bank blob list); "Finalize shards across the fleet" deleted -
      the driver now just stops early so the fleet packs in parallel
- [x] banker job: `needs: [driver, worker-*]`, `if: always()`;
      `gh run download --pattern` then flatten (segment names are
      content-unique); skips publishing an all-empty manifest so a
      dead lap cannot mask the legacy bootstrap
- [x] `cas-compact.yml`: dispatch + weekly (schedule re-dispatches on
      the lineage ref - provenance requires head_branch == lineage);
      8 fixed prefix-pair container uploads, manifest uploaded last
      (atomicity), blob-count monotonicity gate before publishing;
      rewarm folded into the compaction trigger (any referenced
      container older than REWARM_DAYS forces a re-bin). Old
      `cas-shard-N` save path deleted in the same change.

Remaining:

- [x] first live laps (2026-07-16): bootstrap lap 29441912158 banked
      generation 1 - 476 segments, 8.1GB, 2,270,973 blobs (all 64-hex,
      zero tmp contamination), banker admitted 476 / dropped 0. Warm
      lap 29473831833: 11/11 workers restored from the bank, legacy
      fallback skipped everywhere; packs diffed to empty (admitted=0)
      and the banker carried the manifest forward as a new generation.
      Driver build failures in both laps are the pre-existing
      driver-overload class (localhost grpc keep-alive timeouts, then
      runner shutdown) - bank steps green throughout.
Federated rework (2026-07-16, banker deleted): per-range manifests
(`cas-manifest-<lineage>-r<n>`, one primary writer each),
self-verification by step order, spill/absorb for out-of-range blobs;
`cas-compact.yml` became an 8-range matrix (each range decides,
re-bins, and publishes independently; compaction is also a spill
absorption point). Migration: the pre-federation GLOBAL manifest is a
read-only parent - each range's first publish inherits its slice
(segments + blob list), after which the global can expire. Both suites
cover the choreography end-to-end (migration inherit, spill/absorb,
torn publish, subset restore) against a fake gh that runs the scripts'
REAL --jq expressions.

- [ ] remove the legacy shard fallback + global-manifest parent after
      all 8 ranges have published
- [x] compaction (2026-07-17, redesigned per Giles): NO separate
      workflow - the range owner compacts in its own teardown. Its
      store already holds the range's full view (seeded segments +
      absorbed spills + the lap's new blobs), so a full re-pack is
      publish-with-empty-diff-base, stamped `full`, manifest
      referencing only the fresh packs. Triggers: needs_compaction's
      20% rule, or any referenced container older than REWARM_DAYS
      (captured during restore's container fetches). Monotonicity
      gate: if the full pack would shed blobs vs the old manifest
      (missing-container degradation), fall back to a delta.
      cas-compact.yml deleted; PR #67 closed unmerged. Caveat: the
      bank only rewarns while laps run - a repo quiet for ~90d loses
      it to retention (same property the legacy shards had).

Perf gotcha paid for on the way (fixed 1701c70): sizing blobs
per-iteration inside the batching loop (awk scan + wc fork each) was
O(n^2) - lap 29435672672 stalled all 11 workers 30min+. Index once,
join(1), then loop.

## Dice bank (2026-07-16)

The dice value store is a CAS in sqlite clothing - `pagable.{0..15}.db`,
one table of content-addressed 128-bit keys with `INSERT OR IGNORE`
writes (shard = `key_lo & 15`) - so it banks like one: deltas export
as deterministic text segments (`dice_pack`), restores replay them
idempotently (`dice_merge`), and the 19MB byte-stable graph skeleton
rides the manifest whole. Manifest name carries a hash of the
fork-rev+seed (`cas-manifest-<lineage>-dice-<seed8>`): banked rows are
only valid within one reuse gate; a rev bump orphans them and
retention reaps. Replaces the 1.1GB-per-lap monolithic cache save
(delta laps cost tens of MB); the cache restore stays as the cold
bootstrap fallback. The driver is the only consumer, so there is no
range logic - fetch everything, merge, done.

Monotonicity protections (both live-lap incidents, both now tested):
the own-range head always MERGES the global manifest's slice (a thin
manifest published after a flaky restore would otherwise pin its
range's history manifest-invisible - the r3 incident, lap
29488124767); and an own-manifest lookup ERROR demotes the lap to
spill-only rather than reading as "absent" (newest-wins would let a
thin manifest clobber the fat one).

Known hole, self-healing: the global bank has ZERO prefix-6/7 blobs -
the bootstrap lap's shell-era pack silently no-opped on every win
worker ("nothing new to publish" after verifying 299k blobs), and
shard 3 is the only win-exclusive range. Those blobs are union-absent,
so every one that reappears on any node is re-banked automatically.

Gotchas already paid for (do not rediscover): `gh api --jq` accepts no
`--arg`/`--argjson` (interpolate); `upload-artifact` is one artifact
per step, hence the container-per-worker model; `local a="$1" b="$a"`
breaks on macOS bash 3.2; process substitution into native win
binaries fails (jq.exe cannot open MSYS /proc/N/fd paths) - use real
temp files; jq.exe emits CRLF - `tr -d '\r'` any jq output consumed
as filenames/values on a win path (a stray \r failed every [ -d ]
seed test except the final line's).
