#!/bin/bash

# Autocoder Stop Hook
# Prevents session exit when fix loop is active
# Feeds the /fix prompt back to continue the loop

set -euo pipefail

# ============================================================
# ACTIVITY DETECTION FUNCTIONS
# ============================================================

# Check if Claude Code task system has active work
# Returns 0 if tasks active, 1 if idle
check_active_tasks() {
    # Look for .claude/tasks/*.json files
    if [[ -d ".claude/tasks" ]]; then
        # Check for any pending or in_progress tasks
        if grep -l '"status":"pending"\|"status":"in_progress"' \
            .claude/tasks/*.json 2>/dev/null | grep -q .; then
            return 0  # Tasks active
        fi
    fi
    return 1  # No tasks or no tasks dir = idle
}

# Check if last transcript message is recent (< 5 min)
# Returns 0 if recent activity, 1 if idle
# Note: 5-minute threshold matches file activity check for consistent idle detection
check_transcript_activity() {
    local transcript_path="$1"
    local threshold_seconds=300  # 5 minutes (unified idle window)

    # Get timestamp of last assistant message
    local last_msg_time=$(grep '"role":"assistant"' "$transcript_path" | \
        tail -1 | jq -r '.timestamp // empty' 2>/dev/null || echo "")

    if [[ -n "$last_msg_time" ]]; then
        local now=$(date +%s)
        local msg_time=$(date -d "$last_msg_time" +%s 2>/dev/null || echo 0)
        local age=$((now - msg_time))

        if [[ $age -lt $threshold_seconds ]]; then
            return 0  # Recent activity
        fi
    fi
    return 1  # No timestamp or old = idle
}

# Check if any files modified in last 5 minutes
# Returns 0 if recent changes, 1 if idle
check_file_activity() {
    local threshold_minutes=5

    # Find files modified in last N minutes (exclude .claude/, .git/)
    if find . -type f -mmin -$threshold_minutes \
        ! -path './.claude/*' \
        ! -path './.git/*' \
        -print -quit 2>/dev/null | grep -q .; then
        return 0  # Recent file changes
    fi

    return 1  # No recent changes = idle
}

# ============================================================
# MAIN HOOK LOGIC
# ============================================================

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

# ============================================================
# ACTIVITY DETECTION - Only trigger /fix if truly idle
# ============================================================

# Check 1: Active tasks in task system
if check_active_tasks; then
    echo "⏸️  Fix-github loop: Paused - active tasks detected" >&2
    echo "   The loop will resume when tasks are complete" >&2
    exit 0
fi

# Check 2: Recent transcript activity (< 5 minutes)
if check_transcript_activity "$TRANSCRIPT_PATH"; then
    echo "⏸️  Fix-github loop: Paused - recent conversation activity" >&2
    exit 0
fi

# Check 3: Recent file modifications (< 5 minutes)
if check_file_activity; then
    echo "⏸️  Fix-github loop: Paused - recent file changes detected" >&2
    exit 0
fi

# All checks passed - Claude is idle, safe to continue loop
echo "✅ Fix-github loop: Idle detected, continuing..." >&2

# ============================================================
# STOP SIGNAL DETECTION
# ============================================================

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
