---
description: Stop the fix loop
---

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
  echo "🛑 Fix-github loop stopped"
  echo "   Completed iterations: ${ITERATION:-0}"
  echo ""
  echo "   To restart: /fix-loop"
else
  echo "ℹ️  No active fix loop found"
  echo ""
  echo "   To start a loop: /fix-loop"
fi
```
