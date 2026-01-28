---
description: Start infinite fix loop with stop hook
---

# Start Infinite Fix-GitHub Loop

Runs `/fix` in an infinite loop until manually stopped.

## Usage

```bash
# Start infinite loop
/fix-loop

# Limit to 100 iterations
/fix-loop 100

# Custom idle sleep time (default: 15 minutes)
/fix-loop --sleep 30
```

## How It Works

1. Runs `/fix` to process all priority issues
2. When `/fix` outputs `IDLE_NO_WORK_AVAILABLE`, sleeps for configured duration
3. Repeats until manually stopped (Ctrl+C) or max iterations reached

## Stopping the Loop

- **Ctrl+C** - Manual interrupt
- **Max iterations** - If set, stops when reached

## Instructions

**Note**: Antigravity doesn't support Claude Code's stop hook mechanism. Instead, this workflow runs `/fix` repeatedly in a simple while loop.

```bash
# Parse arguments
MAX_ITERATIONS="${1:-0}"  # 0 = unlimited
IDLE_SLEEP_MINUTES="15"

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case ${args[i]} in
    --sleep)
      IDLE_SLEEP_MINUTES="${args[i+1]}"
      ((i++))
      ;;
    [0-9]*)
      MAX_ITERATIONS="${args[i]}"
      ;;
  esac
done

# Create stop signal file location
STOP_FILE=".git/.fix-loop-stop"
rm -f "$STOP_FILE" 2>/dev/null

echo ""
echo "🔄 Starting infinite /fix loop"
echo "   Max iterations: $([ "$MAX_ITERATIONS" = "0" ] && echo "unlimited" || echo "$MAX_ITERATIONS")"
echo "   Idle sleep: $IDLE_SLEEP_MINUTES minutes"
echo ""
echo "To stop: Press Ctrl+C or run: touch $STOP_FILE"
echo ""

ITERATION=0
while true; do
  # Check for stop signal
  if [ -f "$STOP_FILE" ]; then
    echo "🛑 Stop signal detected. Exiting loop."
    rm -f "$STOP_FILE"
    break
  fi

  # Check max iterations
  if [ "$MAX_ITERATIONS" != "0" ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
    echo "✅ Reached max iterations ($MAX_ITERATIONS). Exiting loop."
    break
  fi

  ITERATION=$((ITERATION + 1))
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🔄 Iteration $ITERATION"
  if [ "$MAX_ITERATIONS" != "0" ]; then
    echo "   Progress: $ITERATION / $MAX_ITERATIONS"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Run /compact before each iteration to prevent context overflow
  echo "🗜️  Compacting context..."
  # Note: Antigravity doesn't have /compact command like Claude
  # Context management happens automatically

  # Run the fix workflow
  echo "🔧 Running /fix workflow..."
  echo ""
```

Now execute the `/fix` workflow. After it completes, check if it output `IDLE_NO_WORK_AVAILABLE`.

**After `/fix` completes, continue:**

```bash
  # Check if we should sleep (idle state)
  # The /fix workflow outputs "IDLE_NO_WORK_AVAILABLE" when there's no work
  # For Antigravity, we'll just sleep between iterations
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "💤 Iteration $ITERATION complete"
  echo "   Sleeping for $IDLE_SLEEP_MINUTES minutes before next iteration..."
  echo "   (Press Ctrl+C to stop, or: touch $STOP_FILE)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  # Sleep in 1-minute increments to allow Ctrl+C interruption
  SLEEP_SECONDS=$((IDLE_SLEEP_MINUTES * 60))
  for ((s=0; s<SLEEP_SECONDS; s+=60)); do
    if [ -f "$STOP_FILE" ]; then
      echo "🛑 Stop signal detected during sleep. Exiting loop."
      rm -f "$STOP_FILE"
      exit 0
    fi
    sleep 60
  done
done

echo ""
echo "✅ Fix loop completed"
echo "   Total iterations: $ITERATION"
echo ""
```

## Alternative: Manual Loop

If the automatic loop doesn't work well with Antigravity, you can manually run:

```bash
# Simple infinite loop
while true; do
  echo "Running /fix..."
  # Execute /fix workflow here
  echo "Sleeping 15 minutes..."
  sleep 900
done
```
