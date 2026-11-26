# Author Evals

Turn the failures that repeat into evaluation cases a machine can run and grade (#395). This
runs the trace analyst, scaffolds a dev case and a held-out case for each of the top findings,
and you write each case's task and sandbox project so that a worker given the task in that
project is likely to hit the same failure class. The cases are committed under
`.autocoder/evals/` and run by `/run-evals`.

## Usage

```bash
/author-evals                    # analyse every attempt on record, top 3 findings
/author-evals findings.json      # use an analyze-traces.py --json report you already have
/author-evals findings.json 5    # the top 5 findings
```

## Instructions

### 1. Resolve the scripts, the spec and the findings

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
  found=$(
  find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
  )
  if [ -n "$found" ]; then echo "$found"; exit 0; fi
  # Grok installs to ~/.grok/installed-plugins/<name>-<hash>/. The hash is in
  # the directory name, so the Claude cache glob */autocoder/* does not match.
  find "$HOME/.grok/installed-plugins" -type d -name "scripts" -path "*/autocoder-*/*" -not -path "*/skills/*" 2>/dev/null \
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
FINDINGS=""   # the first argument, or empty
TOP=3         # the second argument, or 3

if [ -z "$FINDINGS" ]; then
  source "$SCRIPT_DIR/repo-id-fns.sh"
  FINDINGS=$(mktemp)
  python3 "$SCRIPT_DIR/trace-build.py" --repo-id "$(autocoder_repo_id .)"
  python3 "$SCRIPT_DIR/analyze-traces.py" --spec "$SPEC" --json > "$FINDINGS"
fi
jq -r --argjson top "$TOP" '.findings[:$top] | to_entries[]
  | "\(.key): \(.value.id)\(if .value.key then ": " + .value.key else "" end), \(.value.count) trace(s), rules \(.value.rules | join(", "))"' "$FINDINGS"
```

If the report has no findings, say so and stop: there is nothing to write a case for.

### 2. Scaffold a dev and a held-out case per finding

```bash
N=$(jq --argjson top "$TOP" '[(.findings | length), $top] | min' "$FINDINGS")
for i in $(seq 0 $((N - 1))); do
  python3 "$SCRIPT_DIR/eval-author.py" new --findings-file "$FINDINGS" --index "$i" --split dev --spec "$SPEC"
  python3 "$SCRIPT_DIR/eval-author.py" new --findings-file "$FINDINGS" --index "$i" --split heldout --spec "$SPEC"
done
```

Each `new` prints the case directory it made. A case is:

| File | What you do with it |
|---|---|
| `case.json` | Write `issue.title`. The verifier (`verify`) comes from the finding's classifier; tighten it when the failure needs it (a `max_gates`, a `steps_absent`), never loosen it. |
| `task.md` | Replace it with the issue body the worker gets. Its author notes show the rules the failure breaks and the evidence from the traces. |
| `seed/` | The sandbox project: the files committed to the sandbox repository before the worker starts. Include a `CLAUDE.md` with the test command when the task needs one; the runner adds `.autocoder.json` and the merge settings when the seed has none. |
| `setup.sh` | Only when the failure needs a second actor. It runs in the sandbox clone after the seed commit, with `ORIGIN` naming the bare remote: for example, it commits a conflicting change and pushes it to `$ORIGIN master`. |

The sandbox issue lives in the file backend unless `case.json` says `"backend": "fake-github"`.
Set that for a failure in the claim protocol (the `working` label, claim markers, start and
release comments) or in the review record (B05, B06). The file backend never runs either of
those: its claim is an atomic rename, and it folds comments into the issue body. Under
fake-github, `issue.comments` stages the comments the issue already has, each
`{"body": "...", "age_s": N}`, posted `age_s` seconds before the worker starts. For example, a
stale start comment is `{"body": "🤖 **Automated Fix Started** ...", "age_s": 600}`.
`issue.state` (`open` or `closed`) is the third option.

### 3. Write each case

For every case directory printed in step 2:

1. Read the author notes in `task.md`. Then write a small, real task in a small project whose
   natural path runs into the failure class. A conflict class needs a second actor in
   `setup.sh`. A red-suite class needs a test that the obvious change breaks.
2. Describe the work, not the failure. Never name the rule, the classifier or the evaluation in
   the title, the task or the seed.
3. Make the dev case and the held-out case of one finding different scenarios (another project
   or another task), so the held-out case measures the class and not a copy of the dev case.
4. Delete every `TODO` and the author notes.

### 4. Check, then commit

```bash
python3 "$SCRIPT_DIR/eval-author.py" check --spec "$SPEC"
```

Fix every line it prints and run it again until it reports every case ok. Then commit the cases:

```bash
git add .autocoder/evals
git commit -m "Add evaluation cases for the top trace findings"
```

### 5. Never open heldout/ again

The held-out cases measure whether a harness change generalises. Once they are committed, do not
read, list or edit anything under `.autocoder/evals/heldout/`, in this session or a later one.
Only `/run-evals heldout` reads them, and its summary reports pass counts, not the cases.

## Settings

`--cases DIR` (or `AUTOCODER_EVAL_CASES`) moves the cases from `.autocoder/evals` under the
repository root. Case format and verifier: `scripts/README-measurement-tooling.md` ("Evaluation
cases") and `docs/specs/2026-11-25-failure-traces-design.md`.
