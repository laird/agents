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
