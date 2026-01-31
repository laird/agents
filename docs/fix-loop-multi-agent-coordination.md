# Multi-Agent Coordination with /fix-loop

Automatic coordination for parallel Claude Code agents across git worktrees with zero manual setup.

## Quick Start

```bash
# 1. Set shared task list ID (same in all worktrees)
export CLAUDE_CODE_TASK_LIST_ID="project-$(date +%Y%m%d)"

# 2. Run /fix-loop in each worktree (same command everywhere)
/fix-loop

# That's it! Automatic deployment when all agents idle and work pushed.
```

## How It Works

### Detection

When `/fix-loop` detects `CLAUDE_CODE_TASK_LIST_ID` is set, it automatically:

1. **Identifies role** - Main worktree = coordinator, feature worktrees = workers
2. **Monitors shared task list** - Sees what all agents are doing
3. **Waits for all idle** - All agents complete their work
4. **Checks integration ready** - All changes pushed to integration branch
5. **Deploys (once)** - Main worktree executes deployment script
6. **Continues loop** - All agents resume looking for work

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Main Worktree (Coordinator)                            │
│  ┌──────────────────────────────────────────────────┐  │
│  │ /fix-loop                                        │  │
│  │ - Works on issues                                │  │
│  │ - Monitors: Are all agents idle?                 │  │
│  │ - Checks: Is integration branch clean & pushed?  │  │
│  │ - Deploys: When all conditions met              │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
                         │
                         │ Shared Task List
                         │ (CLAUDE_CODE_TASK_LIST_ID)
                         │
         ┌───────────────┴────────────────┐
         │                                │
┌────────▼──────────┐          ┌─────────▼─────────┐
│ Feature Worktree 1│          │ Feature Worktree 2│
│ ┌────────────────┐│          │ ┌────────────────┐│
│ │ /fix-loop      ││          │ │ /fix-loop      ││
│ │ - Works on     ││          │ │ - Works on     ││
│ │   tasks        ││          │ │   tasks        ││
│ │ - Pushes       ││          │ │ - Pushes       ││
│ │   changes      ││          │ │   changes      ││
│ └────────────────┘│          │ └────────────────┘│
└───────────────────┘          └───────────────────┘
```

## Setup

### 1. Create Worktrees

```bash
# Create feature worktrees
git worktree add ../project-wt-auth feature/auth
git worktree add ../project-wt-api feature/api
git worktree add ../project-wt-ui feature/ui
```

### 2. Set Shared Task List ID

**Option A: Environment variable (manual)**
```bash
# In each worktree session
export CLAUDE_CODE_TASK_LIST_ID="myproject-2026-01-30"
```

**Option B: .envrc (automatic with direnv)**
```bash
# In project root (main worktree)
echo 'export CLAUDE_CODE_TASK_LIST_ID="myproject-'$(date +%Y%m%d)'"' > .envrc
direnv allow

# Each worktree inherits this automatically
```

**Option C: Shell rc file (persistent)**
```bash
# Add to ~/.bashrc or ~/.zshrc
echo 'export CLAUDE_CODE_TASK_LIST_ID="myproject-persistent"' >> ~/.bashrc
source ~/.bashrc
```

### 3. Configure Deployment

**Option A: Document in CLAUDE.md (Recommended)**

Add to your project's `CLAUDE.md`:

```markdown
## Deployment

Integration branch: main
Deploy to staging: deploy.sh staging .
```

**Option B: Environment variables**

```bash
export CLAUDE_CODE_INTEGRATION_BRANCH="main"
export CLAUDE_CODE_DEPLOY_COMMAND="deploy.sh staging ."
```

**Option C: Command line arguments**

```bash
/fix-loop --branch main --deploy "deploy.sh staging ."
```

**Option D: Create standard deployment script**

```bash
cat > scripts/deploy-staging.sh << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Deploying to staging..."

# Add your deployment logic here:
# - Run tests
# - Build artifacts
# - Deploy to staging environment

echo "Deployment complete!"
EOF

chmod +x scripts/deploy-staging.sh
```

### 4. Start Fix Loops

```bash
# Main worktree
cd /path/to/project
/fix-loop
# Output: 🔄 iteration 1 | 🔗 Coordinator (will deploy when all idle)

# Feature worktree 1
cd /path/to/project-wt-auth
/fix-loop
# Output: 🔄 iteration 1 | 🔗 Worker (myproject-20...)

# Feature worktree 2
cd /path/to/project-wt-api
/fix-loop
# Output: 🔄 iteration 1 | 🔗 Worker (myproject-20...)
```

## Deployment Conditions

Deployment happens automatically when ALL these are true:

1. **All agents idle**
   - No pending tasks in shared task list
   - No in_progress tasks
   - All agents waiting for work

2. **Integration branch ready**
   - Working tree clean (no uncommitted changes)
   - All commits pushed to remote
   - No unpushed work

3. **Main worktree**
   - Current session is in main worktree (not feature worktree)
   - Detected by presence of `.git/` directory

4. **New changes to deploy**
   - Current commit hasn't been deployed yet
   - Prevents deploying same code twice

## Deployment Process

When conditions met, main worktree:

```
1. 🔗 Coordination mode: Shared task list detected
2.    ✅ All agents idle
3.    ✅ Integration branch ready
4.    ✅ Main worktree (deployer role)
5. 🚀 Deploying to staging...
6.    >>> Switching to main
7.    >>> Committing changes in main worktree
8.    >>> Pushing main
9.    >>> Pulling latest main
10.   >>> Feature branches to merge: feature/auth feature/api
11.   >>> Fetching feature/auth
12.   >>> Merging feature/auth into main
13.   >>> Fetching feature/api
14.   >>> Merging feature/api into main
15.   >>> Pushing main
16.   >>> Executing deployment: deploy.sh staging .
17. ✅ Deployment completed - log: .claude/deployment-20260130-143022.log
18. 🔄 Fix-github iteration continues...
```

Worker worktrees see:

```
1. 🔗 Coordination mode: Shared task list detected
2.    ✅ All agents idle
3.    ✅ Integration branch ready
4.    📍 Feature worktree (worker role) - skipping deployment
5.       Main worktree will handle deployment
6. 🔄 Fix-github iteration continues...
```

## Deployment Logs

Every deployment creates a log file:

```bash
# View latest deployment
ls -lt .claude/deployment-*.log | head -1 | xargs cat

# Example log:
=== Deployment Started: 2026-01-30T14:30:22-08:00 ===
Triggered by: Multi-agent idle detection
Task list: myproject-20260130

>>> Executing scripts/deploy-staging.sh
Deploying to staging...
Running tests...
✅ All tests passed
Building artifacts...
✅ Build complete
Deploying to staging environment...
✅ Deployment successful

=== Deployment Complete: 2026-01-30T14:31:05-08:00 ===
```

If `scripts/append-to-history.sh` exists, deployment is also logged to `HISTORY.md`.

## Example Timeline

```
00:00 - All worktrees: Start /fix-loop with shared task list
00:01 - Main worktree: Claims GitHub issue #123, starts work
00:02 - Worktree-auth: Claims GitHub issue #124, starts work
00:03 - Worktree-api: Claims GitHub issue #125, starts work

00:15 - Main worktree: Completes work, pushes to main, goes idle
00:18 - Worktree-auth: Completes work, pushes feature/auth, goes idle
00:20 - Worktree-api: Completes work, pushes feature/api, goes idle

00:21 - Main worktree: Detects all idle + integration ready
00:21 - Main worktree: Executes deployment script
00:22 - Main worktree: Deployment complete, resumes loop
00:22 - All worktrees: Continue fix loops (looking for new work)
```

## Troubleshooting

### Deployment not triggering

**Check all conditions:**

```bash
# 1. Is task list ID set?
echo $CLAUDE_CODE_TASK_LIST_ID
# Should output: myproject-20260130

# 2. Are all agents idle?
grep -r '"status":"pending"\|"status":"in_progress"' .claude/tasks/*.json
# Should output nothing (all complete or no tasks)

# 3. Is working tree clean?
git status
# Should show: "nothing to commit, working tree clean"

# 4. Are all commits pushed?
git log @{u}..
# Should output nothing (all pushed)

# 5. Am I in main worktree?
[[ -d .git ]] && echo "Main worktree" || echo "Feature worktree"
# Should output: Main worktree (for coordinator)

# 6. Check if current commit already deployed
CURRENT_SHA=$(git rev-parse HEAD)
[[ -f ".git/agent-coordination/deployed-$CURRENT_SHA" ]] && echo "Already deployed" || echo "Not deployed yet"
# Should output: "Not deployed yet"
```

### Different task lists in different worktrees

```bash
# Verify same ID everywhere
# Main worktree:
cd /path/to/project
echo $CLAUDE_CODE_TASK_LIST_ID

# Feature worktree 1:
cd /path/to/project-wt-auth
echo $CLAUDE_CODE_TASK_LIST_ID

# Feature worktree 2:
cd /path/to/project-wt-api
echo $CLAUDE_CODE_TASK_LIST_ID

# All should match! If not, set explicitly:
export CLAUDE_CODE_TASK_LIST_ID="myproject-20260130"
```

### Deployment script not found

```bash
# Create deployment script
cat > scripts/deploy-staging.sh << 'EOF'
#!/bin/bash
set -euo pipefail
echo "Deploying to staging..."
# Add your deployment commands here
echo "Done!"
EOF

chmod +x scripts/deploy-staging.sh
```

### Worker worktree trying to deploy

This shouldn't happen, but if it does:

```bash
# Check if .git is a directory (main) or file (worker)
ls -la .git

# Main worktree: drwxr-xr-x ... .git/
# Feature worktree: -rw-r--r-- ... .git

# If worker has .git directory, something is wrong with worktree setup
git worktree list
```

## Stopping Coordination

### Stop All Loops

```bash
# In each worktree, either:
# - Press Ctrl+C
# - Delete state file: rm .claude/fix-loop.local.md
# - Output: STOP_FIX_GITHUB_LOOP
```

### Disable Coordination (Keep Loop)

```bash
# Unset task list ID
unset CLAUDE_CODE_TASK_LIST_ID

# Loop continues but without coordination/deployment
# Each agent works independently
```

## Advanced Usage

### Custom Idle Sleep Time

```bash
# Sleep 30 minutes when idle (default: 15)
/fix-loop --sleep 30
```

### Max Iterations

```bash
# Stop after 100 iterations
/fix-loop 100
```

### Multiple Environments

Use different deployment scripts for different branches:

```bash
# Main worktree on main branch → staging
scripts/deploy-staging.sh

# Main worktree on release branch → production
scripts/deploy-production.sh

# Hook automatically finds and executes correct script
```

### Manual Deployment Lock

Prevent automatic deployment temporarily:

```bash
# Create fake recent deployment
mkdir -p .git/agent-coordination
touch .git/agent-coordination/deployed-$(date +%Y%m%d-%H%M%S)

# Remove when ready to deploy
rm .git/agent-coordination/deployed-*
```

## Benefits

✅ **Zero configuration** - Just set `CLAUDE_CODE_TASK_LIST_ID` and run `/fix-loop`
✅ **Automatic role detection** - Main vs worker determined by worktree location
✅ **Safe deployment** - Only when all work complete and pushed
✅ **Same command everywhere** - No special coordinator vs worker commands
✅ **Audit trail** - Deployment logs and HISTORY.md entries
✅ **Graceful degradation** - Works as regular `/fix-loop` if task list ID not set
✅ **Built on fix-loop** - Inherits all stability and idle detection features

## See Also

- `/fix-loop` - Main command documentation
- `/fix` - Single-shot fix command
- `docs/git-worktrees.md` - Git worktree best practices
- `scripts/deploy-staging-template.sh` - Deployment script template
