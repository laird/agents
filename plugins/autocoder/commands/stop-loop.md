# Stop Fix Loop

Stops the infinite `/fix-loop` and `/monitor-loop`. On Claude Code that removes the stop-hook state file. On Grok it also deletes the `scheduler_create` jobs those commands recorded.

## Usage

```bash
/stop-loop
```

## Instructions

```bash
LOOP_STATE_FILE=".claude/fix-loop.local.md"
GROK_LOOPS=".grok/autocoder-loops.json"
STOPPED=0

if [[ -f "$LOOP_STATE_FILE" ]]; then
  # Extract current iteration for status message
  ITERATION=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$LOOP_STATE_FILE" | grep '^iteration:' | sed 's/iteration: *//')

  rm "$LOOP_STATE_FILE"
  echo "🛑 Fix loop stopped (stop-hook state removed)"
  echo "   Completed iterations: ${ITERATION:-0}"
  STOPPED=1
fi

if [[ -f "$GROK_LOOPS" ]]; then
  echo "Grok schedules to delete:"
  python3 - "$GROK_LOOPS" << 'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for job in data.get("jobs", []):
    print(f"{job.get('kind','?')}\t{job.get('id','')}\t{job.get('prompt','')}")
PY
  echo "Call scheduler_delete once per id above."
  STOPPED=1
fi

if [[ "$STOPPED" -eq 0 ]]; then
  echo "ℹ️  No stop-hook state and no recorded Grok schedule."
  echo "   If scheduler_list shows a fix or monitor loop, delete it anyway."
fi
```

If `scheduler_list` is available, delete every job whose prompt is `/autocoder:gate`, `/autocoder:dispatch`, `/autocoder:fix`, `/autocoder:monitor-workers`, or the same command without the `autocoder:` prefix. A recorded id that is already gone is fine. Then:

```bash
rm -f .grok/autocoder-loops.json
echo "   To restart: /fix-loop or /monitor-loop"
```
