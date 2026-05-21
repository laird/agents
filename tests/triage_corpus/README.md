# Triage corpus — Phase 3 acceptance fixture

Used by spec
[`docs/specs/2026-05-21-fix-loop-token-efficiency-design.md`](../../docs/specs/2026-05-21-fix-loop-token-efficiency-design.md)
§10 Phase 3 and §13.4 Phase 3 acceptance:

> triaging 10 unprioritized issues on Haiku produces the same priority labels
> as a Sonnet baseline ≥80% of the time (measured on a fixed test corpus
> committed to `tests/triage_corpus/`).

## Layout

```
tests/triage_corpus/
├── README.md              # this file
├── expected.csv           # issue_file,expected_priority
└── issues/
    ├── 001-<slug>.md      # one issue body per file
    ├── 002-<slug>.md
    └── ...                # 10–20 issues total, mix of P0/P1/P2/P3
```

Each issue file is a plain markdown issue body (title on the first H1 line,
body below). No frontmatter; no labels in-file — the expected label lives in
`expected.csv` so the corpus mirrors what the gate sees on a fresh untriaged
issue.

`expected.csv` columns:

```
issue_file,expected_priority,rationale
issues/001-prod-down.md,P0,"production outage, no workaround"
issues/002-payment-loss.md,P0,"data-loss risk, all users affected"
issues/003-checkout-broken.md,P1,"major flow broken, slow workaround"
...
```

## Authoring guidance

- Aim for 10–20 issues with roughly even distribution across P0–P3.
- Mix real-looking bug reports, feature requests, and ambiguous cases —
  the acceptance bar is correctness on a *fixed* corpus, so cherry-picking
  easy cases will not surface real Haiku weaknesses.
- Each issue should be answerable from the body alone (no implied repo
  context the gate can't see).
- Source candidate issues from real autocoder backlog where possible;
  redact any PII/secrets first.
- Document each priority decision in the `rationale` column so reviewers
  can challenge the "ground truth" label, not just the Haiku output.

## Running the experiment

The runner script is **not yet built** (out of scope for the Phase 3
plumbing PR). When it lands it should:

1. Read each `issues/*.md` body.
2. Send it through both models with the gate's triage prompt (see
   `plugins/autocoder/commands/dispatch.md` for the matrix).
3. Compare the label each model picks against `expected.csv`.
4. Emit per-model accuracy plus the Haiku-vs-Sonnet agreement rate.

Acceptance bar: **Haiku ≥ 0.80 × Sonnet** on the corpus.

## Scope note

This directory + README is the **structural placeholder** mandated by the
Phase 3 plan. Populating `issues/` and `expected.csv` is a runtime-experiment
task, deferred until the model-split loop has been running long enough on a
real backlog to source realistic issues.
