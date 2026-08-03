# Migrating CI machinery into rebuck2

Status board for the "less shell, more rust" migration. Written so a
fresh session can pick up without the conversation.

**Goal**: everything that is rebuck2's business lives in rebuck2 - as a
`rebuck2 bank` subcommand or a composite action - so a consumer repo's
workflow contains only its own build. Secondary aim, and the one that
justified most of the work: a **windows driver mostly just works**,
because the per-OS branching (`cygpath`, `DEV_DRIVE`,
`timeout`/`gtimeout`, `tr -d '\r'` after every `jq.exe`) is a property
of writing it in shell, not of the problem.

Two repos:

- `gilescope/rebuck` - the engine and the actions (branch
  `giles-cache-dream`).
- `gilescope/buck2-fixups` - the consumer (branch
  `giles-rebuck2-sweep`, PR #66 to main).

## Where it stands

```text
ci/*.sh          2,686 -> 932   (all of it tests + one wrapper)
sweep-hetero.yml 1,220 -> 514
driver job          41 -> 12 steps  (10 consumer, 2 actions)
worker jobs      12/13 -> 4/5 steps
PR #66          +23,375 -> +20,703 lines
```

### Done

- **CAS bank** - restore, publish, packing, compaction, spill/absorb ->
  `rebuck2 bank cas-restore|cas-publish`.
- **AC bank** - restore (union across roles, parent lineage, `(lineage,
  run, role)` apply order), publish -> `bank ac-restore|ac-publish`.
- **Dice bank** - export/pack/merge/restore/publish -> `bank
  dice-*`. sqlite3 stays a subprocess.
- **Manifests** - typed serde, no jq. Compaction thresholds, rewarm,
  shed gate.
- **Artifact API** - `src/github.rs`: list, prefix-list, download +
  unzip, provenance. `GITHUB_API_URL` is the seam (GitHub sets it).
- **Composite verbs** - `bank restore` / `bank publish` do the whole
  warm/teardown path, so actions and workflows cannot drift.
- **Actions** - `driver`, `driver-finish`, `worker`, `bank-restore`,
  `bank-publish`, `runtime-env`, all rewritten against the bank. The
  pre-bank inputs (`cas-shard-artifacts`, `snapshot-key-prefix`,
  `finalize`, ...) are gone.
- **Lap B** of `ac-bank-plan.md` - the `rebuck2-ac2-*` cache pair and
  the hetero monolith fallback deleted after two green laps proved the
  bank restores 85,232 rows in 21s.
- **Fork patches** - `prelude-unpack-dedupe.patch` moved into
  `gilescope/buck2` itself (PR #1, merged to `giles-dice-persistence`)
  and split into the unpack dedupe + an unrelated buildscript exec-bit
  heal that had been riding along in the same file.

### Next, in order

1. **Cut a fork release** from `giles-dice-persistence` (now carries
   both prelude changes), bump `manifest.txt`, and ONLY THEN delete
   `ci/prelude-unpack-dedupe.patch` and the `git apply` from the four
   workflows that do it. Removing it earlier gives laps a prelude
   without the dedupe.
2. **`buck2-fork` action** - the fetch + matching-prelude swap is
   duplicated in four workflows and enforces a buck2 fact (binary and
   prelude must come from the same rev). `debug-upload.yml` does the
   swap WITHOUT the patch re-apply - check whether that is deliberate.
   The patch re-apply itself stays in the consumer: it is this repo's
   change surviving the fork's replacement.
3. **Warn on silent degradation** - if the fork release manifest
   vanishes, every workflow quietly becomes a stock-buck2 sweep with a
   different `DICE_SEED` and no dice persistence. One `::warning::`.
4. **Green lap** - see below; the last three failed on pin coupling.
5. Optional: **reusable workflow** (`workflow_call`) so a consumer
   writes one job of four lines rather than a driver job plus N worker
   jobs. Only worth doing once the actions have run green.

### What is deliberately NOT moving

- `Fetch fork buck2` + `Enable dice persistence` - which buck2, i.e.
  configuration. (The fetch half may become an action; see above.)
- `DICE_SEED` - consumer state: fork rev + a hash of the files that
  shape the graph.
- Runner ballast, swap, python pin, event-log collection - this repo's
  own tuning.
- `ci/store-snapshot.sh` - dead from the hetero sweep's point of view
  but `sweep-re.yml` and `sweep-re-mac.yml` still call it. Do not
  delete until those migrate.

## The pin coupling (three failed laps, same root)

The actions call `rebuck2 bank <verb>`; the engine must be new enough
to have that verb. Three laps died here:

- `30688047988` - workflow pinned an engine older than `cas-restore`.
- `30736320170` - the workflow passed `rebuck2-rev:
  ${{ env.REBUCK2_REV_PIN }}` into the actions, which OVERRODE the
  action's own default and reintroduced the divergence I had just
  claimed to remove.

**Fix, now in place**: the workflow passes no `rebuck2-rev` at all.
Each action defaults it to `github.action_ref` - the sha the action was
pinned at - so the engine and the actions are always the same commit.
`REBUCK2_REV_PIN` is gone from the workflow.

**The rule**: bump the action sha in the workflow and the engine comes
with it. There is one pin, not two. If you find yourself passing
`rebuck2-rev`, you are re-creating the bug.

## Verifying a lap

The bank is quiet when it works, so read these rather than the exit
code:

```text
[bank]    N own + M inherited manifests, union <blobs> blobs
[ac-bank] N role manifests (M inherited), union <rows> rows
[driver]  eager prefetch: census over N peers
```

- `driver.log` lives in the `hetero-logs`/driver-log artifact, NOT in
  the job log - the driver runs detached. Grepping the job log for
  driver output finds nothing and means nothing. This cost two wrong
  diagnoses.
- A worker publishing "no new or changed rows" on a warm lap is
  correct: nothing executed, so nothing was authored.
- 13 role manifests is the full set (driver, co-worker, 11 workers).

## Invariants worth not breaking

- **Segment name = sha256 of the RAW tar.** A changed byte in the USTAR
  layout renames every segment and re-uploads the whole bank under
  names nothing references. Pinned by a golden test in
  `bank/pack.rs`.
- **AC rows are name-stable, content-mutable.** Diff key is `(name,
  content-hash)`; apply order is `(lineage, run, role)` with the parent
  first and the driver last.
- **Write isolation.** A lineage publishes only to its own manifest
  names. Inheritance is read-only.
- **Self-verification is step ORDER.** Each manifest upload is gated on
  its container upload; there is no banker job and no lap-wide failure
  mode.
- **A lookup ERROR is not "absent".** It means unknown, and the publish
  must stage nothing rather than let newest-wins put a thin manifest
  over a fat one.
- **Containers are fetched without provenance** (lineage `-`) because
  the manifest naming them is the trust anchor, and demanding the
  lineage breaks inheritance. Content verification after seeding is
  what makes that safe.

## Bugs the migration surfaced

Kept because each is a class, not an incident:

| bug | shape |
| ----------------------------- | ----------------------------------- |
| flat `ac/` never purged | dir-only walk; the digest-keyed AC kept its poison |
| `read_text()` locale-encoded | green on linux/mac, died on win x86 |
| signed `key_hi` through awk | float arithmetic above 2^53 |
| dice `value_hex` interpolated | SQL injection from a downloaded artifact |
| addr poll ignored the marker | 1h34m dialling a dead driver |
| hot-CAS restore orphaned | its unpack step was deleted separately |
| `store-snapshot.sh` deleted | dead in one workflow, live in two others |

Two recurring shapes: **trust assumed from origin rather than checked
on arrival**, and **halves of a mechanism split across a boundary**.
