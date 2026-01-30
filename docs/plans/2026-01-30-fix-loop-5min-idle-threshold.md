# Fix-Loop 5-Minute Idle Threshold

**Date**: 2026-01-30
**Status**: Approved
**Problem**: Fix-loop interrupts active work with 2-minute transcript threshold

## Overview

Increase the transcript activity threshold from 2 minutes to 5 minutes in the stop hook to create a consistent idle detection window and reduce interruptions during active work.

## Problem Statement

The current stop hook uses a 2-minute threshold for transcript activity detection, which is too aggressive. This causes the fix-loop to interrupt:
- Natural conversation pauses (3-4 minutes of thinking/reading)
- Active brainstorming sessions
- Code review and analysis work

Real-world evidence: Fix-loop interrupted an active brainstorming session because the 2-minute threshold was too short.

## Solution

Change the transcript activity threshold from 2 minutes to 5 minutes to match the file activity threshold, creating a unified 5-minute idle window.

### Detection Strategy

The stop hook will use a **5-minute idle window** before triggering the next `/fix` iteration:

**Activity Signals (all must be quiet for 5+ minutes):**

1. **Conversation activity** - No transcript messages in last 5 minutes
2. **File editing activity** - No file modifications in last 5 minutes
3. **Active tasks** - No pending/in_progress tasks (blocking check)

**Logic:**
```
IF fix-loop is active:
  IF active tasks exist → pause (immediate block)
  IF transcript activity < 5 min → pause
  IF file changes < 5 min → pause
  ELSE → continue loop (trigger /fix)
```

## Implementation

**Files Modified:**
1. `plugins/autocoder/hooks/stop-hook.sh` (Claude Code)
2. `.agent/hooks/stop-hook.sh` (Antigravity mirror)

**Change:**

In `check_transcript_activity()` function:

```bash
# BEFORE:
local threshold_seconds=120  # 2 minutes

# AFTER:
local threshold_seconds=300  # 5 minutes
```

**Added documentation:**
```bash
# Check if last transcript message is recent (< 5 min)
# Returns 0 if recent activity, 1 if idle
# Note: 5-minute threshold matches file activity check for consistent idle detection
check_transcript_activity() {
    local transcript_path="$1"
    local threshold_seconds=300  # 5 minutes (unified idle window)
    ...
}
```

## User Experience

**Behavior Changes:**

| Scenario | Old Behavior | New Behavior |
|----------|--------------|--------------|
| Quick 3-minute conversation | Interrupted after conversation | Waits full 5 min ✓ |
| Editing files for 4 minutes | Paused (5 min file check) | Paused (consistent) ✓ |
| Reading/thinking (no activity) | Loops after 2 min | Loops after 5 min ✓ |
| Active task in progress | Paused immediately | Paused immediately (unchanged) |

**Benefits:**
- Less intrusive - Loop waits 5 minutes instead of 2
- Consistent idle window - Both checks use same threshold
- Predictable behavior - Users can work up to 5 minutes without interruption

**Unchanged:**
- Stop signals (STOP_FIX_GITHUB_LOOP)
- Critical error detection
- Max iterations enforcement
- Idle sleep configuration (--sleep flag)

## Testing

Manual verification:
1. Start fix-loop
2. Have active conversation
3. Verify loop pauses during activity
4. Wait 5+ minutes of silence
5. Verify loop resumes

Expected: Loop pauses during conversation, resumes only after 5 minutes of true idle time.

## Success Criteria

- [x] Transcript threshold changed to 5 minutes
- [x] Both Claude Code and Antigravity versions updated
- [x] Comments updated to reflect unified idle window
- [ ] Manual testing confirms 5-minute idle window works
- [ ] No interruptions during active work
