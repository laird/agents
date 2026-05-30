# Fix-Loop Token-Efficiency — Cumulative Report (TEMPLATE)

> Per spec `docs/specs/2026-05-21-fix-loop-token-efficiency-design.md` §13.5.
> Fill this in after Phase 4 ships, or after the project pauses /
> gets shelved. One report per project lifecycle, not per phase.

- **Filled in at:** `<YYYY-MM-DD>`
- **Author:** `<name / handle>`
- **Project status at fill-in:** `<shipped Phase 4 | paused after Phase N | abandoned>`
- **Spec revision referenced:** `<commit-sha-of-spec-at-fill-in>`

---

## 1. Total Measured Savings vs Baseline

Predicted (from spec §6) vs actual (from joined.csv across all phases).

| Metric                         | Predicted (§6)         | Actual measured          | Delta (% of predicted) |
|--------------------------------|------------------------|--------------------------|------------------------|
| Per-tick prefill tokens        | `<N>` tokens           | `<N>` tokens             | `<+/-N%>`              |
| Per-tick cost (Sonnet)         | `$<N>`                 | `$<N>`                   | `<+/-N%>`              |
| Per-day idle cost (Sonnet)     | `$<N>`/day             | `$<N>`/day               | `<+/-N%>`              |
| Per-day idle cost (Opus)       | `$<N>`/day             | `$<N>`/day               | `<+/-N%>`              |
| Cache-hit rate at 4m cadence   | `<N>%`                 | `<N>%`                   | `<+/-N pp>`            |
| Cache-hit rate at 55m cadence  | `<N>%`                 | `<N>%`                   | `<+/-N pp>`            |

Notes: `<which numbers were validated under load vs synthetic fixtures only>`

---

## 2. Build-Cost Actuals

| Engineer | Hours | Rate ($/hr) | Subtotal |
|----------|-------|-------------|----------|
| `<name>` | `<N>` | `<N>`       | `$<N>`   |
| `<name>` | `<N>` | `<N>`       | `$<N>`   |
| **Total**|       |             | **`$<N>`** |

Compare to spec §6 build-cost estimate: `<predicted $N>` → delta `<+/-N%>`.

---

## 3. Payback Period at Observed Traffic

- Observed daily active sessions running fix-loop: `<N>`
- Observed daily ticks/session (averaged over `<N>` days): `<N>`
- Per-tick savings (actual, from §1): `$<N>`
- Daily savings at observed traffic: `$<N>`/day
- Payback period: `<build cost> / <daily savings>` = `<N> days`

Spec §6 predicted payback: `<N> days`. Delta: `<+/-N%>`.

---

## 4. Lessons Learned

Per §13.5: enumerate which §6 line items were wrong and by how much.
Be specific — "the prefill-shrinkage estimate was X% high" is more useful
than "estimates were off."

- §6.`<line>` `<short description>`: predicted `<X>`, actual `<Y>`, delta `<+/-N%>`.
  Root cause: `<why we got it wrong>`.
- §6.`<line>` `<short description>`: predicted `<X>`, actual `<Y>`, delta `<+/-N%>`.
  Root cause: `<why we got it wrong>`.
- `<...add as many as apply...>`

What we'd do differently next time: `<2-4 bullets>`.

---

## 5. Recommendation on v3

Apply the §11 / §13.5 trigger rule:

- Idle cost on Sonnet (actual, §1): `$<N>`/day — threshold `>$0.20/day`: `<met | not met>`
- Idle cost on Opus (actual, §1): `$<N>`/day — threshold `>$0.50/day`: `<met | not met>`
- Unavoidable per-tick LLM prefill (actual, % of tokens that cannot be
  eliminated by caching/dedup): `<N>%` — threshold `>50%`: `<met | not met>`

**Recommendation:** `<proceed with v3 | do not proceed | revisit in N months when traffic reaches M sessions/day>`

Justification: `<1-2 sentences tying the three numbers above to the trigger rule>`.

---

## 6. Test Environment Disclosure (Reproducibility — §13.3)

For anyone replicating these numbers:

- Model + version: `<e.g. claude-sonnet-4-6@2026-05-01>`
- Region: `<e.g. us-east5>`
- Caching tier in effect: `<5m | 1h | both>`
- Fixture set used: `<commit-sha of tests/fixtures/>`
- Runner: `plugins/autocoder/scripts/run-phase-experiment.sh` at sha `<sha>`
- Analyzer: `plugins/autocoder/scripts/analyze-gate-log.py` at sha `<sha>`
- Hardware / network notes: `<anything non-default that might affect timings>`
- Raw artifacts (gate.jsonl, session.jsonl, joined.csv): `<path or archive URL>`

---

*End of template. See spec §13.5 for the canonical section list.*
