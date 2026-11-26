# Turning agent failures into tests and harness fixes: traces, behaviour spec, trace analyst

Issue #395. Slices 1 and 2 of the loop: a trace per issue attempt, compiled from the ledgers the
plugin already writes; a behaviour spec with numbered rules; a deterministic trace analyst that
turns a corpus of traces into a prioritised list of recurring failure classes, each naming the
rules it breaks, the traces that show it and the harness surface it points at.

## The loop, in this plugin's words

An agent run leaves a record. A short written spec says how the agent is supposed to behave. An
analyst reads many records against the spec and names the failures that repeat, with evidence.
Each repeated failure becomes an evaluation a machine can grade, some of which are held back. The
harness is changed one thing at a time, and a change is kept only when the evaluations it was
written against and the held-back ones both improve. The analyst then runs again on the fixed
agent's records, and the next failure comes to the top.

In this plugin the agent is a worker running the `/fix` protocol under the fix loop, and the
harness is the command protocol, the scripts it runs and the gate. The records already exist:

| Record | File | What it holds |
|---|---|---|
| Issue lifecycle | `issue-events.jsonl` | claimed, first-commit, gate-queued, gate-start, gate-end, landed, released, escalated, decomposed, verdict, verdict-nudged |
| Merge attempts | `merge-events.jsonl` | per attempt: outcome, conflicting files, failing suites, red base, escalation |
| Landing timings | `landing-timings.jsonl` | change rows: ready, batched, landed, returned with cause, rebase, precheck |
| Gate ticks | `gate.jsonl` | which tick claimed which issue, the model, the gate's duration |
| Worker transcript | `$AUTOCODER_LOG_DIR/worker-<pid>-fix-<issue>-<HHMMSS>.jsonl` | every tool call, every tool error, the terminal result (turns, cost, duration) |
| Review record | the issue's close comment | rounds, findings by tag and resolution, verdict |

Nothing joins them. The trace builder does, read-only.

## Slice 1a: the trace

One JSON object per **issue attempt**: one worker's claim of one issue, from its `claimed` event to
the terminal event that ends it (`landed`, `escalated`, `released` with no later gate) or to the
next `claimed` of the same issue. Gate attempts are steps inside it, not traces of their own, because
the behaviour under study is the worker's, and a worker that is returned twice and lands on the third
gate is one attempt with three gates.

Events of an issue with no `claimed` before them (the ledger rotated, or the claim was recorded by
an older version) open an implicit attempt whose `started` is the first event seen.

```
{"v": 1,
 "trace_id": "<repo>:<issue>:<n>",          n = ordinal of the attempt within the issue, from 1
 "repo": "<repo id>", "issue": 12, "attempt": 1,
 "worker": "<id>|null", "branch": "<branch>|null",
 "started": "<ISO>", "ended": "<ISO>|null",   ended is null while the attempt is open
 "next_attempt": "<ISO>|null",                 the next claim of the same (repo, issue), when there is one
 "outcome": "landed|returned|escalated|released|abandoned|open",
 "steps": [ {"ts": "<ISO>", "kind": "<event>", "source": "issue-events|landing-timings",
             "detail": {...}} ],                sorted by ts; the lifecycle events plus landing rebase/precheck rows
 "gates": [ {"attempt": 1, "outcome": "<merge outcome>", "duration_s": 41, "tests_failed": [...],
             "conflict_files": [...], "red_base": true|false|null, "escalated": false, "reason": "..."} ],
                                                a field no row recorded is null, never [] or false
 "returned": [ {"ts": "<ISO>", "cause": "defect|conflict|stale-base|red-integration|infra|docs-resync|other"} ],
 "session": null | {"path": "...", "model": "...", "num_turns": 7, "duration_ms": 1, "cost_usd": 0.1,
                    "is_error": false,
                    "tools": {"calls": 40, "errors": 3,
                              "by_name": {"Bash": {"calls": 30, "errors": 3}, "Edit": {"calls": 10, "errors": 0}}}},
 "review": null | {"status": "reviewed", "rounds": 1, "verdict": "pass",
                   "findings": {"important": 1, "nit": 2, "pre-existing": 0, "other": 0},
                   "resolutions": {"fixed": 2, "answered": 1, "filed": 0, "left": 0, "other": 0}}
         | {"status": "skipped" | "no record" | "unavailable"},
 "tick": null | {"tick_id": "...", "model": "...", "gate_duration_ms": 1200}}
```

The `findings` and `resolutions` keys are the ones `issue-metrics.py`'s review parser already
produces, so the two tools agree on a review record.

Outcome, decided from the steps in order:

| Outcome | When |
|---|---|
| `landed` | a `landed` step |
| `escalated` | an `escalated` step and no `landed` |
| `returned` | the last gate ended non-landed and the attempt then ended (released or re-claimed) |
| `released` | a `released` step and no gate, or a release after a gate that landed or parked |
| `abandoned` | no terminal step, a later `claimed` of the same issue by anyone, or the session's result says error |
| `open` | no terminal step and nothing later |

`ended` is the terminal step's time. When a later claim or a session error closes an attempt
that has no terminal step, `ended` is the time of the last row seen for it in any ledger.

Joins, in order of confidence:

- `merge-events.jsonl` attempt rows join a `gate-end` step by (repo, issue, attempt). An attempt row
  with no matching gate-end becomes a gate of its own (older ledgers).
- `landing-timings.jsonl` change rows join by (repo, issue) and by time: a row inside the attempt's
  window belongs to it. `returned` rows fill `returned`; `rebase` and `precheck` are steps.
- `gate.jsonl` ticks whose `claimed` names the issue (`12`, `#12` or `issue#12`) join the attempt
  whose `started` is within ten minutes after the tick. The gate log names no repository, so this
  join is by issue number and time alone.
- Transcripts join by issue number in the file name and by time. The time is the first
  `timestamp`/`ts` field in the file when one exists; the stream-json `claude -p` writes has none,
  so it is the name's HHMMSS (local time, as the worker loop stamps it) placed on the day nearest
  the attempt's start; mtime is the last resort, since a checkout resets it. It must fall inside the
  window widened by `--slack` (default 60 minutes), and a transcript belongs to the one attempt
  whose start is nearest, so a re-claimed issue's two attempts never share one. A transcript with
  no `result` event gives `tools` so far, and null `num_turns`, `duration_ms`, `cost_usd` and
  `is_error`.
- Review records come from `--comments-dir DIR` (a directory of `<issue>.json` documents as
  `issue_get` prints them, the same offline shape `issue-metrics.py --reviews` reads), parsed by the
  parser `issue-metrics.py` already has. With the directory every trace carries a record with a
  `status` (a document that cannot be read is `unavailable`, never `no record`); without it,
  `review` is null. The directory is keyed by issue number, so a run over two repositories needs
  `--repo-id`.

Writer: `trace-build.py`. Reads the four ledgers at their usual paths (each `--<name> PATH`
override, same environment variables the writers honour), `--log-dir` for transcripts,
`--comments-dir`, `--since`/`--until`, `--repo-id` (default: every repo; one trace never mixes
repos). Writes JSON lines to stdout or `--out PATH` (whole-file rewrite, never append, so a rerun
converges). The default `--out` is `traces.jsonl` beside the ledgers, under the same
`XDG_STATE_HOME` rule, and `AUTOCODER_TRACES` overrides it as the other files' variables do. The
test prelude gets a private path for it. Exit 0 with zero traces when the ledgers are empty or
missing: an empty corpus is a result, not an error. Malformed lines are skipped and counted on
stderr.

## Slice 1b: the behaviour spec

`plugins/autocoder/BEHAVIOR.md`: the rules the protocol already states, one per id, in one place.
Each rule has a stable id (`B01`, `B02`, ...), one sentence of behaviour, its source (a command file
and the exact heading, or a script), and its signal: how a trace shows the rule broken, or `judge`
when only a reader of the transcript can tell. A rule is removed by marking it retired, never by
renumbering.

The first set, from `commands/fix.md` and the gate:

| Id | Rule | Source | Signal |
|---|---|---|---|
| B01 | Work goes to the gate only after the regression suite passed on the branch | `fix.md` Verify Before Claiming | a gate fails on a suite |
| B02 | A conflict or a rejected push is rebased and relaunched, never escalated on the first time | `CLAUDE.md` Landing work; `fix.md` Landing the Work | escalated with a conflict reason after one conflict |
| B03 | The same conflict twice is escalated, not retried a third time | same | three or more conflict gates in one attempt |
| B04 | The `working` label is released only on a terminal outcome | `fix.md` Release the 'working' Label Only on a Terminal Outcome | released with no gate and no escalation; or re-claimed after release |
| B05 | A change lands only with a passing pre-landing review of the landed HEAD | `fix.md` Pre-Landing Review Gate | landed with no review record or a non-pass verdict |
| B06 | Every Important review finding is fixed or answered before landing | `fix.md` Pre-Landing Review Gate | review record with Important findings left |
| B07 | The worker does not stop or wait on a question it can answer itself | `fix.md` Continuous Loop; `monitor-workers.md` verdict watchdog | a `verdict-nudged` step |
| B08 | Immediately before launching the merge, the branch is rebased on the integration branch | `CLAUDE.md` Landing work | returned with cause `stale-base` |
| B09 | A red integration branch is not the change's fault and is not fixed by the worker | `merge-to-integration.sh` red-base check | gate with `red_base` true |
| B10 | Tool calls succeed; a tool that keeps failing is a harness fault, not something to retry blindly | `fix.md` Context Management | tool error share above a threshold |
| B11 | An attempt that opens a session ends in a gate, an escalation or an explicit release | `fix.md` Release the 'working' Label | session ended, no gate, no escalation, no release |
| B12 | Work is decomposed rather than attempted when it is too large for one attempt | `fix.md` Ultra-Complex Issues | judge |

The test (`tests/test_behavior_spec.py`) parses the table and asserts: ids are unique and
sequential, every source heading named exists in the file it names, every rule id the analyst
cites exists in the spec, and every non-`judge` rule is cited by at least one classifier. The spec
is the analyst's contract; the test keeps them from drifting apart.

## Slice 2: the trace analyst

`analyze-traces.py`: reads `traces.jsonl`, runs a table of classifiers, prints a prioritised list
of findings as markdown (default) or `--json`.

A classifier is one row of a registry, not a branch in a loop:

```
Classifier(id, rules=(...),
           surface="commands/fix.md § <heading>" | "scripts/<name>" | "gate" | "integration branch" | "tool",
           match=fn(trace) -> None | evidence-dict, group=fn(evidence) -> tuple of keys,
           weight=1.0, key_rules={key: (rules,)})
```

`match` returns evidence when the trace shows the failure (the failing suite, the cause, the
count). `group` splits a classifier's hits into findings by key (the failing suite's name, the
return cause), so "gate red on suite X" and "gate red on suite Y" are two findings with their
own traces; a trace that fails two suites joins both. `key_rules` lets one classifier cite a
different rule per key (`returned-by-cause`: defect is B01, conflict B02, stale-base B08,
red-integration B09; infra, docs-resync and other cite none). The registry is
`classifiers(tool_error_share)`, a function, so the test can import it without side effects.
A finding is:

```
{"id": "gate-red-suite", "key": "tests/test_x.sh", "rules": ["B01"], "surface": "gate",
 "count": 7, "traces": ["repo:12:1", ...], "share": 0.12,
 "evidence": [{"trace_id": ..., ...first three...}],
 "severity": <count weighted by the classifier's weight>, "judged": false}
```

The report (`--json`) is `{"corpus", "window": {"since", "until"}, "unmatched",
"judge": null | {"prompt", "traces", "errors"}, "findings": [...]}`; `--since`/`--until`
filter traces by `started`.

The first classifiers, each citing the spec:

| Id | Hits when | Group | Rules | Surface |
|---|---|---|---|---|
| `gate-red-suite` | a gate's `tests_failed` is non-empty | suite name | B01 | gate |
| `returned-by-cause` | a `returned` row | cause | B01 (defect), B08 (stale-base), B02 (conflict) | `fix.md` Landing the Work |
| `conflict-escalated-early` | escalated with a conflict in `reason` after one conflict gate | - | B02 | `fix.md` Landing the Work |
| `conflict-retried-late` | three or more conflict gates | - | B03 | same |
| `reclaimed` | the issue has a later attempt and this one did not land or escalate | - | B04 | `fix.md` Release the 'working' Label |
| `claim-bounced` | a `released` step within 120 seconds of the start, no `ready` step and no gate (#402) | - | B13 | `claim-issue.sh` |
| `landed-unreviewed` | outcome landed and review is a record with verdict other than pass, or no record when a comments dir was read | - | B05 | `fix.md` Pre-Landing Review Gate |
| `review-left-important` | review `resolutions.left` > 0 with Important findings | - | B06 | same |
| `verdict-nudged` | a `verdict-nudged` step | - | B07 | `fix.md` Continuous Loop |
| `red-base` | a gate with `red_base` true | - | B09 | integration branch |
| `tool-errors` | `session.tools.errors / calls` above `--tool-error-share` (default 0.25) with at least ten calls | the most-failing tool | B10 | the tool |
| `session-without-gate` | a session with a result and no gate, escalation or release step | - | B11 | `fix.md` Release the 'working' Label |

Priority: severity descending, then count. The markdown lists each finding with its rules, surface,
count and share of the corpus, three example trace ids with their evidence, and ends with the corpus
size, the window and the number of traces no classifier matched. A corpus of zero traces prints
that and exits 0. The JSON carries the same.

### The judged pass

Some rules (B12, and any whose signal is `judge`) need a reader. `analyze-traces.py --judge CMD`
runs `CMD` once per trace that no deterministic classifier matched (or every trace with
`--judge-all`), with the prompt on stdin: the file `plugins/autocoder/prompts/trace-judge.v1.md`,
then the spec, then the trace's JSON. `CMD` prints a JSON array of
`{"rule": "B12", "evidence": "...", "confidence": 0.0-1.0}`; anything else is a judge error,
counted and never a finding. Judged findings are grouped by rule under the id `judged`, marked
`judged: true` with `surface: null`, and sorted after the deterministic ones at equal severity.
The prompt file carries its version in its name; a new prompt is a new file, and findings record
`judge_prompt` (the file name). The default is no judge. `--spec` and `--judge-prompt` point at
the two files when they are not beside the scripts (an Antigravity install ships the scripts
without the plugin root). The test drives `--judge` with a shell fake that prints a fixed array
and one that prints garbage.

### The command

`commands/analyze-traces.md` (and its `.agent/workflows/` mirror): build the traces for a window,
run the analyst, and write the findings to `docs/reports/traces/<date>-findings.md`. It does not
file issues; a later slice turns findings into evaluations.

## Calibration from the first live run

The first run over a host's real ledgers (2,044 attempts across one swarm) showed three things
the fixtures had not:

- **A claim is written twice.** `issue_claim` records `claimed`, and the worker's readback records
  it again about four seconds later (342 of 344 two-claim issues: same worker, under two minutes).
  A `claimed` opens a new attempt only when the open attempt has ended (landed, escalated or
  released before it) or the worker differs; otherwise it is a step of the open attempt. Without
  this, two thirds of the corpus read as "reclaimed".
- **The train lands most work.** The lifecycle ledger's `landed` covered 55 issues; the
  landing-timings `landed` change rows covered 357. A landing-timings `landed` row is a terminal
  `landed` step. The rows `ready` (the worker's READY, its hand-off), `launched`, `batched` and
  `returned` are steps too, so a trace shows the hand-off and what the train did with it.
- **The train's gate issue is not an attempt.** The issue a train's gate runs under (`train.gateIssue`
  in the repository's main-worktree `.autocoder.json`) carries hundreds of claims and no work.
  `--train-gate-issue N` (default from that config, `0` keeps it) drops its traces, as
  `landing-report.py` drops its batches.

Two more, found while calibrating against the same ledgers:

- **A lost claim race writes one claim.** `fix-loop-gate.sh` claims, then checks the claim
  comments; the loser moves on without a release or a readback. Of 187 claims with no readback,
  156 had no later row from that worker on the issue. Another worker's claim opens an attempt only
  when its own readback follows within two minutes; without one it is a step of the open attempt.
  Otherwise the loser's attempt takes the winner's train landing and the winner reads as reclaimed.
- **Older landing rows name no repository.** A landing-timings row without `repo` takes the one
  repository whose other rows name its issue, so a train landing joins the attempt it belongs to.

Also seen: workers on a tmux swarm are interactive sessions, so no `worker-*-fix-*` transcript
exists and `session` is null for every trace; the tool-error and session classifiers are silent
there until a headless worker runs. `gate.jsonl` was absent, so `tick` is null.

## Slice 3: the eval author and the runner

A finding becomes evaluation cases a machine can run and grade. A **case** is a directory:

```
<cases>/dev/<case-id>/        or  <cases>/heldout/<case-id>/
  case.json                   the case: finding, verifier, issue metadata
  task.md                     the issue body the worker gets (the task prompt)
  seed/                       optional: files copied into the sandbox repository before its first commit
  setup.sh                    optional: run in the sandbox after the seed commit (ORIGIN names the bare remote),
                              for a case that needs a second actor (a conflicting commit on the integration branch)
```

`case.json`:

```
{"v": 1, "id": "conflict-escalated-early-001", "authored": "2026-11-25", "split": "dev",
 "finding": {"id": "conflict-escalated-early", "key": null, "rules": ["B02"], "traces": ["<repo>:12:1"]},
 "issue": {"title": "...", "labels": ["P2", "bug"]},
 "verify": {"outcome": "landed",                       the attempt's outcome must equal this (null: any)
            "classifiers_silent": ["conflict-escalated-early"],   none of these may fire on the attempt's trace
            "max_gates": 2, "max_tool_calls": null,   null: no bound
            "steps_present": [], "steps_absent": ["verdict-nudged"]}}
```

The verifier is declarative and behaviour-level: it reads the trace the attempt produced, never
the worker's text. It reuses the analyst's registry, so a case for finding X passes when X's
classifier stays silent on the new trace and the task still lands. The default verifier for a
finding comes from a table keyed by classifier id; the author may tighten it.

`eval-author.py`:

- `new --finding JSON | --findings-file PATH --index N [--split dev|heldout] [--cases DIR] [--id ID]`
  scaffolds a case: `case.json` with the table's verifier, `task.md` with the rule text from the spec,
  the finding's evidence and `TODO` markers where the author writes the task and the seed. Without
  `--split`, the finding's cases alternate dev, heldout, dev, so each finding gets both.
- `list [--cases DIR] [--split S]` prints the cases.
- `check [--cases DIR]` validates every case (schema, split matches its directory, no `TODO` left in
  `task.md`, every classifier in `classifiers_silent` exists, every rule exists in the spec) and
  exits 1 naming each bad case. `/author-evals` runs it before committing.

`eval-run.py [--cases DIR] [--split dev|heldout|all] [--case ID ...] [--worker CMD] [--repeat N]
[--timeout S] [--results PATH] [--keep]`, for each case and repeat:

1. A fresh root under the temp dir: a bare `origin.git`, a clone `repo/`, the case's `seed/` copied
   in, an `.autocoder.json` (`issueSource: file`, merge mode `merge`, integration branch `master`)
   unless the seed brought one, one commit, pushed to origin; then `setup.sh` if present.
2. The issue, created through the file backend from `issue.title`, `task.md` and `issue.labels`.
3. The worker, `CMD` with `{issue}`, `{repo}` and `{root}` substituted, cwd `repo/`, with
   `XDG_STATE_HOME=<root>/state` and `AUTOCODER_LOG_DIR=<root>/logs`, stdout copied to
   `logs/worker-<pid>-fix-<issue>-<HHMMSS>.jsonl` as the worker loop names it, killed at `--timeout`.
   The default `CMD` is the worker loop's own line: `claude -p --output-format stream-json --verbose
   "/autocoder:fix {issue}"`.
4. `trace-build.py` over the root's ledgers and logs; the issue's last attempt is the trace graded.
5. The verifier. One result row appended to `--results` (default
   `${AUTOCODER_EVAL_RESULTS:-$XDG_STATE_HOME/autocoder/eval-results.jsonl}`; the test prelude gets a
   private path): `{ts, case, split, repeat, pass, failed: [check names], outcome, gates, tool_calls,
   duration_s, worker, harness: {sha}, root}`. `harness.sha` is the commit of the plugin checkout the
   worker ran (`AUTOCODER_HARNESS_SHA`, else the script directory's git HEAD, else null). The root is
   deleted unless `--keep` or the case failed.

The run prints a table per case (passes of repeats) and a line per split; `--json` the same. Exit 0
whatever the verdicts; a malformed case exits 2 before any worker runs. A `--worker` that is a
shell fake makes the runner testable without a model: the tests use one that writes lifecycle
events through `issue-events-lib.sh` and a stream-json transcript, in a passing and a failing shape.

**Held-out protection.** The split is the directory. `/author-evals` writes both and tells the
author never to open `heldout/` again. Slice 4's fix-proposing step runs in a worktree with
`heldout/` removed, and only the runner, after the proposal, reads it.

Commands: `/author-evals [findings.json]` (run the analyst, scaffold a dev and a held-out case per
top finding, write each task and seed, `check`, commit) and `/run-evals [dev|heldout|all]`.

**The fake-github backend (#403).** The file backend's claim is an atomic rename, and it folds
comments into the body. So the first real finding, a claim bounced by a stale start comment, could
not be replayed in the sandbox, and B05/B06 cases were graded on outcome only. `case.json` now
takes `"backend": "file" | "fake-github"` (default `file`). Under `fake-github` the issue lives in
a per-sandbox store served by `fake-gh.py` through a `gh` shim on the worker's PATH, and
`issue.comments` (`[{"body", "age_s"}]`) stages comments backdated by `age_s` seconds. The worker
runs with `ISSUE_SOURCE=github`, so the real `issues-gh.sh` and the claim scripts run the race
check against server `createdAt`. `trace-build.py` reads the store as its `--comments-dir`. The
result row gains `backend`. Once the claim-bounce classifier exists, a claim-protocol case is a
stale start comment (`age_s: 600`) with
`verify: {"outcome": "landed", "classifiers_silent": ["claim-bounced"]}`.

## Slice 4: one harness change at a time

`/propose-fix <finding-id[:key] | case-id>` is a command protocol with one small script.

1. The agent works in a worktree of the plugin checkout with `heldout/` removed from the cases
   directory, so the proposal never sees the held-out cases.
2. It reads the finding (from the analyst's JSON), the rules it cites in `BEHAVIOR.md`, the dev
   cases for it, and the harness surface the finding names, and makes ONE change: a protocol step,
   a script, a prompt. One change, so the evaluation attributes the effect.
3. `eval-run.py --split dev` runs before the change (baseline, `harness.sha` = the worktree's base)
   and after it (`harness.sha` = the proposal commit), the same `--repeat`.
4. Only then the runner, not the agent, runs `--split heldout` on both shas.
5. `eval-decide.py --finding F --before SHA --after SHA [--results PATH] [--decisions PATH]` reads
   the result rows of the two shas, compares pass rates per split, and prints `accept` when the dev
   pass rate rose and the held-out pass rate did not fall (and rose when it was below 1), else
   `reject` with the reason; it appends one row to
   `${AUTOCODER_EVAL_DECISIONS:-$XDG_STATE_HOME/autocoder/eval-decisions.jsonl}`:
   `{ts, finding, before, after, dev: {before: [pass, runs], after: [pass, runs]}, heldout: {...},
   accepted: bool, reason}`. Equal pass rates with fewer tool calls is `accept` too (the post's second
   signal); fewer runs than `--min-runs` (default 2 per case) is `inconclusive`, never `accept`.
6. On `accept` the agent opens the plugin PR with the decision row in its body; on `reject` it
   re-runs the analyst on the after-traces (`eval-run.py --keep` roots hold them) and may refine
   once; a second reject stops and records it.

## Slice 5: the loop's numbers on the week page

`landing-report.py --week` gains a block "Self-improvement loop" in "Week in numbers" (and
`loop` in the JSON):

- **Findings**: the report runs `trace-build.py --out <tmp> --since <week start> --until <week end>`
  over the same ledgers it reads and `analyze-traces.py --traces <tmp> --json`, and prints the
  number of finding classes, the traces they cover and the top three (`id: key, count`). `--loop off`
  skips the block; a missing script prints `n/a (trace tooling not installed)`, never 0.
- **Evals**: rows of `eval-results.jsonl` whose `ts` is in the week, per split: passes of runs and
  distinct cases (`dev 12/16 passing over 4 cases; held-out 5/8 over 2`), `n/a` when no row.
- **Changes**: rows of `eval-decisions.jsonl` in the week: accepted, rejected, inconclusive, each
  with the findings they name.

The paths follow the writers' defaults and environment overrides (`AUTOCODER_TRACES`,
`AUTOCODER_EVAL_RESULTS`, `AUTOCODER_EVAL_DECISIONS`), with `--eval-results` and `--eval-decisions`
flags for a copy read elsewhere. The test prelude already privatises them.

## Changes accepted during implementation

Accepted on 2026-11-25 while landing the PR, each because the implementation found the sketch
wrong or short:

- `next_attempt` on the trace, so the `reclaimed` classifier reads one trace, not the corpus.
- Transcript time from the file name on the nearest day, not the start date: a session starts
  just before its claim is written, so "start date, or the next day" put most transcripts a day
  late. One transcript per attempt, the nearest.
- Gate fields with no merge row are null, to tell "not recorded" from "none".
- Steps come from the lifecycle ledger and the landing rows only; the merge row's detail lives on
  the gate, not as a second step for the same gate.
- `tools.by_name` counts calls and errors per tool, since the most-failing tool is what the
  finding names.
- Review records carry a `status`, use the review parser's own keys, and keep `unavailable`
  apart from `no record`.
- `group` returns a tuple of keys; `key_rules` cites one rule per return cause; judged findings
  have no surface.
- A release after a gate that landed or parked is `released`, not `open`.
- Every classifier's weight is 1.0 until a reason to rank one class above another appears.

## Operational loops' ticks (#422)

Added on 2026-11-26. The loops around a swarm leave logs nothing joins, so a fifth ledger,
`ticks.jsonl`, takes one line per run of an operational loop: `ts` (the start), `repo`, `loop`,
`run_id`, `duration_s`, `outcome` (`ok|noop|error|timeout`), `observed`, `actions`, `error`.
`tick-fns.sh` (`tick_start`, `tick_end`) and `tick-log.py` write it; neither rotates it.

Each line is a trace of `kind: "tick"`, joined to nothing, and attempt traces gain
`kind: "attempt"` with no other change to their shape. A tick trace keeps the attempt keys, null or
empty, so a reader that reads `issue` or `gates` needs no branch. Its `tick` holds
`{duration_s, observed, actions, error}`, a different shape from an attempt's gate `tick`; `kind`
tells them apart.

Attempt classifiers never see a tick. A tick classifier reads one repository's ticks of one loop at
a time, because a streak, a median and a cadence exist only across runs, and returns evidence by
trace id. Four ship: `tick-error-streak` (B14), `tick-slow` (B15), `tick-noop-only` (B16) and
`tick-missing` (B17), with the thresholds in `scripts/README-measurement-tooling.md`. Two choices
the issue left open:

- `tick-noop-only` fires once per idle loop, on its latest tick, and needs ten ticks inside the
  last day. If it fired on every tick, a five-minute loop idle for a day would score 288 and outrank
  every attempt finding.
- `tick-missing` also measures the silence after a loop's last tick, up to the corpus's latest
  tick start. Otherwise a loop that stopped for good, the case that matters most, would never fire.

A finding's share is of its own kind, so ticks do not dilute the attempts' shares. The judge reads
attempts only. Evaluation cases are attempts, so a case for a tick finding has an empty
`classifiers_silent`.

## Decisions

- **Compiler, not emitter.** The ledgers and transcripts already hold the steps, tool calls and
  verdicts. A reader that joins them changes nothing on the hot path, back-fills from history on
  disk, and is tested with fixture ledgers. A hook for steps only a hot path can see can come later.
- **One trace per claim, gates inside it.** The unit of behaviour is the worker's attempt.
- **Classifiers as a table.** New failure classes are rows, and the spec test checks that every
  rule has a classifier and every classifier a rule.
- **Judge off by default, prompt versioned, output parsed strictly.** A deterministic finding and a
  judged one are never mixed in a count.
