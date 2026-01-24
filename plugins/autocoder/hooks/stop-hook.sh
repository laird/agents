#!/bin/bash

# Autocoder Stop Hook
# Prevents session exit when fix loop is active
# Feeds the /fix prompt back to continue the loop

set -euo pipefail

# Read hook input from stdin (advanced stop hook API)
HOOK_INPUT=$(cat)

# Check if fix loop is active
LOOP_STATE_FILE=".claude/fix-loop.local.md"

if [[ ! -f "$LOOP_STATE_FILE" ]]; then
    # No active loop - allow exit
    exit 0
fi

# Parse markdown frontmatter (YAML between ---) and extract values
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$LOOP_STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
IDLE_SLEEP_MINUTES=$(echo "$FRONTMATTER" | grep '^idle_sleep_minutes:' | sed 's/idle_sleep_minutes: *//' || echo "15")

# Validate numeric fields before arithmetic operations
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
    echo "⚠️ Fix-github loop: State file corrupted" >&2
    echo "  File: $LOOP_STATE_FILE" >&2
    echo "  Problem: 'iteration' field is not a valid number (got: '$ITERATION')" >&2
    echo "" >&2
    echo "  Run /fix-loop again to start fresh." >&2
    rm "$LOOP_STATE_FILE"
    exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
    echo "⚠️ Fix-github loop: State file corrupted" >&2
    echo "  File: $LOOP_STATE_FILE" >&2
    echo "  Problem: 'max_iterations' field is not a valid number (got: '$MAX_ITERATIONS')" >&2
    rm "$LOOP_STATE_FILE"
    exit 0
fi

# Check if max iterations reached (0 = unlimited)
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
    echo "🛑 Fix-github loop: Max iterations ($MAX_ITERATIONS) reached."
    rm "$LOOP_STATE_FILE"
    exit 0
fi

# Get transcript path from hook input
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
    echo "⚠️ Fix-github loop: Transcript file not found" >&2
    echo "  Expected: $TRANSCRIPT_PATH" >&2
    rm "$LOOP_STATE_FILE"
    exit 0
fi

# Check for stop signals in last assistant message
if grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
    LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
    LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '
        .message.content |
        map(select(.type == "text")) |
        map(.text) |
        join("\n")
    ' 2>/dev/null || echo "")

    # Check for explicit stop signals
    if echo "$LAST_OUTPUT" | grep -qi "STOP_FIX_GITHUB_LOOP"; then
        echo "🛑 Fix-github loop: Explicit stop signal detected"
        rm "$LOOP_STATE_FILE"
        exit 0
    fi

    # Check for critical errors that should pause the loop
    if echo "$LAST_OUTPUT" | grep -qiE "(fatal error|authentication failed|rate limit exceeded|API quota)"; then
        echo "⚠️ Fix-github loop: Critical error detected, pausing loop" >&2
        echo "  Review the error and run /fix-loop to resume" >&2
        rm "$LOOP_STATE_FILE"
        exit 0
    fi

    # Check for idle state - nothing useful to do, sleep and retry
    if echo "$LAST_OUTPUT" | grep -qi "IDLE_NO_WORK_AVAILABLE"; then
        echo "😴 Fix-github loop: No work available, sleeping for $IDLE_SLEEP_MINUTES minutes..."
        sleep $((IDLE_SLEEP_MINUTES * 60))
        echo "⏰ Waking up, checking for new work..."
    fi
fi

# Not complete - continue loop
NEXT_ITERATION=$((ITERATION + 1))

# Extract prompt (everything after the closing ---)
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$LOOP_STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
    echo "⚠️ Fix-github loop: No prompt text found in state file" >&2
    rm "$LOOP_STATE_FILE"
    exit 0
fi

# Update iteration in frontmatter
TEMP_FILE="${LOOP_STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$LOOP_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$LOOP_STATE_FILE"

# Build system message
if [[ $MAX_ITERATIONS -gt 0 ]]; then
    SYSTEM_MSG="🔄 Fix-github iteration $NEXT_ITERATION/$MAX_ITERATIONS | To stop: output STOP_FIX_GITHUB_LOOP or press Ctrl+C"
else
    SYSTEM_MSG="🔄 Fix-github iteration $NEXT_ITERATION (unlimited) | To stop: output STOP_FIX_GITHUB_LOOP or press Ctrl+C"
fi

# Output JSON to block the stop and feed prompt back
jq -n \
    --arg prompt "$PROMPT_TEXT" \
    --arg msg "$SYSTEM_MSG" \
    '{
        "decision": "block",
        "reason": $prompt,
        "systemMessage": $msg
    }'

exit 0
