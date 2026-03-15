# Modernize + Autocoder Integration Design

**Date**: 2026-03-15
**Status**: Approved

## Problem

The modernize plugin handles test failures during migration phases via direct fix-and-retest cycles between Coder and Tester agents. This is sequential and doesn't leverage the parallel agent infrastructure that autocoder provides. When both plugins are installed, modernize should be able to file failures as GitHub issues and let autocoder workers resolve them in parallel.

## Design

### Detection (Prerequisites Check)

At startup, modernize detects:

1. **Autocoder plugin** — check if autocoder commands are available (look for autocoder plugin in installed plugins or check for the fix command)
2. **Swarm environment** — detect tmux session, cmux workspaces, or plain terminal
3. **Report and recommend**:
   - Autocoder + swarm: "Test failures will be filed as GitHub issues and resolved by worker agents in parallel."
   - Autocoder, no swarm: "Recommend running in a swarm: `startt 3` then `/modernize` in the manager session."
   - No autocoder: "Using direct fix-and-retest cycles. Install autocoder for parallel issue resolution."

### Detection Logic

```bash
# Detect autocoder plugin
AUTOCODER_AVAILABLE=false
if claude plugins list 2>/dev/null | grep -q "autocoder"; then
  AUTOCODER_AVAILABLE=true
fi

# Detect swarm environment
SWARM_ENV="none"
if [ -n "$TMUX" ]; then
  SWARM_ENV="tmux"
  # Count worker panes/windows
  WORKER_COUNT=$(tmux list-panes -a 2>/dev/null | wc -l)
elif cmux list-workspaces 2>/dev/null | grep -q "wt"; then
  SWARM_ENV="cmux"
  WORKER_COUNT=$(cmux list-workspaces 2>/dev/null | grep "wt" | wc -l)
fi
```

### Issue Creation (on test failures)

When a phase encounters test failures and autocoder is available:

1. **Analyze failures** — group by likely root cause:
   - Same module/directory
   - Same API change or dependency update
   - Same error pattern/message
2. **Create one GitHub issue per root-cause group**:
   - Title: `[modernize] Phase N: <root cause description>`
   - Priority label: P0 for blocking failures, P1 for others
   - `modernize` label to distinguish from regular issues
   - Body includes: phase context, what was changed, which tests fail, error messages
3. **Log issue creation** to HISTORY.md

### Issue Template

```markdown
## Modernize Phase {N} - {Phase Name}

**Root Cause**: {description of the change that caused failures}

**Changed**: {what was modified - dependency update, API replacement, etc.}

**Failing Tests** ({count}):
- `test/path/file1.test.js` - {error summary}
- `test/path/file2.test.js` - {error summary}

**Context**: This issue was created by `/modernize` during Phase {N} ({phase name}).
Fix the failing tests to unblock the modernization workflow.

**Phase Quality Gate**: {what needs to pass for the phase to proceed}
```

### Wait Loop (coordination)

After creating issues, modernize enters a wait loop using the best available coordination:

```
while issues remain open:
  1. Check GitHub: gh issue list --label modernize --state open
  2. If swarm detected (tmux/cmux):
     a. Read worker screens to check activity
     b. Detect idle workers, dispatch if unassigned issues exist
     c. Detect stuck workers (no activity >30 min), alert user
  3. If plain terminal:
     a. Check if issues have 'working' label (agent picked them up)
     b. If issue open >30 min with no 'working' label, prompt user
  4. Sleep 2-3 minutes between checks

when all issues closed:
  Re-run phase quality gate (build + tests)
  If passes: proceed to next phase
  If fails: create issues for new failures, repeat
```

### Worker Screen Reading

**tmux**:
```bash
# Read last 15 lines of each worker pane
for pane in $(tmux list-panes -t "$SESSION:0" -F '#{pane_index}'); do
  STATUS=$(tmux capture-pane -t "$SESSION:0.$pane" -p | tail -15)
  # Check for idle indicators: prompt, "waiting", "no issues"
  # Check for active indicators: "fixing", "running tests", "working on"
done
```

**cmux**:
```bash
# Read each worker workspace screen
for ws in $(cmux list-workspaces | grep "wt"); do
  STATUS=$(cmux read-screen --workspace "$ws" --lines 15)
  # Same idle/active detection
done
```

**Dispatch idle workers**:
```bash
# tmux
tmux send-keys -t "$SESSION:0.$pane" "/autocoder:fix $ISSUE_NUM" Enter

# cmux
cmux send --workspace "$ws" "/autocoder:fix $ISSUE_NUM"
cmux send-key --workspace "$ws" Enter
```

### Fallback Behavior (no autocoder)

When autocoder is NOT installed, behavior is identical to current:
- Direct fix-and-retest cycles between Coder and Tester agents
- No GitHub issues created for internal failures
- No swarm coordination
- All existing phase logic unchanged

### Recommended Workflow (for README)

```bash
# 1. Install both plugins
/plugin install modernize autocoder

# 2. One-time setup (installs stop hook, scripts, aliases)
/install

# 3. Start the swarm from your terminal
cd ~/src/myproject
startt 3          # 3 workers + 1 manager

# 4. In the manager session, run the modernization
/assess           # Evaluate viability
/plan             # Create execution strategy
/modernize        # Execute — creates issues, workers fix in parallel

# 5. While modernize runs, use manager commands as needed
/review-blocked   # Approve architectural decisions workers can't handle
/monitor-workers  # Check worker progress, dispatch idle workers

# 6. When done, tear down
endt
```

## Files to Modify

1. **`plugins/modernize/commands/modernize.md`** — add autocoder detection in Prerequisites, issue creation logic in phase failure handling, wait loop for issue resolution
2. **`plugins/modernize/README.md`** — add "Integration with Autocoder" section with recommended workflow
3. **`.agent/workflows/modernize.md`** — parallel changes for Antigravity compatibility

## What Does NOT Change

- All 7 phases, their ordering, and quality gates
- Agent roles and responsibilities
- `/assess`, `/plan`, `/retro`, `/retro-apply` commands
- All behavior when autocoder is not installed
- The modernize label system (separate from autocoder's label system)
