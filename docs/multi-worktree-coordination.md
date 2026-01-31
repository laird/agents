# Multi-Worktree Coordination with /fix-loop-coordinated

Complete guide for coordinating parallel Claude Code agents across git worktrees with automatic deployment.

## Overview

When multiple Claude Code agents work in parallel worktrees, `/fix-loop-coordinated` provides automatic coordination and deployment:

1. **Work Phase**: Agents in separate worktrees complete tasks independently
2. **Coordination**: All agents share a task list via `CLAUDE_CODE_TASK_LIST_ID`
3. **Deployment**: Main worktree detects completion, pulls all branches, deploys to staging
4. **Continuation**: Fix loop continues after deployment

## Architecture

```
Main Worktree (Coordinator)          Worktree 1              Worktree 2
┌─────────────────────┐              ┌──────────────┐        ┌──────────────┐
│ /fix-loop-coordinated│              │ Claude Code  │        │ Claude Code  │
│ ┌─────────────────┐ │              │              │        │              │
│ │ Creates Tasks:  │ │              │ Claims       │        │ Claims       │
│ │ - Work Task 1   │ │◄────────────►│ Task 1       │        │ Task 2       │
│ │ - Work Task 2   │ │              │              │        │              │
│ │ - Deploy Task   │ │              │ Pushes       │        │ Pushes       │
│ │   (blocked)     │ │              │ feature/auth │        │ feature/api  │
│ └─────────────────┘ │              │              │        │              │
│         ↓           │              │ Marks        │        │ Marks        │
│ Monitors Task List  │              │ Complete ✓   │        │ Complete ✓   │
│         ↓           │              └──────────────┘        └──────────────┘
│ Deploy Unblocked!   │                      │                      │
│         ↓           │                      └──────────┬───────────┘
│ Pull + Merge        │                                 │
│         ↓           │                        Shared Task List
│ Deploy to Staging   │                    (CLAUDE_CODE_TASK_LIST_ID)
│         ↓           │
│ Continue /fix loop  │
└─────────────────────┘
```

## Setup

### 1. Set Shared Task List ID

All Claude Code sessions must use the same task list ID:

```bash
# Option A: Set in environment (affects all sessions)
export CLAUDE_CODE_TASK_LIST_ID="myproject-$(date +%Y%m%d)"

# Option B: Set in .envrc for automatic loading (recommended)
echo 'export CLAUDE_CODE_TASK_LIST_ID="myproject-2026-01-30"' > .envrc
direnv allow

# Verify in each worktree
echo $CLAUDE_CODE_TASK_LIST_ID
```

### 2. Create Worktrees

```bash
# Main worktree (coordinator)
cd /path/to/project

# Create parallel worktrees for feature work
git worktree add ../project-wt-auth feature/auth
git worktree add ../project-wt-api feature/api
git worktree add ../project-wt-ui feature/ui
```

### 3. Create Deployment Script

```bash
# Copy template
cp scripts/deploy-staging-template.sh scripts/deploy-staging.sh

# Customize for your deployment method
vim scripts/deploy-staging.sh
```

## Usage Workflow

### Main Worktree: Start Coordination

```bash
cd /path/to/project

# Start coordinated fix loop
/fix-loop-coordinated
```

This will:
1. Check for existing tasks or prompt to create them
2. Create deployment task blocked by all work tasks
3. Install coordinated stop hook
4. Start `/fix` loop

### Each Worktree: Claim and Complete Tasks

```bash
# In worktree 1
cd /path/to/project-wt-auth

# Start Claude Code session (shares same CLAUDE_CODE_TASK_LIST_ID)
claude

# Agent sees shared task list, claims Task 1
# Works on feature/auth
# Pushes branch when complete
# Marks task complete
```

```bash
# In worktree 2
cd /path/to/project-wt-api

claude

# Agent claims Task 2
# Works on feature/api
# Pushes and marks complete
```

### Automatic Deployment

When the last worktree agent marks their task complete:

1. **Detection**: Main worktree's stop hook detects deployment task is unblocked
2. **Collection**: Gathers all completed task branches from metadata
3. **Integration**: Pulls and merges each feature branch
4. **Deployment**: Executes `scripts/deploy-staging.sh`
5. **Logging**: Records deployment in `.claude/deployment-*.log` and `HISTORY.md`
6. **Continuation**: Marks deployment task complete, continues fix loop

## Task Structure

### Work Tasks (Created per Worktree)

```json
{
  "id": "1",
  "subject": "Migrate authentication module",
  "description": "Implement auth migration in worktree-auth, push feature/auth",
  "status": "pending",
  "metadata": {
    "worktree": "project-wt-auth",
    "branch": "feature/auth",
    "agent": "coder-1"
  }
}
```

### Deployment Task (Coordinator)

```json
{
  "id": "4",
  "subject": "Deploy to staging",
  "description": "Pull all feature branches, merge, deploy staging",
  "status": "pending",
  "blockedBy": ["1", "2", "3"],
  "metadata": {
    "coordinator": true,
    "autoTrigger": true
  }
}
```

As work tasks complete, `blockedBy` shrinks to `[]`, triggering deployment.

## Stop Hook Behavior

The coordinated stop hook (`stop-hook-coordinated.sh`) extends the standard fix-loop behavior:

### Standard Checks (Inherited)
- ✅ Active tasks detection (pauses if work in progress)
- ✅ Transcript activity check (< 5 min)
- ✅ File modification check (< 5 min)
- ✅ Stop signal detection (`STOP_FIX_GITHUB_LOOP`)
- ✅ Idle sleep when no work available

### Coordination Extensions
- ✅ **Deployment task detection**: Finds tasks with `metadata.coordinator = true`
- ✅ **Unblock detection**: Checks if `blockedBy` array is empty
- ✅ **Branch collection**: Gathers branches from completed task metadata
- ✅ **Automatic deployment**: Executes pull → merge → deploy workflow
- ✅ **Audit logging**: Records deployment details

## Monitoring

### Check Task Status

```bash
# In any worktree (shared task list)
claude

# Inside Claude Code session
> TaskList()
```

Output shows:
- All work tasks and their status
- Deployment task and blocking dependencies
- Who owns each task

### Check Deployment Logs

```bash
# View latest deployment log
ls -lt .claude/deployment-*.log | head -1 | xargs cat

# Check HISTORY.md
tail -50 HISTORY.md
```

## Stopping the Loop

```bash
# Method 1: Ctrl+C in main worktree

# Method 2: Delete state file
rm .claude/fix-loop.local.md

# Method 3: Output stop signal (Claude)
> "STOP_FIX_GITHUB_LOOP - deployment complete, stopping loop"
```

## Advanced Configuration

### Custom Idle Sleep Time

```bash
# Sleep 30 minutes when idle instead of default 15
/fix-loop-coordinated --sleep 30
```

### Max Iterations

```bash
# Stop after 100 iterations
/fix-loop-coordinated --max 100

# Or positional argument
/fix-loop-coordinated 100
```

### Multiple Deployment Tasks

You can have multiple coordinator tasks for different environments:

```json
{
  "subject": "Deploy to staging",
  "metadata": { "coordinator": true, "environment": "staging" }
},
{
  "subject": "Deploy to production",
  "metadata": { "coordinator": true, "environment": "production" },
  "blockedBy": ["staging-deployment-task-id"]
}
```

The hook triggers the first unblocked coordinator task.

## Troubleshooting

### Issue: Deployment not triggering

**Check:**
1. Are all work tasks marked `completed`?
2. Is deployment task `blockedBy` array empty?
3. Is deployment task status `pending` (not `in_progress` or `completed`)?
4. Does deployment task have `metadata.coordinator = true`?

```bash
# Debug: Inspect deployment task
jq . .claude/tasks/*.json | grep -A 20 '"coordinator":true'
```

### Issue: Branches not found during deployment

**Check:**
1. Did worktree agents push their branches to origin?
2. Do completed tasks have `metadata.branch` set correctly?

```bash
# Verify branches exist on GitHub
gh api repos/:owner/:repo/branches | jq '.[].name'

# Check task metadata
jq '.metadata.branch' .claude/tasks/*.json
```

### Issue: Deployment script fails

**Check:**
1. Does `scripts/deploy-staging.sh` exist and have execute permissions?
2. Review deployment log for error details:

```bash
cat .claude/deployment-*.log | tail -100
```

### Issue: Different task lists in worktrees

**Check:**
1. Verify `CLAUDE_CODE_TASK_LIST_ID` is identical in all sessions:

```bash
# In each worktree
echo $CLAUDE_CODE_TASK_LIST_ID
```

2. If different, set explicitly:

```bash
export CLAUDE_CODE_TASK_LIST_ID="myproject-2026-01-30"
```

## Integration with Existing Commands

### With /modernize

```bash
# Use coordinated fix-loop during modernization
/modernize

# When coder agents dispatched to worktrees:
# Main worktree runs /fix-loop-coordinated
# Each worktree runs /fix
```

### With /retro

After deployment completes:

```bash
/retro

# Analyzes:
# - Git history from all merged feature branches
# - Deployment logs
# - Multi-worktree coordination efficiency
```

## Benefits

✅ **Automatic coordination** - No manual merging or deployment triggers
✅ **Parallel efficiency** - Multiple agents work simultaneously
✅ **Safe deployment** - Only deploys when ALL work complete
✅ **Audit trail** - Deployment logs and HISTORY.md entries
✅ **Continuous operation** - Fix loop continues after deployment
✅ **Built on fix-loop** - Inherits all stability and idle detection

## Example Timeline

```
00:00 - Main worktree: /fix-loop-coordinated starts
00:01 - Creates tasks 1, 2, 3 (work) and 4 (deploy, blocked by 1,2,3)
00:02 - Worktree 1 claims task 1, starts feature/auth work
00:03 - Worktree 2 claims task 2, starts feature/api work
00:15 - Worktree 1 pushes feature/auth, marks task 1 complete
00:20 - Worktree 2 pushes feature/api, marks task 2 complete
00:21 - Main worktree detects task 4 unblocked (all work done)
00:22 - Pulls feature/auth and feature/api
00:23 - Merges both branches to main
00:24 - Executes scripts/deploy-staging.sh
00:25 - Deployment complete, marks task 4 complete
00:26 - Fix loop continues, looks for new GitHub issues
```

## See Also

- `/fix-loop` - Standard infinite fix loop (single worktree)
- `/fix` - Single-shot fix command
- `superpowers:dispatching-parallel-agents` - Agent coordination skill
- `docs/git-worktrees.md` - Git worktree best practices
