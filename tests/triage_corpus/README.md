# Triage corpus — Phase 3 acceptance fixture

Fixed test corpus used by the
[fix-loop token-efficiency design](../../docs/specs/2026-05-21-fix-loop-token-efficiency-design.md)
§13.4 Phase 3 acceptance gate:

> Triage-correctness on Haiku ≥ 80% of Sonnet baseline, measured on
> a fixed test corpus committed to `tests/triage_corpus/`.

The corpus exercises the triage decision matrix in
[`plugins/autocoder/commands/fix.md`](../../plugins/autocoder/commands/fix.md)
(§ "Triage Decision Matrix"). It is used to validate that swapping
Sonnet → Haiku for the triage hop does not regress label quality below
the 80% bar.

## Layout

```
tests/triage_corpus/
├── README.md          # this file
├── expected.csv       # ground-truth labels + rationales
└── issues/
    ├── 01.md          # one issue body per file (title + body, no frontmatter)
    ├── 02.md
    └── ... 10.md
```

Each issue file is a plain-markdown GitHub-style issue body: the first
line is an H1 title, the rest is the body. No YAML frontmatter, no
labels in-file — the expected priority lives in `expected.csv` so the
benchmark sees the same untriaged input the gate sees on a real issue.

`expected.csv` columns:

| Column              | Meaning                                               |
|---------------------|-------------------------------------------------------|
| `issue_file`        | Path relative to this directory, e.g. `issues/01.md`. |
| `expected_priority` | One of `P0`, `P1`, `P2`, `P3`.                        |
| `rationale`         | One sentence citing which row of the fix.md matrix produced the label. Cases marked "ambiguous" flag where the label is defensible but reasonable graders could disagree. |

## Corpus shape

10 issues, distributed to exercise the full matrix and to deliberately
include borderline cases:

| Priority | Count | Files          |
|----------|-------|----------------|
| P0       | 2     | 01, 02         |
| P1       | 3     | 03, 04, 05     |
| P2       | 3     | 06, 07, 08     |
| P3       | 2     | 09, 10         |

Two cases are flagged ambiguous in `expected.csv` and exist to surface
real Haiku/Sonnet disagreement points:

- **05** — P0/P1 boundary (SSO down for the majority but not all users).
- **07** — P2/P3 boundary (intermittent "feels slow", no repro, multiple
  reporters but nobody blocked).

A model that disagrees on these is not necessarily wrong — but
systematic disagreement on the unambiguous cases (01, 02, 09, 10) is a
red flag.

## Running the benchmark

The runner is **not** included in this directory (out of scope for the
corpus-authoring task; it's a future runtime experiment). When written,
it should follow this shape:

```python
# Pseudocode — runner not yet built
import csv, pathlib

corpus = pathlib.Path("tests/triage_corpus")
expected = {row["issue_file"]: row["expected_priority"]
            for row in csv.DictReader((corpus / "expected.csv").open())}

results = {"haiku": [], "sonnet": []}
for issue_path, gold in expected.items():
    body = (corpus / issue_path).read_text()
    for model in ("haiku", "sonnet"):
        pred = classify_with_triage_prompt(model, body)  # uses fix.md matrix
        results[model].append((issue_path, gold, pred, pred == gold))

haiku_acc  = sum(r[3] for r in results["haiku"])  / len(results["haiku"])
sonnet_acc = sum(r[3] for r in results["sonnet"]) / len(results["sonnet"])

# §13.4 acceptance:
assert haiku_acc >= 0.80 * sonnet_acc, f"Haiku regression: {haiku_acc:.2f} < 0.80 * {sonnet_acc:.2f}"
```

Use the exact triage prompt from `plugins/autocoder/commands/fix.md`
§ "Triage Instructions" — do not invent a new prompt or the benchmark
will measure something other than what the gate runs in production.

## Acceptance threshold

Per §13.4 Phase 3:

- **Pass:** `haiku_accuracy ≥ 0.80 × sonnet_accuracy` on this corpus.
- **Fail:** any lower → roll triage back to Sonnet (or revisit the
  Haiku prompt) before promoting the model-split change.

The threshold is *relative* to Sonnet, not absolute, because the
corpus includes deliberately ambiguous cases where even Sonnet may
miss the "ground truth" label.

## Extending the corpus

To add an issue:

1. Create `issues/NN.md` (next sequential number) with a realistic
   title + body. No frontmatter.
2. Append a row to `expected.csv`:
   `issues/NN.md,P{0|1|2|3},"<rationale citing fix.md matrix row>"`.
3. If the case is borderline, say so explicitly in the rationale
   (e.g. `"ambiguous — could be P1/P2 because ..."`). This protects
   the gate from being graded down on judgment calls.
4. Keep the distribution roughly balanced across P0–P3; the benchmark
   is a worse signal if it's dominated by one bucket.
5. Don't paste real CVEs, real customer issues, or real PII. Synthetic
   but realistic phrasing only.

Re-run the benchmark after extending — the 80% bar applies to the
whole corpus, not just the additions.
