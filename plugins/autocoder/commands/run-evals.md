# Run Evals

Run the evaluation cases that `/author-evals` wrote against a worker, and report how many pass
(#395). Each run gets a fresh sandbox repository with the case's seed and its issue in a file
backend. The worker works the issue there, and the trace of that attempt is graded against the
case's verifier. Pass rates are recorded per harness commit, so a harness change can be compared
with the commit before it.

## Usage

```bash
/run-evals              # the dev cases
/run-evals heldout      # the held-out cases
/run-evals all          # both
```

## Instructions

### 1. Resolve the scripts

```bash
# Resolve SCRIPT_DIR — see scripts/README.md#script-dir
SCRIPT_DIR=$(
  for d in "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; exit 0; fi
  done
  # Fallback: the installed plugin. Only <ver>/scripts is a complete tree;
  # <ver>/skills/autocoder/scripts is a subset that sorts after it (#142).
  # Rank by the <ver> directory alone, not the whole path: with two marketplaces
  # in the cache, a whole-path sort lets the marketplace name decide (#201).
  find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
)
if [ ! -f "${SCRIPT_DIR}/issue-fns.sh" ]; then
  echo "autocoder: cannot locate issue-fns.sh (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi
SPEC="$SCRIPT_DIR/../BEHAVIOR.md"
if [ ! -f "$SPEC" ]; then
  echo "autocoder: BEHAVIOR.md is not beside the scripts; set SPEC to its path" >&2
  exit 1
fi
SPLIT="dev"   # the first argument: dev, heldout or all
```

### 2. Run the cases

```bash
python3 "$SCRIPT_DIR/eval-run.py" --split "$SPLIT" --spec "$SPEC"
```

The default worker is the worker loop's own line, `claude -p --output-format stream-json
--verbose "/autocoder:fix {issue}"`. That is one headless fix session per case and repeat, and
each one costs what a fix session costs. `--repeat N` runs each case N times, `--timeout S`
(default 3600) bounds one session, and `--worker CMD` replaces the worker (`{issue}`, `{repo}`
and `{root}` are substituted). A malformed case stops the run with exit 2 before any worker
starts: run `eval-author.py check` and fix what it names.

A case with `"backend": "fake-github"` (a claim-protocol or review-record finding) runs on a
fake `gh` that keeps the sandbox issue, its labels and its comments. It never reaches a real
tracker, and it needs no `gh` login.

### 3. Report

Print the summary the runner wrote: one line per case with its passes out of its repeats and the
checks that failed, then one line per split. A failed check is `outcome`, `max_gates`,
`max_tool_calls`, `timeout`, `setup`, `trace` (no attempt was recorded), or
`classifiers_silent:<id>`, `steps_present:<kind>` or `steps_absent:<kind>`.

The runner keeps the sandbox of each failing run and prints `kept for <case>: <root>`. Point the
operator at it: `<root>/traces.jsonl` is the graded trace, `<root>/logs/` holds the worker's
transcript, `<root>/worker.stderr` its errors, and `<root>/repo` is the sandbox repository as the
worker left it. A fake-github case also keeps `<root>/gh-store/` (the issue as `gh issue view`
prints it) and `<root>/gh.log` (every `gh` call, with its exit code). A call with exit 1 and a
`fake gh: unsupported form` line in `worker.stderr` means the fake lacks a form the worker used.
Report that as a gap in `fake-gh.py`, not as a failure of the harness. For a held-out run, report the counts and the kept roots only. Do not open the
case files under `.autocoder/evals/heldout/`.

## Settings

| Setting | Default |
|---|---|
| Cases | `--cases DIR`, else `AUTOCODER_EVAL_CASES`, else `.autocoder/evals` under the repository root |
| Results ledger | `--results PATH`, else `${AUTOCODER_EVAL_RESULTS:-$XDG_STATE_HOME/autocoder/eval-results.jsonl}` |
| Harness commit | `AUTOCODER_HARNESS_SHA`, else the scripts' checkout HEAD |
| Keep every sandbox | `--keep` (failing ones are always kept) |
