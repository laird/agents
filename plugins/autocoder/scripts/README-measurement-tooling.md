# Fix-loop measurement tooling

Two scripts that capture and analyze per-tick cost telemetry for the
`/loop /autocoder:gate` flow. Design: see
`docs/specs/2026-05-21-fix-loop-token-efficiency-design.md` §13.

## `gate-log.py`

Invoked by `/autocoder:gate` at gate exit. Appends one JSON record per
tick to `${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/gate.jsonl`.

Record schema (spec §13.2):

```
{"ts","tick_id","outcome","model","issues_scanned","stale_swept",
 "claimed","gate_duration_ms","session_jsonl_path"}
```

`outcome` is one of `idle | triage | fix | enhance | error`.
`tick_id` is `<session_id>-<epoch_ms>`. Writes are O_APPEND atomic.

CLI:

```
gate-log.py --outcome OUT --session ID --session-jsonl PATH \
            [--model M] [--issues-scanned N] [--stale-swept N] \
            [--claimed ISSUE] [--gate-duration-ms N] [--log-path PATH]
```

## `analyze-gate-log.py`

Joins gate-log records with the Claude Code session jsonl (which
carries `message.usage.{input_tokens, cache_read_input_tokens,
cache_creation_input_tokens, output_tokens}` and `message.model`),
emits a per-tick CSV and a markdown summary aggregated per outcome
and per model.

Schema-defensive: missing fields render as `n/a`; missing in ALL
sampled records exits 2 (schema-drift); unknown usage subfields
print stderr warnings (additive Anthropic changes surface without
breaking CI).

CLI:

```
analyze-gate-log.py --gate-log PATH --session-jsonl PATH \
                    --out-csv PATH --out-md PATH
```

CSV columns: `ts, outcome, model, input_tokens, cache_read_tokens,
cache_creation_tokens, output_tokens, gate_duration_ms,
issues_scanned`.

## Sample fixtures

`tests/fixtures/sample-session.jsonl` carries golden token counts
(`input=1024, cache_read=8192, cache_creation=0, output=37`,
model `claude-sonnet-4-6`) so the analyzer's first-record output
can be asserted exactly. Refresh per spec §10 Phase 2.0 cadence
(every Claude Code version bump OR quarterly).

## Landing timings and the waste-first report

Where the time and the gate-minutes of landing changes go. Generic: rows carry ids and numbers
only (no project, branch or person names), so any project can adopt it.

### `landing-timings.py` (writer) and `landing-timings-lib.sh`

Appends one JSON row per CHANGE event, one per BATCH, one per PLAN candidate and one CI VERDICT per landed commit to
`${AUTOCODER_LANDING_TIMINGS:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/landing-timings.jsonl}`
(one O_APPEND write per line, mode 0600, no rotation). Bad input exits 2 and writes nothing; the
shell wrappers drop errors so recording never fails or delays a gate.

```
landing-timings.py [--repo ID] change --issue N --event claimed|ready|batched|landed|returned|rebase|precheck
                          [--batch ID] [--cause CAUSE] [--sha HEX] [--ts ISO]
landing-timings.py [--repo ID] batch  --batch ID --members 1,2,3 [--assembly-s N] [--stage NAME=SECS ...]
                          [--gate-s N] [--discarded-gate-s N] [--publish-s N]
                          [--verdict green|red|aborted|infra] [--cause CAUSE]
                          [--resyncs N] [--push-rejected N] [--ts ISO]
landing-timings.py [--repo ID] plan   --issue N --verdict train|skip|drop|fault --seconds S [--batch ID] [--ts ISO]
landing-timings.py [--repo ID] ci-verdict --sha HEX --conclusion C --verdict-ts ISO [--run-id ID] [--workflows A,B] [--ts ISO]
```

A `landed` row carries `--sha`, the commit now on the integration branch that carries the change
(every member of one batch names the same one); the gate and the train both pass it. A
`ci-verdict` row is the integration branch's CI verdict on one landed commit (run id, conclusion,
the time CI reached it, the workflows it was judged over), written ONCE by `landing-report.py` when
it first finds a terminal verdict; `unknown` and `pending` are refused, so a forge that could not
answer is asked again next time.

Every row names its repository: `--repo ID`, default `$AUTOCODER_LANDING_REPO`, which the gate, the
train, `enqueue.sh` and the publisher export from `repo-id-fns.sh`'s `autocoder_repo_id` (the
`<basename>-<8 hex>` every worktree of one repository shares); null in rows written before the
field existed. Two repositories on one host share the default file, and a test run from a checkout
without the test prelude's private path once left fixture rows beside a real week's.

`CAUSE` (required with `--event returned` and with a non-green verdict): `defect` (the change
itself was wrong, the only useful rejection), `conflict`, `stale-base`, `red-integration`,
`infra`, `docs-resync`, `other`. `gate_s` defaults to the sum of the stages; `discarded_gate_s` is
the gate time spent on trees a later re-sync replaced, which is waste even when the batch ends
green. A figure never measured is null, never 0.

Who writes what:

- `merge-to-integration.sh` writes, for its single-change gate, one batch of one (gate seconds,
  discarded seconds, re-syncs, rejected pushes, verdict and cause, and the stage runner's per-stage
  seconds when the gate command wrote them to the `AUTOCODER_STAGE_TIMINGS_FILE` the gate hands each
  run) plus `batched`, and `landed` (with the landed commit) or `returned`. `LANDING_CAUSE` is `defect` for a gate that fails
  only with the change, `red-integration` when the integration branch fails alone too, `conflict`
  for a conflict, `infra` for a job that ended without a verdict. A LANDING IS THE PUBLISH PROOF: a
  job killed mid-run (a memory-cap watcher's signal, a host shutdown) reaches the gate's EXIT trap
  with no outcome and `$?` of the command it interrupted, usually 0, and used to be recorded as
  `landed`; now it is `aborted`, the run in flight is counted as gate time, and the batch row says
  `aborted:infra` with the seconds spent. A train's gate ended by a signal with no verdict line at
  all is `infra` to the train (re-gated once, nobody blamed), and the train writes the lifecycle
  ledger's `gate-end aborted` when the killed gate left none.
- The queue (`merge-train.py queue` and every cycle of `merge-train-run.py`) writes a `ready` row
  the FIRST time it sees a READY, once per issue and READY comment (`ready-seen.tsv` in the train's
  state dir), with the comment's own time as the row's `ts`, so the wait after READY and the
  READY-to-landed cycle are measured from the worker's post; `enqueue.sh` writes one at its post.
  The take is the member's `batched` row (assembly, then the gate). The train's batch row carries
  the assembly seconds and, after the close-out, the publish seconds.
- A project's own queue or train script sources `landing-timings-lib.sh` and calls
  `landing_change <issue> <event> ...` as each change is claimed, marked READY, taken into a batch,
  landed or returned, and `landing_batch ...` once per batch with its stage seconds. A train that
  gates N changes as one tree writes ONE batch row naming all N members (so its gate-minutes are
  counted once) and one `batched` row per member.

### `landing-report.py`

```
landing-report.py [--since DATE | --week [DATE|last]] [--until DATE] [--bucket day|week] [--batches]
                  [--log PATH] [--json] [--repo DIR] [--repo-id ID | --all-repos]
                  [--ci auto|off] [--ci-runs-cmd CMD] [--ci-workflow NAME ...] [--integration BRANCH]
                  [--history [--merge-events PATH] ...]
```

One repository per report. The rows kept are the `--repo-id` given (strict), else those of the id
of `--repo DIR` (default: the current directory) when the ledger holds rows of it; rows naming no
repository are kept; the rows of other ids are dropped and counted on stderr (`ignored N row(s) of
other repositories (...)`). A ledger holding no row of the derived id (a copy read on another host,
an older ledger) is reported whole, with a notice naming the ids it does hold, never empty by
accident; `--all-repos` keeps every row.

A train's own gate passes are not batches: before the gate learned the train's id, every gate pass
of a train wrote a solo batch of the issue the gate runs under (`train.gateIssue` in the repository's
`.autocoder.json`) beside the train's own row, so a week's batches, landings and gate-minutes were
counted twice. A batch row whose only member is that issue, and that issue's change and plan rows,
are dropped (`--train-gate-issue N` names it, default the configured one, `0` keeps them) and the
run says how many; the train rows own the passes.

Waste leads: gate-minutes thrown away (red, aborted or infra batches, plus the gate time a
re-sync discarded) as a share of all gate-minutes, with the breakdown; changes returned at least
once, by cause, and how many returns were useful; rebases and pre-checks per landed change. Then
build time (claim to READY), wait after READY, cycle time, batch sizes, assembly/publish/stage
time, rejected pushes, red batches by cause, and a capacity-against-demand table per day or week.

`--history` reconstructs the same rows for the period before the writer existed: from the
issue tracker through `issue-fns.sh`, one `issue_get` per change that landed in the window (or
every issue with `--all-issues`; claim, READY and return comments, matched by
`--claim-regex`, `--ready-regex` and `--rules`, a JSON file of `return_pattern` and ordered
`causes`), from first-parent git history of `--integration` (commits whose subject matches
`--batch-subject-regex`, group 1 the batch id and group 2 the issue number, are the members of ONE
batch per id; any other commit starting `#N` and not excluded by `--skip-subject-regex` is a batch
of one), and from `merge-events.jsonl` (gate duration and outcome per attempt). It
uses only rows older than the first writer row, so nothing is counted twice, and
`--export-rows PATH` saves what it built. History has no gate seconds except from
merge-events, so a project whose gates are not in merge-events reads n/a for the waste share
until the writer has run.

`--week` is the WEEKLY report: one calendar week, Monday 00:00Z to the next Monday (`--week
2026-11-16` the week holding that date; a bare `--week`, or `--week last`, the last COMPLETED week,
so a Monday run reports the week that just ended). Before the sections above it prints "Week in
numbers" (batches and members, changes landed, returned by cause and dropped at planning,
gate-minutes wasted by cause, the median READY-to-landed, planning time, re-gates by reason) and a
table of every batch with each member's outcome (`landed`, `returned (<cause>)` or no outcome yet;
`--batches` adds that table to any window). A RE-GATE is a batch that gates again a change an
earlier non-green batch of the window already gated (the same members after an infrastructure
red, the halves of a bisection after a red, an innocent member gated again without the culprit);
its reason is that earlier batch's `verdict:cause`, so the gate-minutes a red costs beyond its own
run are visible. It is a ceiling: the culprit's own next gate after a `defect` return (fixed,
re-READY'd) counts too, because the ledger carries no tip to tell a fixed change from the same one.
The JSON carries the same as `batch_rows`, `regates` and `week`.

**Landing to CI verdict.** The gate is not the last word on a landing: the integration branch's own
CI runs on the landed commit, and when its runners queue, a red surfaces hours after the landing
while further landings stack on top of it. The report groups the window's `landed` rows by commit
(one LANDING per commit, however many members) and, for each landing with no cached verdict, asks
the forge ONCE for that commit's runs on `--integration` (`gh api .../actions/runs?head_sha=` in
`--repo DIR`; for another forge or a test, `--ci-runs-cmd` or `$AUTOCODER_CI_RUNS_CMD`, a command
given SHA and BRANCH that prints the commit's runs as a JSON array of `{id, name, status,
conclusion, updated_at, head_branch}`). The verdict is the first failing run's conclusion at the
time that run completed (when the red surfaced), `success` at the time the last judged run
completed, `cancelled` when every run was superseded or skipped; a run still queued or running is
`pending`, a commit with no run is `no run`, a forge that cannot be reached is `unknown`, never 0.
A terminal verdict is cached as a `ci-verdict` row, so each commit is asked about once; `pending`
and `unknown` are asked again next time. `--ci off` asks nothing and reads the cache. WHICH
WORKFLOWS ARE THE VERDICT is the repository's to say: `ciWorkflows` in its `.autocoder.json` (a
list of workflow names; `--ci-workflow NAME` overrides it) names the judging ones, because a
repository whose every push also runs a workflow that is red for reasons of its own (a release
validation with no credentials) or a code scan that takes an hour would otherwise read every
landing as red at once, or pending for an hour; the cached row records the selection it was judged
over and is not reused under another. Unset, every run on the branch counts. A landed row written
before the writer named its commit is resolved at read time from the integration branch's
first-parent log (a commit whose subject names the batch id, else the issue's own `#N` commit
within a day before the row), never rewritten. "Week in numbers" and the Time section carry
`Landing to CI verdict: p50, p75 (n of the landed commits; pending, no run, unknown, rows with no
commit); judged red by CI: N landings; landings that happened before those verdicts: M` (M counts
the other landings between a red landing and its verdict, the ones that stacked on a red nobody
had seen yet); every row of the Batches table ends with its landing's verdict and lag (`failure
2.5h (2 landed before the verdict)`). A ledger written before the landed rows carried their commit
reads `n/a (no landed row carries its commit)`; the JSON is `ci` (`lag_s` with `p75`, `red`,
`red_count`, `landings_before_red_verdicts`, each None, not 0, when the forge went unanswered).

One row per batch id: a train's gate runs `merge-to-integration.sh` with `AUTOCODER_LANDING_BATCH`
(the train's id) and `AUTOCODER_LANDING_MEMBERS` (its members) in its environment
(the train runner sets both), so the gate writes its batch row under the train's id with the
seconds, discarded gate time and re-syncs only it measures, and no change rows for the gate
issue; the train writes the verdict it judged under the same id and the members' change rows.
The report merges rows that share an id (later non-null fields win, members and stages are
unioned), so a gate is counted once. Before this, every train counted twice: a solo batch of the
gate issue from the gate beside the train's own row.
