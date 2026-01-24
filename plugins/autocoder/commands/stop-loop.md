# Stop Fix-GitHub Loop

Stops the infinite `/fix-github-loop` by removing the state file.

## Usage

```bash
/stop-loop
```

## Instructions

```bash
LOOP_STATE_FILE=".claude/fix-github-loop.local.md"

if [[ -f "$LOOP_STATE_FILE" ]]; then
  # Extract current iteration for status message
  ITERATION=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$LOOP_STATE_FILE" | grep '^iteration:' | sed 's/iteration: *//')

  rm "$LOOP_STATE_FILE"
  echo "🛑 Fix-github loop stopped"
  echo "   Completed iterations: ${ITERATION:-0}"
  echo ""
  echo "   To restart: /fix-github-loop"
else
  echo "ℹ️  No active fix-github loop found"
  echo ""
  echo "   To start a loop: /fix-github-loop"
fi
```
