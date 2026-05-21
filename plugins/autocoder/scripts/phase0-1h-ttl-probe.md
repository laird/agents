# Phase 0 — 1-hour TTL probe runbook

**Purpose:** Decide which cache-TTL / cadence pairing becomes the new
`/fix-loop` default. Spec reference:
`docs/specs/2026-05-21-fix-loop-token-efficiency-design.md` §10 Phase 0
and §13.4 Phase 0 acceptance.

The deterministic code change (default `IDLE_SLEEP_MINUTES=4`) has
already shipped on this branch. This runbook describes the runtime
experiment an operator runs to *validate* that choice against the
alternative (55-min cadence + `cache_control: { ttl: "1h" }` writes).

## Prerequisites

- `feat/fix-loop-token-efficiency` checked out.
- A fixture committed at `tests/fixtures/queue-state-p2-bug.sh`
  (Phase 2.0 deliverable; experiment cannot run until that lands).
- Phase 2.0 measurement tooling green (`gate-log.py`,
  `analyze-gate-log.py`).

## The two runs

Run both against the **same fixture**, ideally back-to-back so traffic
mix is comparable. Each run is a few hours so cache-warm behavior
stabilizes.

```bash
# A) New default: 4-min cadence, 5-min TTL
plugins/autocoder/scripts/run-phase-experiment.sh \
    --fixture p2-bug \
    --duration 240 \
    --cadence 4m \
    --cache-ttl 5m \
    --inject-at 1800 --inject-fixture p1-injection \
    --output-dir ~/.local/state/autocoder/phase0/4m-5m \
    --execute

# B) Probe alternative: 55-min cadence, 1-h TTL
plugins/autocoder/scripts/run-phase-experiment.sh \
    --fixture p2-bug \
    --duration 240 \
    --cadence 55m \
    --cache-ttl 1h \
    --inject-at 1800 --inject-fixture p1-injection \
    --output-dir ~/.local/state/autocoder/phase0/55m-1h \
    --execute
```

## Comparison

Open both `report.md` files. Compare:

| Metric                                | A (4m/5m)  | B (55m/1h) |
|---------------------------------------|-----------|-----------|
| Per-tick input cost (cache-warm)      |           |           |
| Per-active-tick cost on P2 fixture    |           |           |
| Median time-to-claim (P1 injection)   |           |           |
| Total cost over the run window        |           |           |
| % cache-warm ticks                    |           |           |

## Decision rule (§13.4 Phase 0 acceptance)

Default = whichever configuration has lower **total cost over the run
window** *and* meets all of:

- ≥80% cache-warm ticks
- per-active-tick cost on the P2 fixture no worse than the 15-min
  baseline captured in any prior measurement
- median time-to-claim on the P1 injection ≥3× faster than 15-min
  baseline

If A wins → no further code change (default is already 4m).
If B wins → update `IDLE_SLEEP_MINUTES="4"` in both
`plugins/autocoder/commands/fix-loop.md` and
`.agent/workflows/fix-loop.md` to `"55"`, plus wire the `ttl: "1h"`
cache_control flag through wherever Phase 2 gate prompts are sent.

Commit the chosen result alongside the two `report.md` files under
`docs/reports/`.
