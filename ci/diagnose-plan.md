# Diagnosing the zero-dispatch sweep

Status: **FOUND — candidate 1, in the label rather than the file path.** Fixed
in `sweep-hetero.yml`; a preflight now catches the whole class in seconds. The
narrowing below is kept because it is what made the answer cheap to reach.

## The answer

`.buckconfig.local` said `execution_platforms = root//platforms:re-exec`.
**There is no `root` cell in this repo.** `.buckconfig` names the root cell
`fixups`, deliberately, so that labels fixups bakes into generated BUCK files
resolve identically in consumer projects.

```console
$ buck2 audit cell
prelude: …  toolchains: …  none: …  fixups: /…/buck2-fixups-rebuck2

$ buck2 targets root//platforms:re-exec
unknown cell alias: `root`. In cell `fixups`, known aliases are:
  buck, config, fbcode, fbsource, fixups, none, prelude, toolchains
```

The value came from rebuck's own README (`rebuck2/README.md:82`), where
`root//` is right because THAT repo's root cell is `root`. Copied here it
names a cell buck2 has never heard of, the platform never resolves, and every
action falls back to the local-only default — buck2 dials the driver, decides
there is nothing to send it, and asks nothing. Which is precisely the
signature.

Confirmed locally in seconds, and version-independently: cell aliases come
from `.buckconfig`, not the prelude, so the pinned-buck2 mismatch on a dev box
does not touch it.

**Fix**: `execution-platforms: fixups//platforms:hetero-all` — the label all
three legs already ask for, in the file value that is the one reaching action
execution.

**Not confirmed, and deliberately not chased**: whether buck2 errors on the
dangling label and something swallows it, or falls back silently. The fix is
the same either way, and the preflight below makes the distinction moot.

**Guard added** — a preflight step between the driver and the legs that reads
back what buck2 ACTUALLY resolved and proves the label parses, failing in
~30 s with a named error instead of silently at 4 h. It runs in a throwaway
isolation dir: the legs' daemon inherits env from its FIRST client, and that
client must be a leg or `BUCK2_DICE_*` persistence is lost.

**Left alone on purpose**: the legs' `-c build.execution_platforms=…`. It is
either redundant or inert, never harmful, and moving one variable per lap is
the whole point. Revisit once a lap is green.

---

Original narrowing, written 2026-08-09 at the end of a long session;
everything below is evidence, not recollection.

## The finding

Run [31299045921](https://github.com/gilescope/buck2-fixups/actions/runs/31299045921),
`driver.log` (in the `rebuck2-logs` artifact):

```text
[driver] REAPI listening on grpc://127.0.0.1:9092 (round-trip verified)
[driver] WARNING: 5m serving, 85 connection(s) accepted but ZERO requests.
         buck2 reached us and is not asking - check execution_platforms
         is in-graph, not passed via --config
```

**buck2 connects 85 times and issues no request at all.** Not one AC lookup, CAS
read or Execute. It decides against remote execution before asking anything.

## Ruled out, with evidence

| hypothesis | killed by |
| --- | --- |
| driver never bound | `round-trip verified` - the self-check completed a real `GetCapabilities` |
| wrong address / port | 85 connections arrived on `127.0.0.1:9092` |
| engine unhealthy | 12 workers joined; `ac_ok=0 ac_fail=0` means nothing arrived, not that it failed |
| a hung REAPI handler | requests never arrive, so no handler ever runs |
| too big for the timeout | `jobs dispatched: 0` - the legs did no work in 4h; they did not run out of time |

Earlier laps also fixed and eliminated: `$HOME/bin` missing (run 30736320170),
`git apply` of an already-applied prelude patch, an abbreviated action sha, and
the macOS bash 3.2 `T[@]` empty-array bug that killed all four mac workers.
Those were real, and none of them was this.

## The two candidates

Both explain "connects, asks nothing". Both are cheap to test.

### 1. buck2 is not reading the `.buckconfig.local` we write

`sweep-hetero.yml` writes it to `$IN_BUCK_ROOT/.buckconfig.local` with
`IN_BUCK_ROOT: .` - the workspace root. The legs run
`buck2 --isolation-dir sweep ...` from `build-all.sh`. If the leg's cwd or
project root differs from where the file landed, buck2 reads a config that never
mentions the engine and silently builds local-only.

Test:

```bash
# in the driver job, after the buckconfig step, before the legs
buck2 --isolation-dir sweep audit config build.execution_platforms
buck2 --isolation-dir sweep audit config buck2_re_client.engine_address
```

`audit config` reports what buck2 ACTUALLY resolved, which is the only thing
that settles this. If either is empty, the file is not being read and the fix is
`buck-root:` / cwd, not the engine.

### 2. `root//platforms:re-exec` is not remote-enabled

The config can be read correctly and still produce this: if the platform target
resolves to an `ExecutionPlatformInfo` without remote execution enabled, buck2
uses it, concludes there is nothing to talk to, and runs everything locally -
having already opened a connection.

Test:

```bash
buck2 --isolation-dir sweep audit providers root//platforms:re-exec
```

Look for `remote_enabled`. Compare against `examples/platforms/` in the rebuck
repo, which is the known-good shape for the v1 sidecar, and against whatever
`re-exec` (as opposed to `re-cache`) is meant to add.

The README's own note is the reference:

> `execution_platforms` must be in a config file, not `--config`. Passing it via
> `--config` is parser-scoped and never reaches action execution - the build
> silently uses the local-only default platform.

## Where the evidence lives

- `driver.log` is in the **`rebuck2-logs` artifact**, NOT the job log - the
  driver runs detached. Grepping the job log finds nothing and means nothing;
  that has now cost three wrong diagnoses.
- `hetero-build-logs` holds the per-leg logs.
- Fetch it:

```bash
ID=$(gh api repos/gilescope/buck2-fixups/actions/runs/<run>/artifacts \
      -q '.artifacts[] | select(.name=="rebuck2-logs") | .id')
gh api "repos/gilescope/buck2-fixups/actions/artifacts/$ID/zip" > l.zip && unzip l.zip
```

## Diagnostics now available (rebuck main d4426bb)

- **startup self-check** - the driver proves a `GetCapabilities` round trip
  against itself before announcing readiness. A driver that comes up unable to
  serve now dies in seconds with a named error instead of hanging for hours.
- **`conns=N`** in the stats heartbeat - separates "buck2 never dialled" from
  "buck2 dialled and asked nothing". These read identically in every other
  counter, which is what made this ambiguous for three laps.
- **idle warnings** every 5 idle minutes, naming which of the two worlds it is
  in and what to check. Resets when a request lands.

## Next, in order

1. ~~Add the two `audit config` / `audit providers` calls~~ — done, and as a
   permanent gate rather than a one-lap probe. It never needed a lap: `audit
   cell` answered it on a laptop.
2. ~~Fix whichever it is~~ — done, candidate 1.
3. Judge the timeout. Still open, and now genuinely testable: the legs have
   never done any work, so `timeout 15000` has never been tested against a
   real build. Expect the first green lap to be the first honest reading.

## Follow-ups noticed, not urgent

- `driver.log` is not tailed live by the driver job (it tails `leg-*.log` only),
  so every diagnostic above is readable only at teardown. Adding it to that tail
  turns an autopsy into a readout. Small change to the driver action.
- Interim banking is filed as gilescope/rebuck#8 - a lap killed by timeout banks
  nothing, so long laps cannot ratchet themselves warm. Second-order: nothing is
  being produced to bank yet.
- `sweep-hetero` as a required check on PR #66 gates a PR on a 4-hour lap. Worth
  deciding whether it should.
