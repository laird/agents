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

## Out of scope here

Slice 3 (findings to replayable evaluations with a held-out set), slice 4 (one change at a time,
accepted when dev and held-out both improve), slice 5 (the loop's numbers on the week page).
The trace schema carries what those need: trace ids to cite, the gate and review verdicts to grade,
and the session's tool counts to compare before and after a change.

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

## Decisions

- **Compiler, not emitter.** The ledgers and transcripts already hold the steps, tool calls and
  verdicts. A reader that joins them changes nothing on the hot path, back-fills from history on
  disk, and is tested with fixture ledgers. A hook for steps only a hot path can see can come later.
- **One trace per claim, gates inside it.** The unit of behaviour is the worker's attempt.
- **Classifiers as a table.** New failure classes are rows, and the spec test checks that every
  rule has a classifier and every classifier a rule.
- **Judge off by default, prompt versioned, output parsed strictly.** A deterministic finding and a
  judged one are never mixed in a count.
