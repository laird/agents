# Fix-loop measurement tooling

Scripts that capture and analyze per-tick cost telemetry, landing efficiency,
and agent behavior traces for the fix loop. Gate log design:
`docs/specs/2026-05-21-fix-loop-token-efficiency-design.md` §13. Trace analysis
design: `docs/specs/2026-11-25-failure-traces-design.md`.

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
                  [--issue-events PATH] [--merge-events PATH]
                  [--loop on|off] [--eval-results PATH] [--eval-decisions PATH]
                  [--history ...]
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

**The self-improvement loop.** "Week in numbers" ends with a "Self-improvement loop" block (#395),
which shows whether the loop ran this week and what it kept:

```
- Self-improvement loop:
  - Findings: 12 classes covering 7 of 12 traces; top returned-by-cause: conflict, 2; conflict-escalated-early, 1; conflict-retried-late, 1
  - Evals: dev 2/3 passing over 2 cases; held-out 1/2 passing over 1 case
  - Changes: accepted 2 (gate-red-suite:tests/test_x.sh); rejected 1 (reclaimed); inconclusive 1 (verdict-nudged)
```

- **Findings**: the report runs `trace-build.py` over the ledgers it reads itself (`--log`,
  `--issue-events` and `--merge-events`, which falls back to the writer's path,
  `${AUTOCODER_MERGE_EVENTS:-$XDG_STATE_HOME/autocoder/merge-events.jsonl}`) for the attempts that
  started in the week. It then runs `analyze-traces.py --json` on the result. The line gives the
  number of finding classes, the traces they cover out of the week's corpus, and the top three as
  `id: key, count`. The gate log and the transcripts follow `trace-build.py`'s own defaults. The
  repository is the one the report keeps (`--repo-id`, or the directory's id when the ledger holds
  rows of it; every repository under `--all-repos`).
- **Evals**: the rows of `--eval-results` (default
  `${AUTOCODER_EVAL_RESULTS:-$XDG_STATE_HOME/autocoder/eval-results.jsonl}`) whose `ts` is in the
  week, per split: passing runs out of all runs, and distinct cases.
- **Changes**: the rows of `--eval-decisions` (default
  `${AUTOCODER_EVAL_DECISIONS:-$XDG_STATE_HOME/autocoder/eval-decisions.jsonl}`, which
  `eval-decide.py` writes) whose `ts` is in the week, counted as accepted, rejected or inconclusive,
  each with the findings it names.

A figure the report cannot read prints n/a with the reason, never 0: `n/a (trace tooling not
installed)` when a trace script is not beside the report, `n/a (no eval results file)`, `n/a (no
eval run in the week)` or `n/a (no eval decisions file)`. `--loop off` drops the block. The JSON
carries it as `loop`, with `findings`, `evals` and `changes`; a figure that is n/a is
`{"na": "<reason>"}`.

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
THE JOB THAT BOUNDS THE VERDICT is named too: the judging run's jobs are read once (`gh api
.../actions/runs/<id>/jobs` in `--repo DIR`, or `--ci-jobs-cmd` / `$AUTOCODER_CI_JOBS_CMD`, a
command given RUN_ID that prints a JSON array of `{name, status, conclusion, completed_at}`), and
the bounding job is, for a red verdict, the FIRST job to complete with a red conclusion (where the
red surfaced) and, for a green one, the LAST job to complete (what the lag waited for). It is cached
on the `ci-verdict` row (`job`; a row written before this field, or a run whose jobs could not be
read, is `not read`, never a name, and the verdict is cached without it). The line ends with
`bounding job: Backend Tests (vitest) 41, lint 2 (not read for 1)`, the Batches cell reads
`failure 2.5h in Backend Tests (vitest) (2 landed before the verdict)`, and the JSON carries
`bounding_jobs` (`[{job, n}]`, by count) and `job_unread`, so a job that takes hours is a number
every Monday and the week page says what to shard.

One row per batch id: a train's gate runs `merge-to-integration.sh` with `AUTOCODER_LANDING_BATCH`
(the train's id) and `AUTOCODER_LANDING_MEMBERS` (its members) in its environment
(the train runner sets both), so the gate writes its batch row under the train's id with the
seconds, discarded gate time and re-syncs only it measures, and no change rows for the gate
issue; the train writes the verdict it judged under the same id and the members' change rows.
The report merges rows that share an id (later non-null fields win, members and stages are
unioned), so a gate is counted once. Before this, every train counted twice: a solo batch of the
gate issue from the gate beside the train's own row.

## Trace analysis and the behaviour spec

Three pieces turn agent failures into tests and harness fixes (#395; design:
`docs/specs/2026-11-25-failure-traces-design.md`). `trace-build.py` compiles one trace per issue
attempt from the ledgers above and the worker transcripts. `BEHAVIOR.md` (plugin root) states the
fix protocol's rules with stable ids. `analyze-traces.py` reads the traces against the spec and
names the failures that repeat. `/analyze-traces` runs both.

### `trace-build.py`

```
trace-build.py [--issue-events PATH] [--merge-events PATH] [--landing-timings PATH]
               [--gate-log PATH] [--ticks PATH] [--log-dir DIR] [--comments-dir DIR]
               [--out PATH|-] [--since DATE] [--until DATE] [--repo-id ID] [--slack MINUTES]
               [--repo DIR] [--train-gate-issue N]
```

An attempt is one worker's claim of one (repo, issue), up to the claim that opens the next
attempt. `claimed` is written twice per claim (`issue_claim`, then the worker's readback a few
seconds later), and a worker that loses the claim race writes it once and nothing more. So a
`claimed` opens an attempt only when none is open, the open one has ended (a landed, escalated or
released row since it started), or another worker wrote it and read it back within two minutes.
Any other `claimed` is a step of the open attempt and leaves its `started`, `worker` and
`branch` alone. Events before any claim open an implicit attempt with worker and branch null. A
trace never mixes repositories. Each trace carries `started`, `ended` (the terminal step's time,
null while open), `next_attempt` (the next attempt's claim, or null), `outcome`
(`landed|escalated|returned|released|abandoned|open`), `steps`, `gates`, `returned`, `session`,
`review` and `tick`.

- **Steps** are the lifecycle events plus the landing-timings change rows `ready` (the worker's
  hand-off), `launched`, `batched`, `landed`, `returned`, `rebase` and `precheck`. The merge
  train lands most work and records it only as a landing-timings `landed` row, so that row is a
  terminal `landed` step (detail: `batch`, `sha`) like the lifecycle one. A `released` after a
  landing is the label cleanup and leaves the outcome `landed`. A landing row from a writer that
  recorded no repository takes the one repository whose other rows name its issue.
- **Gates** start from each `gate-end` step and take `tests_failed`, `conflict_files`,
  `red_base` and `escalated` from the merge-events `attempt` row with the same attempt number.
  A merge row with no `gate-end` is a gate of its own. A field no row recorded is null. A train's
  gate records `attempt: null` on both rows; such gates pair in time order.
- **Session**: the transcript named `worker-<pid>-fix-<issue>-<HHMMSS>.jsonl` whose time (a
  `timestamp`/`ts` field, else the name's HHMMSS in local time, else mtime) falls in the
  attempt's window widened by `--slack` (default 60 minutes). It belongs to the attempt whose
  start is nearest. `tools` is `{"calls", "errors", "by_name": {"<tool>": {"calls", "errors"}}}`,
  each error charged to the tool its `tool_use_id` names. A session with no `result` event yet
  reports its tools, and `num_turns`, `duration_ms`, `cost_usd` and `is_error` are null.
- **Review**, only with `--comments-dir` (`<issue>.json` documents as `issue_get` prints them):
  `{"status": "reviewed", "rounds", "verdict", "findings", "resolutions"}`, `{"status":
  "skipped"}`, `{"status": "no record"}`, or `{"status": "unavailable"}` for a document that
  could not be read. Without the directory, `review` is null.
- **Tick**: the gate.jsonl row whose `claimed` names the issue, written in the ten minutes
  before the attempt started.

Attempt traces carry `kind: "attempt"`. Each line of `ticks.jsonl` becomes a trace of
`kind: "tick"`; see [Operational loops' ticks](#operational-loops-ticks).

`--since`/`--until` keep attempts whose start is in `[since, until)`. The train's gate issue
carries claims and no work, so its traces are dropped: `--train-gate-issue N` names it, and by
default it is `train.gateIssue` in the main-worktree `.autocoder.json` of `--repo DIR` (default:
the current directory), as `landing-report.py` reads it. `0` keeps it. One stderr line says how
many traces were dropped. Output goes to
`${AUTOCODER_TRACES:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/traces.jsonl}` (`--out -`
for stdout) as a whole-file rewrite, so a rerun converges. Missing ledgers give an empty file and
exit 0. Malformed lines are skipped and counted per ledger on one stderr line.

### `BEHAVIOR.md`

One row per rule: id (`B01`, ...), one sentence of behaviour, its source, and its signal (how a
trace shows it broken, or `judge`). Its Citations section defines the source grammar. A rule is
retired by starting its text with `Retired:`, never renumbered. `tests/test_behavior_spec.py`
checks that every citation resolves, that every rule a classifier cites exists, and that every
rule with a trace signal has a classifier.

### `analyze-traces.py`

```
analyze-traces.py [--traces PATH] [--json] [--since DATE] [--until DATE]
                  [--tool-error-share F] [--judge CMD [--judge-all] [--spec PATH] [--judge-prompt PATH]]
```

`classifiers()` returns the registry: each row has an id, the rules it cites, the surface it
points at (`commands/fix.md § <heading>`, `scripts/<name>`, `gate`, `integration branch`,
`tool` or `loop`), a `match` that returns evidence or None, and a `group` that splits hits into findings
by key (the failing suite, the return cause, the most-failing tool). `tool-errors` fires at an
error share above `--tool-error-share` (default 0.25) with at least ten calls. `claim-bounced`
fires on an attempt released within two minutes of its claim with no READY and no gate (B13,
surface `scripts/claim-issue.sh`): a claim refused or dropped before any work began (#402). A finding carries
id, key, rules, surface, count, traces, share of the corpus, three examples with evidence, and
severity (count times the classifier's weight). Findings sort by severity, then count, then
deterministic before judged. The report ends with the corpus size, the window and the traces no
classifier matched.

The judge is off by default. `--judge CMD` runs `CMD` once per trace no classifier matched (every
trace with `--judge-all`) with `prompts/trace-judge.v1.md`, then `BEHAVIOR.md`, then the trace's
JSON on stdin. `CMD` prints a JSON array of `{"rule", "evidence", "confidence"}`; a non-zero
exit, non-JSON, a non-array or an element without a string `rule` is a judge error, counted and
never a finding. Judged findings have id `judged`, key the rule, and `judge_prompt` naming the
prompt file. A new prompt is a new file.

## Operational loops' ticks

The loops around a swarm (a queue pass, a merge train's cycle hook, a health check, a sentinel
tick, a watchdog) record each run as one line of a fifth ledger (#422), so the analyst can name a
loop that keeps failing, runs slow, does nothing, or stops running. Loop ids are the writer's
choice; the plugin names none.

```
${AUTOCODER_TICKS:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/ticks.jsonl}

{"v":1,"ts":"2026-11-20T22:20:00Z","repo":"agents-3f9a1c2b","loop":"queue-pass","run_id":"03",
 "duration_s":12.3,"outcome":"ok|noop|error|timeout","observed":{"queued":4},"actions":{"claimed":1},
 "error":null}
```

`ts` is the run's start. `observed` holds what the run saw and `actions` what it did. `duration_s`
is null when the start was not recorded. The file is not rotated.

A shell loop sources `tick-fns.sh`:

```bash
source "$SCRIPT_DIR/tick-fns.sh"
tick_start queue-pass            # [run_id], default: the start time and $$
# ... the run ...
tick_end ok observed.queued=4 actions.claimed=1      # or: tick_end error error="lock held"
```

`tick_start` writes nothing; it only notes the loop, the run id and the start time. `tick_end`
writes the line, with `repo` from `autocoder_repo_id` (else the checkout's directory name) and
values that read as numbers written as numbers. `tick_end` with no `tick_start` writes
`duration_s: null` under the calling script's name. Recording is best effort: an unwritable ledger
or a bad argument writes nothing and still returns 0.

A Python loop runs `tick-log.py`, which writes the same line:

```
tick-log.py --loop L --outcome O [--run-id R] [--duration-s S] [--observed JSON] [--actions JSON]
            [--error TEXT] [--repo ID] [--ts ISO] [observed.KEY=VALUE | actions.KEY=VALUE | error=TEXT ...]
```

It exits 1 with a line on stderr when the line cannot be written, and 2 on a bad argument.

`trace-build.py` reads the ledger (`--ticks PATH`) and turns each line into a trace of
`kind: "tick"`, joined to nothing: trace id `<repo>:tick:<loop>:<run_id>`, the loop id as `worker`,
`started` the line's `ts`, `ended` the start plus `duration_s` (null when that is null), the run's
`outcome`, and `tick: {duration_s, observed, actions, error}`. The attempt keys a tick lacks are null
or empty. A line with no parseable `ts`, no `loop`, no `run_id`, or another outcome counts as
malformed. `--repo-id`, `--since` and `--until` apply to ticks too.

`analyze-traces.py`'s attempt classifiers never see a tick. Four tick classifiers read one
repository's ticks of one loop at a time, in start order, key their findings by loop id, and cite
rules B14 to B17 with surface `loop`:

| Classifier | Fires on | Rule |
|---|---|---|
| `tick-error-streak` | each tick in a run of three or more consecutive `error` or `timeout` outcomes | B14 |
| `tick-slow` | a tick that took more than five times its loop's median duration, over at least ten timed ticks | B15 |
| `tick-noop-only` | the latest tick of a loop with at least ten ticks in the corpus's last 24 hours, all `noop` (one finding per idle loop) | B16 |
| `tick-missing` | the tick before a silence longer than five times the loop's median gap, over at least ten ticks; the silence after the last tick runs to the corpus's end (`resumed: null`) | B17 |

The corpus's end is its latest tick start. A tick finding's share is of the ticks, an attempt
finding's of the attempts; the report's `ticks` counts the ticks in the corpus. The judge never
reads a tick. `landing-report.py --week` counts tick findings in its loop block as it counts any
other. A case written for a tick finding cannot name a tick classifier in `classifiers_silent`,
because the verifier reads one attempt.

## Evaluation cases

A finding becomes evaluation cases that a machine runs and grades (#395, slice 3).
`eval-author.py` writes the cases, `eval-run.py` runs them, `/author-evals` and `/run-evals`
drive the two.

A case is a directory, `<cases>/dev/<id>/` or `<cases>/heldout/<id>/`. The split is the
directory. `<cases>` is `--cases DIR`, else `AUTOCODER_EVAL_CASES`, else `.autocoder/evals` under
the repository root.

| File | What it holds |
|---|---|
| `case.json` | `{"v": 1, "id", "authored", "split", "backend"?, "finding": {"id", "key", "rules", "traces"}, "issue": {"title", "labels", "comments"?, "state"?}, "verify": {...}}` |
| `task.md` | The issue body the worker gets |
| `seed/` | Optional: files copied into the sandbox repository before its first commit |
| `setup.sh` | Optional: runs in the sandbox clone after the seed commit, with `ORIGIN` naming the bare remote, for a case that needs a second actor |

`verify` is declarative and reads only the attempt's trace. `outcome` (null: any), each
classifier in `classifiers_silent` must not match, `max_gates` and `max_tool_calls` bound the
gate count and the session's tool calls (null: no bound; a tool-call bound with no transcript
fails), `steps_present` and `steps_absent` name step kinds. The default verifier for a finding
comes from `VERIFY_DEFAULTS` in `eval-author.py`, one row per classifier in `classifiers()`;
`tests/test_eval_author.py` fails when a classifier has no row.

`backend` picks the sandbox's issue backend: `file` (the default) or `fake-github`. Use the
file backend for any finding about the work itself (a red suite, a conflict, a return). Use
`fake-github` for a finding about the claim protocol or the review record. The file backend never
runs either: its claim is an atomic rename, so the GitHub claim race (the `working` label, the
claim marker comment and the read-back by `createdAt`) is skipped, and it folds comments into
the body, so `review` is null. Under `fake-github`:

- `fake-gh.py` keeps the issue in `<root>/gh-store/<n>.json`. Each file is the document
  `gh issue view --json number,title,body,state,labels,comments,...` prints. A `gh` shim in
  `<root>/bin`, first on the worker's PATH, execs `fake-gh.py`. The shim logs every call to
  `<root>/gh.log` as `{"argv", "exit"}`. The fake answers the `issue list`, `view`, `edit`,
  `comment`, `close`, `reopen` and `create` forms that `issues-gh.sh` issues, plus `repo view`
  and the `blockedBy` GraphQL probe from `issue-deps.sh`. Any other form exits 1 with
  `fake gh: unsupported form: gh ...` on stderr.
- `issue.comments`, a list of `{"body": "...", "age_s": N}`, is posted in order before the worker
  starts, with `createdAt` set `age_s` seconds in the past. Use it to stage a stale start comment
  or an old claim marker. New comments get the wall time, because the claim race window is
  measured in server seconds. `issue.state` (`open` or `closed`) sets the issue's state.
- The worker gets `ISSUE_SOURCE=github`, and `.autocoder.json` says `issueSource: github`
  (the runner overwrites that one key in the seed's own file, under either backend).
- `trace-build.py` gets `--comments-dir <root>/gh-store`, so the review classifiers grade the
  comments the worker posted. A landed attempt with no review record is `no record`, not null.

`check` refuses an unknown `backend`, `issue.comments` or `issue.state` without `fake-github`,
and a comment that is not exactly a string `body` and a non-negative `age_s`.

### `eval-author.py`

```
eval-author.py new (--finding JSON | --findings-file PATH --index N) [--split dev|heldout]
                   [--cases DIR] [--id ID] [--spec PATH]
eval-author.py list [--cases DIR] [--split dev|heldout]
eval-author.py check [--cases DIR] [--spec PATH]
```

`new` scaffolds `case.json` with the default verifier and `task.md` with the rule text from
`BEHAVIOR.md`, the finding's evidence and `TODO` markers. `--index` is 0-based in an
`analyze-traces.py --json` report. The id defaults to `<finding id>[-<key>]-NNN`. Without
`--split`, a finding's cases alternate dev, heldout, dev. `check` exits 1 with one
`<split>/<id>: <problem>` line per defect: invalid or non-object `case.json`, an id or split that
does not match its directory, an unknown rule or classifier, an unknown `verify` key or a bad
bound, and a `TODO` left in `task.md` or `issue.title`.

### `eval-run.py`

```
eval-run.py [--cases DIR] [--split dev|heldout|all] [--case ID ...] [--worker CMD] [--repeat N]
            [--timeout S] [--results PATH] [--keep] [--json] [--spec PATH]
```

`--split` defaults to `dev`, or to `all` when `--case` names the cases. Every selected case is
checked first; a malformed or unknown case exits 2 before any worker runs. Then for each case and
repeat:

1. A fresh root under the temp dir: a bare `origin.git` and a clone `repo/` with `seed/` copied
   in. The runner adds `.autocoder.json` (`issueSource` naming the backend) and a `CLAUDE.md` with the Merge
   Mode (`merge`) and Integration Branch (`master`) sections when the seed has none. It makes one
   commit, pushes it, and runs `setup.sh`. `.issues/` is excluded from git in the clone.
2. The issue is created through the case's backend from `issue.title`, `task.md` and
   `issue.labels`. Under `fake-github` the issue's comments come from `issue.comments`.
3. The worker is `CMD` with `{issue}`, `{repo}` and `{root}` substituted (default
   `claude -p --output-format stream-json --verbose "/autocoder:fix {issue}"`). It runs in `repo/`
   with `XDG_STATE_HOME=<root>/state`, `AUTOCODER_LOG_DIR=<root>/logs`, `ISSUE_SOURCE` set to the
   backend (`file` or `github`) and no other inherited `AUTOCODER_*` or `FAKE_GH_*` variable. Its stdout goes to
   `logs/worker-<pid>-fix-<issue>-<HHMMSS>.jsonl` and its stderr to `worker.stderr`. At
   `--timeout` (default 3600 seconds) its process group gets SIGTERM, then SIGKILL.
4. `trace-build.py` compiles the root's ledgers and logs, and the issue's last attempt is graded.
   Under the file backend no `--comments-dir` is passed, because that backend folds comments into
   the body: `review` is null and the two review classifiers stay silent. Under `fake-github` the
   store is the comments dir.
5. One row is appended to `--results` (default
   `${AUTOCODER_EVAL_RESULTS:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/eval-results.jsonl}`):
   `{ts, case, split, backend, repeat, pass, failed, outcome, gates, tool_calls, duration_s, worker,
   harness: {sha}, root}`. `failed` lists `outcome`, `max_gates`, `max_tool_calls`,
   `classifiers_silent:<id>`, `steps_present:<kind>`, `steps_absent:<kind>`, `timeout`, `setup`
   (the sandbox or `setup.sh` failed) or `trace` (no attempt was recorded). `worker` is the
   command template. `harness.sha` is `AUTOCODER_HARNESS_SHA`, else the script directory's git
   HEAD, else null. A passing run's root is deleted unless `--keep`, and its `root` is then null.

The run prints one line per case (passes out of repeats, failed checks with counts), one line per
split, and the root kept for each failing run. `--json` prints `{"rows", "cases", "splits"}`. The
exit code is 0 whatever the verdicts.
`/propose-fix <finding> [harness] [repeats]` is the agent's step between the two: in a worktree
of the plugin checkout (the harness) with no held-out cases, one change for the finding, the dev
cases run before and after, then the runner scores the held-out cases on both commits and
`eval-decide.py` gives the verdict. The worker under test loads the proposal with
`claude --plugin-dir`, so the installed plugin never changes during a proposal.

### `eval-decide.py`

```
eval-decide.py --finding F --before SHA --after SHA [--results PATH] [--decisions PATH]
               [--min-runs N] [--json]
```

Decides whether to keep one harness change. It reads the eval result rows of the two harness shas
(`harness.sha`; a sha given matches a row whose sha starts with it) from `--results` (default
`${AUTOCODER_EVAL_RESULTS:-$XDG_STATE_HOME/autocoder/eval-results.jsonl}`) and compares the pass
rates per split:

| Decision | When | Exit |
|---|---|---|
| `inconclusive <reason>` | a split has no case on either sha, or a case has fewer than `--min-runs` (default 2) runs on either sha | 3 |
| `accept` | the dev pass rate rose and the held-out pass rate did not fall (and rose, when it was below 1); or both pass rates are unchanged and the mean `tool_calls` fell | 0 |
| `reject <reason>` | anything else | 1 |

Each call appends one row to `--decisions` (default
`${AUTOCODER_EVAL_DECISIONS:-$XDG_STATE_HOME/autocoder/eval-decisions.jsonl}`) in a single append:
`{ts, finding, before, after, dev: {before: [passes, runs], after: [...]}, heldout: {...},
tool_calls: {before, after}, decision, accepted, reason}`. `--json` prints that row in place of the
verdict line. The week page counts these rows.
