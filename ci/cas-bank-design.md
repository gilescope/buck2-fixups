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
