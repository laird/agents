# Stop Fix Loop

Stops the infinite `/fix-loop` by removing the state file.

## Usage

```bash
/stop-loop
```

## Instructions

```bash
LOOP_STATE_FILE=".claude/fix-loop.local.md"

if [[ -f "$LOOP_STATE_FILE" ]]; then
  # Extract current iteration for status message
  ITERATION=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$LOOP_STATE_FILE" | grep '^iteration:' | sed 's/iteration: *//')

  rm "$LOOP_STATE_FILE"
  echo "🛑 Fix loop stopped"
  echo "   Completed iterations: ${ITERATION:-0}"
  echo ""
  echo "   To restart: /fix-loop"
else
  echo "ℹ️  No active fix loop found"
  echo ""
  echo "   To start a loop: /fix-loop"
fi
```

On Grok, also cancel the schedules `/fix-loop` and `/monitor-loop` created with `scheduler_create`. Do this only when `scheduler_list` or `scheduler_delete` is available. Leave the Claude Code steps above unchanged.

If `.grok/autocoder-loops.json` exists, `scheduler_delete` each id in it, then remove the file. Also delete any listed job whose prompt is `/autocoder:gate`, `/autocoder:dispatch`, `/autocoder:fix`, `/autocoder:monitor-workers`, or the same command without the `autocoder:` prefix. A missing id is fine.
