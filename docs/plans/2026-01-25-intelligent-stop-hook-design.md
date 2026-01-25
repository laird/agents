# Intelligent Stop Hook Design

**Date**: 2026-01-25
**Status**: Approved
**Problem**: Stop hook unconditionally triggers `/fix` when fix-loop is active, interrupting other work

## Overview

Add multi-layered activity detection to the stop hook so it only triggers `/fix` when Claude is truly idle, preventing annoying interruptions during active work.

## Problem Statement

The current stop hook (`plugins/autocoder/hooks/stop-hook.sh`) checks only if `.claude/fix-loop.local.md` exists. If present, it always feeds `/fix` back to continue the loop, regardless of what else Claude might be working on. This interrupts:
- Active task execution
- Ongoing conversations
- File editing sessions
- Other workflows in progress

## Solution

Implement comprehensive activity detection that checks multiple signals before triggering `/fix`.

### Detection Strategy

The hook will only trigger `/fix` when ALL of these conditions are met:

1. **Fix-loop is active** - `.claude/fix-loop.local.md` exists (existing check)
2. **No active tasks** - Task system has no pending/in_progress tasks
3. **No recent transcript activity** - Last message ≥ 2 minutes ago
4. **No recent file changes** - No files modified in last 5 minutes

If ANY condition fails → Exit cleanly (allow stop, don't interrupt)
If ALL conditions pass → Continue loop (feed `/fix` back)

### Time Thresholds (Conservative)

- **Transcript activity**: 2 minutes
- **File modifications**: 5 minutes
- **Rationale**: Conservative thresholds minimize interrupt risk, slight delay in resuming `/fix` is acceptable

## Implementation

### File Changes

**Primary**:
- `plugins/autocoder/hooks/stop-hook.sh` - Add activity detection functions and integration logic

**Mirror** (parallel maintenance required):
- `.agent/hooks/stop-hook.sh` - Identical changes for Antigravity compatibility

### New Functions

#### 1. Task Detection
```bash
# Check if Claude Code task system has active work
# Returns 0 if tasks active, 1 if idle
check_active_tasks() {
    # Look for .claude/tasks/*.json files
    if [ -d ".claude/tasks" ]; then
        # Check for any pending or in_progress tasks
        grep -l '"status":"pending"\|"status":"in_progress"' \
            .claude/tasks/*.json 2>/dev/null
        return $?
    fi
    return 1  # No tasks dir = idle
}
```

#### 2. Transcript Recency
```bash
# Check if last transcript message is recent (< 2 min)
# Returns 0 if recent activity, 1 if idle
check_transcript_activity() {
    local transcript_path="$1"
    local threshold_seconds=120  # 2 minutes

    # Get timestamp of last assistant message
    local last_msg_time=$(grep '"role":"assistant"' "$transcript_path" | \
        tail -1 | jq -r '.timestamp // empty')

    if [ -n "$last_msg_time" ]; then
        local now=$(date +%s)
        local msg_time=$(date -d "$last_msg_time" +%s 2>/dev/null || echo 0)
        local age=$((now - msg_time))

        [ $age -lt $threshold_seconds ]
        return $?
    fi
    return 1  # No timestamp = idle
}
```

#### 3. File Modification Activity
```bash
# Check if any files modified in last 5 minutes
# Returns 0 if recent changes, 1 if idle
check_file_activity() {
    local threshold_minutes=5

    # Find files modified in last N minutes (exclude .claude/, .git/)
    find . -type f -mmin -$threshold_minutes \
        ! -path './.claude/*' \
        ! -path './.git/*' \
        -print -quit 2>/dev/null | grep -q .

    return $?
}
```

### Integration Point

Insert after line 60 (transcript validation), before existing stop signal checks (line 63):

```bash
# ============================================================
# ACTIVITY DETECTION - Only trigger /fix if truly idle
# ============================================================

# Check 1: Active tasks in task system
if check_active_tasks; then
    echo "⏸️  Fix-github loop: Paused - active tasks detected" >&2
    echo "   The loop will resume when tasks are complete" >&2
    exit 0
fi

# Check 2: Recent transcript activity (< 2 minutes)
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
```

## Error Handling

### Graceful Degradation
- Task detection fails → Assume idle, continue to next check
- Transcript timestamp missing → Assume idle, continue to next check
- `find` command fails → Assume idle, continue (fail-safe)

### Performance
- `find` limited to single result with `-print -quit` (fast exit)
- `grep` on task files is lightweight (small JSON files)
- Total overhead: ~50-100ms per stop attempt

### Race Conditions
- User stops Claude manually (Ctrl+C) → Loop exits normally
- User starts new task while hook running → Next stop catches it
- Multiple hooks running → Each reads same state file (safe, read-only)

### Edge Cases
- No activity signals ever detected → Defaults to "idle", allows loop continuation
- Prevents loop from getting permanently stuck

## Backward Compatibility

- Works with existing `/fix-loop` behavior
- Works when task system not used (falls back to time-based checks)
- Works with manual `/fix` calls (no loop state = exits normally)
- Existing stop signals unchanged:
  - `STOP_FIX_GITHUB_LOOP` - Explicit stop
  - Critical errors - Fatal/auth/rate limit
  - Max iterations - Configured limit reached
  - Idle sleep - `IDLE_NO_WORK_AVAILABLE` signal

## Testing Plan

### Test Case 1: Active Tasks
```bash
# Setup: Create pending task
mkdir -p .claude/tasks
echo '{"status":"pending","subject":"Test"}' > .claude/tasks/test.json

# Action: Start /fix-loop, press Ctrl+D
# Expected: "Paused - active tasks detected"
```

### Test Case 2: Recent Transcript Activity
```bash
# Setup: Fresh conversation (< 2 min old)
# Action: Press Ctrl+D immediately after Claude responds
# Expected: "Paused - recent conversation activity"
```

### Test Case 3: Recent File Changes
```bash
# Setup: Edit any file
touch test-file.txt

# Action: Press Ctrl+D within 5 minutes
# Expected: "Paused - recent file changes detected"
```

### Test Case 4: Truly Idle
```bash
# Setup: No tasks, wait 5+ minutes with no activity
# Action: Press Ctrl+D
# Expected: "Idle detected, continuing..." + /fix runs
```

### Test Case 5: Existing Stop Signals
```bash
# Action: Output STOP_FIX_GITHUB_LOOP
# Expected: Loop stops regardless of activity
```

## Success Criteria

- [ ] Hook detects active tasks and pauses loop
- [ ] Hook detects recent transcript activity and pauses loop
- [ ] Hook detects recent file changes and pauses loop
- [ ] Hook continues loop when truly idle
- [ ] Existing stop signals still work
- [ ] Both Claude Code and Antigravity versions updated
- [ ] All test cases pass
- [ ] No performance degradation (< 100ms overhead)

## Future Enhancements

Potential improvements for later iterations:

- Configurable thresholds in loop state file
- Support for other loop types beyond fix-loop
- Activity detection metrics/logging
- User-configurable activity signals
