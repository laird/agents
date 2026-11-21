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

Appends one JSON row per CHANGE event and one per BATCH to
`${AUTOCODER_LANDING_TIMINGS:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/landing-timings.jsonl}`
(one O_APPEND write per line, mode 0600, no rotation). Bad input exits 2 and writes nothing; the
shell wrappers drop errors so recording never fails or delays a gate.

```
landing-timings.py change --issue N --event claimed|ready|batched|landed|returned|rebase|precheck
                          [--batch ID] [--cause CAUSE] [--ts ISO]
landing-timings.py batch  --batch ID --members 1,2,3 [--assembly-s N] [--stage NAME=SECS ...]
                          [--gate-s N] [--discarded-gate-s N] [--publish-s N]
                          [--verdict green|red|aborted|infra] [--cause CAUSE]
                          [--resyncs N] [--push-rejected N] [--ts ISO]
```

`CAUSE` (required with `--event returned` and with a non-green verdict): `defect` (the change
itself was wrong, the only useful rejection), `conflict`, `stale-base`, `red-integration`,
`infra`, `docs-resync`, `other`. `gate_s` defaults to the sum of the stages; `discarded_gate_s` is
the gate time spent on trees a later re-sync replaced, which is waste even when the batch ends
green. A figure never measured is null, never 0.

Who writes what:

- `merge-to-integration.sh` writes, for its single-change gate, one batch of one (gate seconds,
  discarded seconds, re-syncs, rejected pushes, verdict and cause) plus `batched`, and `landed` or
  `returned`. `LANDING_CAUSE` is `defect` for a gate that fails only with the change,
  `red-integration` when the integration branch fails alone too, `conflict` for a conflict.
- A project's own queue or train script sources `landing-timings-lib.sh` and calls
  `landing_change <issue> <event> ...` as each change is claimed, marked READY, taken into a batch,
  landed or returned, and `landing_batch ...` once per batch with its stage seconds. A train that
  gates N changes as one tree writes ONE batch row naming all N members (so its gate-minutes are
  counted once) and one `batched` row per member.

### `landing-report.py`

```
landing-report.py [--since DATE] [--until DATE] [--bucket day|week] [--log PATH] [--json]
                  [--history [--repo DIR] [--integration BRANCH] [--merge-events PATH] ...]
```

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
