# Analyze Traces

Name the agent failures that repeat (#395). This builds one trace per issue attempt from the
ledgers the fix loop already writes, runs the trace analyst against the behaviour spec
(`BEHAVIOR.md` in the plugin root), and writes the findings to
`docs/reports/traces/<date>-findings.md`. It does not file issues; turning findings into
evaluations is a later step.

## Usage

```bash
/analyze-traces                          # every attempt on record for this repository
/analyze-traces 2026-11-01               # attempts started on or after a date
/analyze-traces 2026-11-01 2026-11-15    # attempts started in [since, until)
```

## Instructions

### 1. Resolve the scripts and this repository's id

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
source "$SCRIPT_DIR/repo-id-fns.sh"
REPO_ID=$(autocoder_repo_id .)

SINCE=""   # the first argument (YYYY-MM-DD or ISO-8601), or empty
UNTIL=""   # the second argument, or empty
WINDOW=()
[ -n "$SINCE" ] && WINDOW+=(--since "$SINCE")
[ -n "$UNTIL" ] && WINDOW+=(--until "$UNTIL")
```

### 2. Build the traces

```bash
python3 "$SCRIPT_DIR/trace-build.py" --repo-id "$REPO_ID" "${WINDOW[@]}"
```

Run it from this repository: the train's gate issue (`train.gateIssue` in the main worktree's
`.autocoder.json`) carries claims and no work, so the builder drops its traces and says how many
on stderr. Pass `--train-gate-issue N` to name a different issue, or `0` to keep it.

Each trace's steps include the landing-timings rows: `ready` (the worker's hand-off),
`launched`, `batched`, `returned` and `landed`. A train landing appears only there, and it counts
as the attempt's landing.

Each line of the loop-ticks ledger is a trace of its own, `kind: "tick"`: one run of an
operational loop that recorded itself with `tick-fns.sh` or `tick-log.py`. The four `tick-*`
classifiers read them a loop at a time (an error streak, a slow run, a day of noops, a lapsed
cadence) and key their findings by loop id. No ledger means no tick traces and no tick findings.

The traces go to the default path beside the ledgers,
`${AUTOCODER_TRACES:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/traces.jsonl}`, never into
the working tree. A rerun rewrites the whole file. A line on stderr counts any malformed ledger
lines that were skipped.

**Review records (only if the operator asks for them).** Without `--comments-dir` every trace's
review is null, so the `landed-unreviewed` and `review-left-important` classifiers stay silent.
Say so in your summary. If the operator wants them, fetch the landed issues' documents and
rebuild:

```bash
source "$SCRIPT_DIR/issue-fns.sh"
TRACES="${AUTOCODER_TRACES:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/traces.jsonl}"
COMMENTS_DIR=$(mktemp -d)
for n in $(jq -r 'select(.outcome == "landed") | .issue' "$TRACES" | sort -un); do
  issue_get "$n" > "$COMMENTS_DIR/$n.json"
done
python3 "$SCRIPT_DIR/trace-build.py" --repo-id "$REPO_ID" "${WINDOW[@]}" --comments-dir "$COMMENTS_DIR"
```

Leave a failed fetch's file in place: an unreadable document is reported as `unavailable`,
never as `no record`, so a network error never reads as an unreviewed landing.

### 3. Run the analyst and write the findings

```bash
mkdir -p docs/reports/traces
OUT="docs/reports/traces/$(date +%Y-%m-%d)-findings.md"
python3 "$SCRIPT_DIR/analyze-traces.py" "${WINDOW[@]}" > "$OUT"
```

Each finding names a classifier and its key, the `BEHAVIOR.md` rules it breaks, the harness
surface it points at, its count and share of the corpus, and three example traces with their
evidence. The report ends with the corpus size, the window and the traces no classifier matched.

**The judge is off by default.** Some rules (signal `judge` in `BEHAVIOR.md`, such as B12) need a
reader of the trace. To turn the judge on, add `--judge CMD` to the analyst: `CMD` gets the
prompt (`prompts/trace-judge.v1.md`), the spec and one trace on stdin and must print a JSON
array, for example `--judge "claude -p --output-format text"`. It runs once per trace no
classifier matched, or once per trace with `--judge-all`, so it costs one model call per trace.
When the analyst cannot find the prompt and spec beside its scripts, pass `--judge-prompt PATH`
and `--spec PATH`.

### 4. Report

Print the findings file's path and the top three findings, then stop:

```bash
echo "Findings: $OUT"
python3 "$SCRIPT_DIR/analyze-traces.py" "${WINDOW[@]}" --json \
  | jq -r '.findings[:3][] | "\(.id)\(if .key then ": " + .key else "" end): \(.count) trace(s), rules \(.rules | join(", ")), surface \(.surface)"'
```

## Settings

The builder reads the ledgers at the paths their writers use; each has a flag to override it:

| Ledger | Default | Flag |
|---|---|---|
| Issue lifecycle | `${AUTOCODER_ISSUE_EVENTS:-$XDG_STATE_HOME/autocoder/issue-events.jsonl}` | `--issue-events` |
| Merge attempts | `${AUTOCODER_MERGE_EVENTS:-$XDG_STATE_HOME/autocoder/merge-events.jsonl}` | `--merge-events` |
| Landing timings | `${AUTOCODER_LANDING_TIMINGS:-$XDG_STATE_HOME/autocoder/landing-timings.jsonl}` | `--landing-timings` |
| Gate ticks | `$XDG_STATE_HOME/autocoder/gate.jsonl` | `--gate-log` |
| Loop ticks | `${AUTOCODER_TICKS:-$XDG_STATE_HOME/autocoder/ticks.jsonl}` | `--ticks` |
| Worker transcripts | `${AUTOCODER_LOG_DIR:-/tmp/autocoder-logs}` | `--log-dir` |

`$XDG_STATE_HOME` defaults to `~/.local/state`. Schema, joins and outcome rules:
`docs/specs/2026-11-25-failure-traces-design.md` and `scripts/README-measurement-tooling.md`.
