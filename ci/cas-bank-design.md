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

## Lap flow

```text
restore (per worker, parallel):
  fetch manifest chain (own lineage, then parent lineage)
  fetch segments whose prefix bitmap overlaps this worker's ranges
  untar into store; keep bank blobs.txt as "already banked"

build: as today.

pack (per worker, post-build, always()):
  new = store blobs - bank blobs.txt      # exact diff, no sync needed
  split new into <=SEG_MAX_MB tars, content-name, upload as artifacts
  upload a small report artifact: segment names + metas

bank (single "banker" job, needs: [driver, all workers], if: always()):
  collect worker reports; verify each named segment artifact exists
  new manifest = HEAD segments + verified new segments
  new blobs.txt = old + verified new blob lists
  upload cas-manifest-<lineage>            # atomic: artifact appears
                                           # whole or not at all
```

Failure containment: a worker dying mid-pack loses only its own
<=64MB segment(s); the banker references only what landed, so the
manifest never lies. The mesh plays no part in banking - the GH job
graph is the barrier (this deletes the finalize ack/assignment failure
class observed in the field: 5/8 and 6/8 "banked" with ack loss and an
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

## Compaction (the 20% rule)

Separate workflow (`cas-compact.yml`, dispatch + weekly), never inside
a sweep's finalize (a long pack window there is exactly the exposure
this design removes). Fires when, for a lineage:

- `delta_bytes > COMPACT_DELTA_PCT` (default 20) percent of
  `full_bytes`, with `COMPACT_HYSTERESIS_PCT` (default 5) so hovering
  at the boundary does not compact alternate laps, and
- `delta_bytes > COMPACT_MIN_MB` (default 256) - absolute floor so
  small lineages do not churn, or
- `segments > COMPACT_MAX_SEGMENTS` (default 64).

Compaction downloads the lineage's segments, re-bins blobs into
prefix-grouped packs of `SEG_MAX_MB`, uploads them, and publishes a
manifest whose segment list is just the new packs (same blob list).
Old segments become unreferenced and age out with artifact retention.
Only the lineage's own writer compacts it; a child lineage never
compacts its parent's segments (that would fork shared history).

All knobs are workflow env; tune without code changes.

## Retention & GC

Artifacts expire (90d) - that is the pool's GC. Consequences:

- Segments referenced by a live manifest must not silently expire: the
  weekly compaction run re-uploads (touches) any referenced segment
  older than `REWARM_DAYS` (default 60).
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
- [ ] remove the legacy fallback after a few green laps
- [ ] first compaction: needs cas-compact.yml on the default branch
      (workflow_dispatch resolves there; branch
      giles-register-cas-compact is pushed and awaits a PR). Today's
      hash-sorted segments give narrow bitmaps but each WORKER
      container spans most prefixes, so warm restores over-fetch
      (~8GB to extract ~1GB) until the first re-bin lands.

Perf gotcha paid for on the way (fixed 1701c70): sizing blobs
per-iteration inside the batching loop (awk scan + wc fork each) was
O(n^2) - lap 29435672672 stalled all 11 workers 30min+. Index once,
join(1), then loop.

Gotchas already paid for (do not rediscover): `gh api --jq` accepts no
`--arg`/`--argjson` (interpolate); `upload-artifact` is one artifact
per step, hence the container-per-worker model; `local a="$1" b="$a"`
breaks on macOS bash 3.2.
