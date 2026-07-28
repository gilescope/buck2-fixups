# AC bank: the ledger joins the artifacts

Status: PLANNED. Companion to `ci/cas-bank-design.md` (blobs) and its
dice-bank section (sqlite rows). This banks the third and final
load-bearing state: the action cache.

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

Dice-bank pattern, not federated-blob pattern: the driver is the only
reader and writer, so there are no ranges, no spills, no secondaries -
one manifest, whole-fetch.

- Rows: `ac/<digest>` and `acn/<key>` files in the driver store,
  ~22MB total. Name = action digest (or canonical key); content =
  encoded REAPI ActionResult.
- Artifacts: container `cas-ac-segs-<lineage>-<run>` (segments of
  rows, tar.zst via the existing deterministic USTAR tool) + manifest
  `cas-manifest-<lineage>-ac` (newest-by-created = HEAD; provenance-
  checked like every other manifest).
- Sidecar per segment: `rows.txt.zst` of `<name> <sha256(content)>`
  lines - the diff key.

## The one semantic difference from blobs

CAS blobs are content-addressed and immutable; AC rows are
NAME-stable but CONTENT-mutable (a re-executed action overwrites its
row, e.g. after a failure-purge or unservable re-derivation). Two
consequences:

1. Diff key is `(name, content-hash)`, not name alone - a changed row
   re-banks even though its name is already in the banked set.
2. Restore applies segments in GENERATION ORDER (manifest segment
   list is append-ordered) so newer rows overwrite older ones -
   last-write-wins, same as `ac_put`'s rename-over semantics.

## Lap flow

```text
driver seed (before serving):
  fetch cas-manifest-<lineage>-ac (exit-3 tolerant: cold = empty AC)
  fetch containers, lay rows into ac/ + acn/, oldest generation first
  run the existing ac-purge-failures pass (unchanged)
  keep the banked (name, hash) list for the teardown diff

driver teardown (after AC pack step today):
  new/changed = rows whose (name, hash) not in the banked list
  pack into segments -> container upload -> manifest upload
  (manifest gated on container step success - self-verification by
  step order, no banker)
```

## Compaction / growth

Rows are tiny and the set is bounded by the action graph (~68k rows,
22MB), so v1 appends deltas and lets the same owner-side trigger
machinery decide when to publish a full re-pack (needs_compaction on
the ac manifest; `full: true` stamping; the measured-overhead
autotune applies unchanged). Rewarm: any referenced container older
than REWARM_DAYS forces a full re-pack - the same 90d-defiance as the
blob bank.

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
  (old row + new row -> new content wins on restore).
- Integration (fake-gh harness): bootstrap publish, warm restore,
  delta lap with an overwritten row, torn publish (container lands,
  manifest doesn't -> old HEAD stands), failure-purge interaction
  (purged rows re-bank as changed rows next lap).

## Out of scope (recorded)

- Federating AC rows across workers (workers could serve AC lookups
  for their ranges) - engine work, no current need at 22MB.
- Banking `dice-graph.meta` history beyond the current generation.
- The hotcas monolith retirement rides the separate prefetch plan
  (`--prefetch-metadata`, lap A pending verification - note its log
  line was absent on run 30241746804, verify the flag plumbs before
  deleting the cache steps).

## Effort

Two scripts mirroring `ci/dice-bank-{restore,publish}.sh`, two-ish
workflow steps + gated manifest upload, test groups in the existing
suites. Half a day at the established loop cadence.
