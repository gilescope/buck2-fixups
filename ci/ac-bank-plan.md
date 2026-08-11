# AC bank: the ledger joins the artifacts

Status: BUILDING v2 (role-authored, federated). Companion to
`ci/cas-bank-design.md` (blobs) and its dice-bank section (sqlite
rows). This banks the third and final load-bearing state: the action
cache. v1 (driver-only, whole-fetch) is described below for the
record; we are building v2 directly.

## Why (the 2026-07-27 autopsy)

After 9 idle days, lap 30239636346 re-executed 67,822 actions over
3h13m on an UNCHANGED tree. The miss census: 461 input-drift (noise,
no discovery-class roots) vs ~110k serve-fail - identical action
digests to the previous perfect lap, results simply absent. Root
cause: GitHub Actions cache entries evict after 7 idle days, and the
AC snapshot (`rebuck2-ac2-*`) lives there. Every artifact-hosted
store survived (CAS bank, dice bank - 90d retention, refreshed each
lap); the 22MB ledger pointing INTO them was reaped, so the fleet
honestly re-derived everything. The lap after ran in 12 minutes.

The AC is the last state on evictable storage. Bank it and an idle
repo wakes warm anywhere inside 90 days.

## Shape

Every node - driver and every worker - banks the rows it AUTHORED,
into its own role manifest. "Their part" is authorship, not a hash
range, and that is what makes it free: the worker already holds the
bytes (`W2D::Done { action_result }` is encoded on the worker), so
there is no row distribution, no range map, no new mesh frames.

- Rows: `ac/<digest>` (flat) and `acn/<xx>/<key>` files in the node's
  store, ~22MB across the fleet; content = encoded REAPI ActionResult.
- Artifacts, per role: container `cas-ac-segs-<lineage>-<run>-<role>`
  (segments of rows, tar.zst via the existing deterministic USTAR
  tool) + manifest `cas-manifest-<lineage>-ac-<role>` (newest-by-
  created = HEAD for that role; provenance-checked like every other
  manifest).
- Segment layout is the CAS bank's verbatim - `bulk.tar.zst`,
  `blobs.txt.zst`, `meta.json` - so `seed_store`, `write_manifest`
  and `segments_to_fetch` are reused unchanged. For the AC a
  "blob" line is `<store-relative-path> <sha256(content)>`: the
  diff key.
- Roles are the ones the CAS bank already uses (`<os>-w<n>`,
  `driver`, `co-worker`).

## Why role-authored beats driver-only

Not the ~25s of driver teardown. Coherence: under `--locality` a row
and the blobs it references are born on the same box in the same lap,
and are now banked by the same node in the same teardown. A torn
publish loses row+blobs together (honest miss -> re-execute) instead
of banking a row whose outputs never landed - the unservable class
this repo keeps paying for (17k blob-less results, writer
28935304124; 5,390 lost to tree interiors, reader 29010597531).
Blast radius drops from "the lap's whole ledger" to one role's slice,
and the pack runs on 12 boxes in parallel instead of on the driver's
critical path.

## The one semantic difference from blobs

CAS blobs are content-addressed and immutable; AC rows are
NAME-stable but CONTENT-mutable (a re-executed action overwrites its
row). Three consequences:

1. Diff key is `(name, content-hash)`, not name alone - a changed row
   re-banks even though its name is already in the banked set.
2. Restore applies segments in GENERATION ORDER so newer rows
   overwrite older ones - last-write-wins, same as `ac_put`'s
   rename-over semantics.
3. With many writers, generation order must be TOTAL and
   deterministic. Each segment's meta carries the `run` that packed
   it and the `role` that owns it; the driver sorts
   `(run asc, role asc, driver LAST)` and untars in that order. The
   driver goes last because its row is the normalized one
   (`ensure_execution_metadata`) and it is the only node that serves.

## Lap flow

```text
every node, seed (before building):
  fetch own role manifest -> segments -> lay rows into ac/ + acn/
  driver ALSO fetches every other role manifest and lays those first,
    in (run, role) order, driver's own last
  run ac-purge-failures over ac/ + acn/
  keep the union (name, hash) list for the teardown diff

build: workers write ac/<digest> for every action they execute that
  is cacheable (exit 0, not do_not_cache). The driver writes rows as
  it always has - digest-keyed and canonical (acn/).

every node, teardown (always()):
  purge failure rows, then diff: new/changed = rows whose
    (name, hash) is not in the union
  pack into segments -> container upload -> manifest upload
  (manifest gated on container step success - self-verification by
  step order, no banker)
```

Worker stores are seeded with their own history so a rewarm/compaction
re-pack has the full view locally; ~2MB per role, so the fetch is
noise. Workers never READ the AC - the driver remains the only
consumer at runtime, so there is no lookup RTT anywhere.

## Compaction / growth

Rows are tiny and the set is bounded by the action graph (~68k rows,
22MB fleet-wide), so v1 appends deltas and lets the same owner-side
trigger machinery decide when to publish a full re-pack
(`needs_compaction` on the role's manifest; `full: true` stamping;
the measured-overhead autotune applies unchanged). Rewarm: any
referenced container older than REWARM_DAYS forces a full re-pack -
the same 90d-defiance as the blob bank.

A role that disappears (matrix change) stops rewarming its manifest;
its rows expire at 90d and re-derive. Self-healing, but note that AC
warmth now sits on 12 retention clocks rather than one.

## Migration & rollout

1. Lap A: scripts + steps land; bank restore is additive (actions
   cache restore still runs; bank rows lay down first, cache snapshot
   overwrites - both warm paths active). Publish starts immediately.
2. Lap B (after one green lap): delete the `rebuck2-ac2-*` cache
   save/restore steps. The 22MB pack step goes with them; teardown
   gets ~25s back.
3. The store-snapshot "AC unchanged - skip pack" optimization carries
   over: no new rows and no changed rows -> no container, no manifest
   bump (same as a range owner with nothing new).

## Tests

- Unit: row diff by (name, hash) - changed content re-banks under the
  same name; unchanged set packs nothing; generation-order overwrite
  (old row + new row -> new content wins on restore); flat `ac/` rows
  and nested `acn/xx/` rows both index and round-trip.
- Integration (fake-gh harness): bootstrap publish, warm restore,
  delta lap with an overwritten row, torn publish (container lands,
  manifest doesn't -> old HEAD stands), multi-role union restore with
  a cross-role name collision resolved by (run, role) order.

## Out of scope (recorded)

- SERVING federation (workers answering AC lookups for a range).
  Rejected, not deferred: `validated_ac_get` is the driver's hottest
  path and a row is a page-cache read; a mesh RTT there buys nothing
  at 22MB and the driver-overload class is grpc/relay pressure.
- Content-addressing the row payload (row file holds a sha, bytes ride
  the blob bank). Considered (rejected: it dedups acn/ac twins but
  gives up the row/blob co-location that is the whole point of v2).
- Banking `dice-graph.meta` history beyond the current generation.
- The hotcas monolith retirement rides the separate prefetch plan
  (`--prefetch-metadata`, lap A pending verification - note its log
  line was absent on run 30241746804, verify the flag plumbs before
  deleting the cache steps).

## v1, for the record (not built)

Driver-only: one manifest, whole-fetch, no roles, no ordering rules -
the dice-bank pattern. Half a day, and it fixes the eviction outage
just as well. We skipped it because v2's coherence property is the
part that stops the unservable class recurring, and the extra
machinery is one sort key and a per-role loop.
