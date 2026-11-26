# Propose Fix

Propose ONE harness change for one finding, and keep it only when the evaluations it was
written against and the held-out ones both improve (#395). The finding comes from
`/analyze-traces`, the cases from `/author-evals`, and the verdict from `eval-decide.py`; this
command is the agent's part in between. One change at a time, so the evaluation attributes the
effect to it.

Run this in the project repository that holds the cases (`.autocoder/evals/`). The harness is
the plugin: a git checkout of the plugin repository, named by the second argument or
`AUTOCODER_HARNESS_REPO`. The worker under test loads the plugin from the proposal worktree with
`claude --plugin-dir`, so the installed plugin is never changed by a proposal.

## Usage

```bash
/propose-fix conflict-escalated-early                 # finding id; harness from AUTOCODER_HARNESS_REPO
/propose-fix gate-red-suite:tests/test_x.sh ~/src/plugin-checkout
/propose-fix reclaimed ~/src/plugin-checkout 3        # three repeats per case (default 2)
```

## Instructions

### 1. Resolve the scripts, the finding, the cases and the harness

```bash
# Resolve SCRIPT_DIR — see scripts/README.md#script-dir
SCRIPT_DIR=$(
  for d in "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/issue-fns.sh" ]; then echo "$d"; exit 0; fi
  done
  # Fallback: the installed plugin. Only <ver>/scripts is a complete tree;
  # <ver>/skills/autocoder/scripts is a subset that sorts after it (#142).
  # Rank by the <ver> directory alone, not the whole path: with two marketplaces
  # in the cache, a whole-path sort lets the marketplace name decide (#201).
  found=$(
  find "$HOME/.agent/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
  )
  if [ -n "$found" ]; then echo "$found"; exit 0; fi
  # Grok installs to ~/.grok/installed-plugins/<name>-<hash>/. The hash is in
  # the directory name, so the Claude cache glob */autocoder/* does not match.
  find "$HOME/.grok/installed-plugins" -type d -name "scripts" -path "*/autocoder-*/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
)
if [ ! -f "${SCRIPT_DIR}/issue-fns.sh" ]; then
  echo "autocoder: cannot locate issue-fns.sh (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi
FINDING=""                                   # the first argument: <classifier-id>[:<key>]
HARNESS="${2:-${AUTOCODER_HARNESS_REPO:-}}"  # a git checkout of the plugin repository
REPEAT="${3:-2}"
CASES="${AUTOCODER_EVAL_CASES:-$(pwd)/.autocoder/evals}"

[ -d "$HARNESS/plugins/autocoder" ] || { echo "propose-fix: $HARNESS is not a checkout of the plugin repository (set AUTOCODER_HARNESS_REPO)" >&2; exit 1; }
SPEC="$HARNESS/plugins/autocoder/BEHAVIOR.md"
DEV_CASES=$(python3 "$SCRIPT_DIR/eval-author.py" list --cases "$CASES" --split dev | grep -F "$FINDING" || true)
[ -n "$DEV_CASES" ] || { echo "propose-fix: no dev case for finding '$FINDING'; run /author-evals first" >&2; exit 1; }
echo "$DEV_CASES"
```

Then read, in this order, and nothing else: the finding's entry in the latest analyst report
(`analyze-traces.py --json`, or re-run it), the rules it cites in `$SPEC`, the dev cases listed
above (their `task.md`, `seed/` and `case.json`), and the harness surface the finding names (a
command file section, a script, a prompt) in `$HARNESS`.

### 2. Make the proposal worktree, without the held-out cases

```bash
STAMP=$(date +%Y%m%d-%H%M%S)
CMP=$(python3 -c 'import uuid; print(uuid.uuid4())')
WT="${TMPDIR:-/tmp}/propose-${STAMP}"
git -C "$HARNESS" worktree add -q "$WT" -b "fix/${FINDING%%:*}-${STAMP}" HEAD
BEFORE=$(git -C "$WT" rev-parse HEAD)
WORKER="claude -p --plugin-dir $WT/plugins/autocoder --output-format stream-json --verbose \"/autocoder:fix {issue}\""
```

The held-out cases live in this project's `.autocoder/evals/heldout/`. Do not open, list or
read anything under it, in this session or a later one. The runner reads it in step 5 and
reports counts only.

### 3. Baseline: the dev cases on the harness as it is

```bash
AUTOCODER_HARNESS_SHA="$BEFORE" python3 "$SCRIPT_DIR/eval-run.py" \
  --cases "$CASES" --split dev --case $(echo "$DEV_CASES" | awk '{print $1}') \
  --repeat "$REPEAT" --worker "$WORKER" --spec "$SPEC" --comparison "$CMP"
```

Each run is one headless fix session and costs what one costs. Record the summary line. If
every dev case already passes every repeat, stop: there is nothing for a change to improve, and
the finding needs a sharper case (`/author-evals`), not a harness change.

### 4. Propose ONE change

In `$WT`, change one thing at the surface the finding names: a protocol step's wording or order,
a script's behaviour, a prompt. Keep the plugin's rules: edit a command under
`plugins/autocoder/commands/` and its `.agent/workflows/` copy together; edit scripts under
`plugins/autocoder/scripts/` then run the repository's script packager (CLAUDE.md names it); add or adjust
the unit test that pins the new behaviour; never bump a version. Run the plugin's own suite for
what you touched. Then commit, staging only the files you changed:

```bash
git -C "$WT" add <the files you changed>
git -C "$WT" commit -m "<what changed and why, naming the finding and the rules>"
AFTER=$(git -C "$WT" rev-parse HEAD)
```

Do not make a second change before the first is judged. If you believe two changes are needed,
make the one the evidence supports most and let the verdict decide.

### 5. Measure: dev again, then the held-out cases, both shas

```bash
AUTOCODER_HARNESS_SHA="$AFTER" python3 "$SCRIPT_DIR/eval-run.py" \
  --cases "$CASES" --split dev --case $(echo "$DEV_CASES" | awk '{print $1}') \
  --repeat "$REPEAT" --worker "$WORKER" --spec "$SPEC" --comparison "$CMP"

# The held-out cases: the runner reads them, you read the counts.
for SHA in "$BEFORE" "$AFTER"; do
  git -C "$WT" checkout -q "$SHA"
  AUTOCODER_HARNESS_SHA="$SHA" python3 "$SCRIPT_DIR/eval-run.py" \
    --cases "$CASES" --split heldout --repeat "$REPEAT" --worker "$WORKER" --spec "$SPEC" --comparison "$CMP" --json \
    | jq -c 'del(.rows) + {sha: "'"$SHA"'"}'
done
git -C "$WT" checkout -q "fix/${FINDING%%:*}-${STAMP}"
```

The first pass runs held-out on both shas. A later pass must not run `$BEFORE` again: those rows
stay in the comparison, and a second run makes the held-out counts `2*REPEAT` against the
candidate's `REPEAT`, which is inconclusive. On a refine, run only the `$AFTER` commands above
(dev, then held-out).

A held-out run's kept roots hold the failing traces; do not open them. If a dev case's kept root
is needed to understand a failure, that one is yours to read.

### 6. The verdict

```bash
python3 "$SCRIPT_DIR/eval-decide.py" --finding "$FINDING" --before "$BEFORE" --after "$AFTER" --min-runs "$REPEAT" --comparison "$CMP"
VERDICT=$?
```

- **accept (exit 0):** push the branch and open the plugin's pull request. The body carries the
  finding, the rules, the one change, and the decision row `eval-decide.py --json` printed, with
  the dev and held-out pass counts before and after. Generic words only: no project, client or
  person names, since the plugin ships to every repository.
- **reject (exit 1):** run the analyst on the dev runs' traces (`analyze-traces.py --traces
  <kept root>/traces.jsonl` for each kept dev root) and read what the fixed harness did instead.
  You may refine the change ONCE: amend in `$WT`, take the new sha as `AFTER`, keep the same
  `CMP`, and repeat only the `$AFTER` measurements in step 5 (dev, then held-out) and this step.
  Do not run held-out on `$BEFORE` again, and do not return to step 4. A second reject ends the
  proposal: leave the branch unpushed, and record the decision rows (both are in
  `eval-decisions.jsonl`) in your summary so the next attempt starts from them.
- **inconclusive (exit 3):** say the reason, and do not treat it as a pass.
  - `no <split> case was run`: that split has no rows. Author a case if none exists, then run
    that split on both shas with the same `CMP`. Do not re-run the split that already matched.
  - `fewer than N runs`: one side did not run a case the other side ran. A count of 0 is this
    reason. Re-run that side with the same cases and the same `CMP`. Do not add or drop a case.
  - The case set, grader, worker, timeout, or `REPEAT` must change: mint a new `CMP`. Check out
    `$BEFORE` in `$WT`, run step 3, check out the feature branch, then run step 5 and step 6.
    Do not return to step 4. Step 3 labels rows with `$BEFORE` but runs whatever `$WT` has
    checked out, so a baseline measured on the candidate tree is not a baseline. The old rows
    share the harness sha, so the same `CMP` would pool them and the settings would disagree.
  - A refine after an amend, same `REPEAT` and same cases: keep the same `CMP` and re-run only
    the `$AFTER` rows. The new after sha drops the replaced candidate rows. The baseline rows
    stay; do not append them again.

### 7. Report and clean up

Print: the finding, the change in one sentence with the files, the baseline and after summaries
for dev, the held-out counts for both shas, the verdict with its reason, and the pull request
URL when accepted. Then remove the worktree unless the proposal was accepted and its branch is
still needed:

```bash
git -C "$HARNESS" worktree remove --force "$WT"
```

## Settings

| Setting | Default |
|---|---|
| Harness checkout | second argument, else `AUTOCODER_HARNESS_REPO` |
| Cases | `AUTOCODER_EVAL_CASES`, else `.autocoder/evals` under this repository |
| Repeats per case | third argument, else 2 (also `eval-decide.py --min-runs`) |
| Results and decisions | `${AUTOCODER_EVAL_RESULTS:-$XDG_STATE_HOME/autocoder/eval-results.jsonl}`, `${AUTOCODER_EVAL_DECISIONS:-$XDG_STATE_HOME/autocoder/eval-decisions.jsonl}` |

The accept rule and the week page that counts these decisions: `scripts/README-measurement-tooling.md`
and `docs/specs/2026-11-25-failure-traces-design.md`.
