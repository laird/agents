# Testing Multi-Agent Coordination for /fix-loop

Complete test plan for validating automatic multi-agent coordination across git worktrees.

## Prerequisites

### 1. Install Plugin from parallel Branch

```bash
/install https://github.com/laird/agents#parallel:.claude-plugin/plugins/autocoder
```

Verify installation:
```bash
/plugins
# Should show: autocoder v3.2.0
```

### 2. Prepare Test Project

You need a project with:
- Git repository
- GitHub remote configured
- A deployment script or command

**Quick Setup:**

```bash
# Create test project
mkdir -p ~/test-multi-agent
cd ~/test-multi-agent
git init
git remote add origin https://github.com/YOUR_USERNAME/test-multi-agent.git

# Create initial files
echo "# Test Project" > README.md
git add README.md
git commit -m "Initial commit"
git push -u origin main

# Create deployment script
cat > deploy.sh << 'EOF'
#!/bin/bash
echo "=== Deploying to staging ==="
echo "Timestamp: $(date)"
echo "Branch: $(git branch --show-current)"
echo "Commit: $(git rev-parse --short HEAD)"
echo "Deployment successful!"
EOF
chmod +x deploy.sh

git add deploy.sh
git commit -m "Add deployment script"
git push
```

### 3. Configure Project

Create `CLAUDE.md`:

```bash
cat > CLAUDE.md << 'EOF'
# Test Multi-Agent Coordination

This project tests automatic multi-agent coordination for Claude Code.

## Deployment

Integration branch: main
Deploy to staging: ./deploy.sh staging .
EOF

git add CLAUDE.md
git commit -m "Add CLAUDE.md configuration"
git push
```

## Test Scenarios

### Test 1: Basic Two-Agent Coordination

**Goal:** Verify two agents coordinate deployment after completing work.

**Setup:**

```bash
cd ~/test-multi-agent

# Set shared task list ID
export CLAUDE_CODE_TASK_LIST_ID="test-two-agents-$(date +%Y%m%d-%H%M%S)"

# Create feature worktree 1
git worktree add ../test-multi-agent-wt1 -b feature/test-1

# Create feature worktree 2
git worktree add ../test-multi-agent-wt2 -b feature/test-2
```

**Execution:**

1. **Main Worktree (Terminal 1):**
   ```bash
   cd ~/test-multi-agent
   export CLAUDE_CODE_TASK_LIST_ID="test-two-agents-20260130"
   claude

   # In Claude Code:
   /fix-loop
   ```

2. **Worktree 1 (Terminal 2):**
   ```bash
   cd ~/test-multi-agent-wt1
   export CLAUDE_CODE_TASK_LIST_ID="test-two-agents-20260130"
   claude

   # In Claude Code, make a change:
   > echo "Feature 1 implementation" >> feature1.txt
   > git add feature1.txt
   > git commit -m "feat: Add feature 1"
   > git push origin feature/test-1
   >
   > # Signal you're done by outputting:
   > "Work complete, going idle"
   ```

3. **Worktree 2 (Terminal 3):**
   ```bash
   cd ~/test-multi-agent-wt2
   export CLAUDE_CODE_TASK_LIST_ID="test-two-agents-20260130"
   claude

   # In Claude Code, make a change:
   > echo "Feature 2 implementation" >> feature2.txt
   > git add feature2.txt
   > git commit -m "feat: Add feature 2"
   > git push origin feature/test-2
   >
   > # Signal you're done:
   > "Work complete, going idle"
   ```

**Expected Behavior:**

Watch Terminal 1 (main worktree). Within ~5 minutes of both worktrees going idle:

```
✅ Fix-github loop: Idle detected, continuing...
🔗 Coordination mode: Shared task list detected (test-two-agents-20260130)
   ✅ All agents idle
   ✅ Integration branch ready
   ✅ Main worktree (deployer role)
🚀 Deploying to staging...
>>> Switching to main
>>> Committing changes in main worktree
>>> Pushing main
>>> Pulling latest main
>>> Feature branches to merge: feature/test-1 feature/test-2
>>> Fetching feature/test-1
>>> Merging feature/test-1 into main
>>> Fetching feature/test-2
>>> Merging feature/test-2 into main
>>> Pushing main
>>> Executing deployment: ./deploy.sh staging .
=== Deploying to staging ===
Timestamp: 2026-01-30T14:30:22-08:00
Branch: main
Commit: abc1234
Deployment successful!
✅ Deployment completed - log: .claude/deployment-20260130-143022.log
```

**Validation:**

```bash
# Check main branch has both features merged
cd ~/test-multi-agent
git log --oneline -5
# Should show:
# abc1234 chore: merge feature/test-2 for deployment
# def5678 chore: merge feature/test-1 for deployment
# ...

# Verify both feature files exist
ls -la feature*.txt
# Should show:
# feature1.txt
# feature2.txt

# Check deployment log
cat .claude/deployment-*.log
# Should contain deployment output

# Verify deployment marker exists
CURRENT_SHA=$(git rev-parse HEAD)
ls -la .git/agent-coordination/deployed-$CURRENT_SHA
# Should exist
```

### Test 2: Three-Agent Coordination

**Goal:** Verify coordination works with more than 2 agents.

**Setup:**

```bash
cd ~/test-multi-agent

# Clean up from Test 1
git worktree remove ../test-multi-agent-wt1 --force
git worktree remove ../test-multi-agent-wt2 --force
git branch -D feature/test-1 feature/test-2

# Create three worktrees
export CLAUDE_CODE_TASK_LIST_ID="test-three-agents-$(date +%Y%m%d-%H%M%S)"

git worktree add ../test-multi-agent-auth -b feature/auth
git worktree add ../test-multi-agent-api -b feature/api
git worktree add ../test-multi-agent-ui -b feature/ui
```

**Execution:**

Run `/fix-loop` in main worktree, then simulate work in each feature worktree:

```bash
# Worktree 1: Auth
cd ../test-multi-agent-auth
echo "Auth module" >> auth.js
git add auth.js
git commit -m "feat: Add authentication"
git push origin feature/auth

# Worktree 2: API
cd ../test-multi-agent-api
echo "API layer" >> api.js
git add api.js
git commit -m "feat: Add API endpoints"
git push origin feature/api

# Worktree 3: UI
cd ../test-multi-agent-ui
echo "UI components" >> ui.js
git add ui.js
git commit -m "feat: Add UI components"
git push origin feature/ui
```

**Expected:** Main worktree detects all 3 idle, merges all 3 branches, deploys once.

**Validation:**

```bash
cd ~/test-multi-agent
git log --oneline -5
# Should show 3 merge commits

ls -la *.js
# Should show auth.js, api.js, ui.js
```

### Test 3: Deployment Already Done (Idempotency)

**Goal:** Verify deployment doesn't re-run for same commit.

**Setup:**

Use the state from Test 1 or Test 2 (after deployment has run).

**Execution:**

1. Keep main worktree `/fix-loop` running
2. Don't make any changes
3. Wait for another idle cycle (~5 minutes)

**Expected Behavior:**

```
🔗 Coordination mode: Shared task list detected
   ✅ All agents idle
   ✅ Integration branch ready
   ✅ Main worktree (deployer role)
   ⏭️  Skipping deployment (current commit already deployed)
```

**Validation:**

```bash
# Should only be one deployment log for this commit
CURRENT_SHA=$(git rev-parse HEAD)
ls -la .git/agent-coordination/deployed-$CURRENT_SHA
# Should exist (created earlier)

# Should not create a new deployment log
ls -lt .claude/deployment-*.log | head -1
# Timestamp should be from previous deployment, not new
```

### Test 4: Worker Worktree Behavior

**Goal:** Verify worker worktrees don't attempt deployment.

**Setup:**

Use existing worktree setup from Test 2.

**Execution:**

1. Stop `/fix-loop` in main worktree (Ctrl+C)
2. Start `/fix-loop` in a feature worktree:
   ```bash
   cd ~/test-multi-agent-auth
   export CLAUDE_CODE_TASK_LIST_ID="test-three-agents-20260130"
   claude
   /fix-loop
   ```

**Expected Behavior:**

When all agents idle:

```
🔗 Coordination mode: Shared task list detected (test-three-agents-20260130)
   ✅ All agents idle
   ✅ Integration branch ready
   📍 Feature worktree (worker role) - skipping deployment
      Main worktree will handle deployment
🔄 Fix-github iteration continues...
```

**Validation:**

- Feature worktree should NOT attempt to merge or deploy
- Should continue its fix-loop normally
- Should see "worker role" in system message

### Test 5: Configuration from CLAUDE.md

**Goal:** Verify deployment config is read from CLAUDE.md.

**Setup:**

```bash
cd ~/test-multi-agent

# Update CLAUDE.md with different deployment command
cat > CLAUDE.md << 'EOF'
# Test Configuration

## Deployment

Integration branch: main
Deploy to staging: echo "Custom deployment from CLAUDE.md" && ./deploy.sh staging .
EOF

git add CLAUDE.md
git commit -m "Update deployment config"
git push
```

**Execution:**

1. Restart `/fix-loop` in main worktree (Ctrl+C, then `/fix-loop` again)
2. Make a change in a feature worktree
3. Push and wait for deployment

**Expected Behavior:**

Deployment output should include:
```
>>> Executing deployment: echo "Custom deployment from CLAUDE.md" && ./deploy.sh staging .
Custom deployment from CLAUDE.md
=== Deploying to staging ===
...
```

**Validation:**

```bash
# Check deployment log contains custom message
grep "Custom deployment from CLAUDE.md" .claude/deployment-*.log
# Should find the message
```

### Test 6: Environment Variable Override

**Goal:** Verify env vars override CLAUDE.md config.

**Setup:**

```bash
cd ~/test-multi-agent

export CLAUDE_CODE_INTEGRATION_BRANCH="main"
export CLAUDE_CODE_DEPLOY_COMMAND="echo 'Deployed via environment variable'"
```

**Execution:**

1. Start `/fix-loop` with env vars set
2. Make change, push, trigger deployment

**Expected Behavior:**

```
>>> Executing deployment: echo 'Deployed via environment variable'
Deployed via environment variable
```

**Validation:**

```bash
grep "Deployed via environment variable" .claude/deployment-*.log
# Should find the message
```

### Test 7: Merge Conflict Handling

**Goal:** Verify graceful handling of merge conflicts.

**Setup:**

```bash
cd ~/test-multi-agent

# Clean slate
git worktree remove ../test-multi-agent-wt1 --force 2>/dev/null || true
git worktree remove ../test-multi-agent-wt2 --force 2>/dev/null || true

export CLAUDE_CODE_TASK_LIST_ID="test-conflicts-$(date +%Y%m%d-%H%M%S)"

# Create worktrees
git worktree add ../test-multi-agent-wt1 -b feature/conflict-1
git worktree add ../test-multi-agent-wt2 -b feature/conflict-2
```

**Execution:**

1. Both worktrees modify the SAME file with different content:

   **Worktree 1:**
   ```bash
   cd ../test-multi-agent-wt1
   echo "Version from worktree 1" > shared.txt
   git add shared.txt
   git commit -m "Update shared file - version 1"
   git push origin feature/conflict-1
   ```

   **Worktree 2:**
   ```bash
   cd ../test-multi-agent-wt2
   echo "Version from worktree 2" > shared.txt
   git add shared.txt
   git commit -m "Update shared file - version 2"
   git push origin feature/conflict-2
   ```

2. Wait for main worktree to attempt deployment

**Expected Behavior:**

```
>>> Merging feature/conflict-1 into main
>>> Merging feature/conflict-2 into main
ERROR: Failed to merge feature/conflict-2
       You may need to resolve conflicts manually
⚠️ Fix-github loop: Critical error detected, pausing loop
```

**Validation:**

- Deployment should fail gracefully
- Loop should pause (not continue infinitely with error)
- Error message should be clear about which branch failed
- State file should be removed

```bash
ls -la .claude/fix-loop.local.md
# Should not exist (loop stopped)

cat .claude/deployment-*.log | tail -20
# Should show error message
```

### Test 8: No Deployment Command Configured

**Goal:** Verify behavior when deployment command is missing.

**Setup:**

```bash
cd ~/test-multi-agent

# Remove CLAUDE.md
rm CLAUDE.md
git add CLAUDE.md
git commit -m "Remove CLAUDE.md"
git push

# Remove deploy.sh
rm deploy.sh
git add deploy.sh
git commit -m "Remove deploy.sh"
git push

# Unset env vars
unset CLAUDE_CODE_DEPLOY_COMMAND
unset CLAUDE_CODE_INTEGRATION_BRANCH
```

**Execution:**

1. Start `/fix-loop`
2. Make change, push, trigger coordination

**Expected Behavior:**

```
🚀 Deploying to staging...
>>> Switching to main
>>> Pulling latest main
>>> Feature branches to merge: feature/test-1
>>> Fetching feature/test-1
>>> Merging feature/test-1 into main
>>> Pushing main
WARN: No deployment command configured

To configure deployment, use one of:
  1. Set CLAUDE_CODE_DEPLOY_COMMAND environment variable
     export CLAUDE_CODE_DEPLOY_COMMAND='deploy.sh staging .'

  2. Document in CLAUDE.md:
     ## Deployment
     Deploy to staging: deploy.sh staging .

  3. Create scripts/deploy-staging.sh

Skipping deployment execution (branches merged successfully)
✅ Deployment completed - log: .claude/deployment-20260130-143022.log
```

**Validation:**

- Branches should still be merged successfully
- Push should complete
- Deployment step should be skipped with helpful message
- Loop should continue (not crash)

## Validation Checklist

After running all tests, verify:

- [ ] Main worktree correctly identified as coordinator
- [ ] Feature worktrees correctly identified as workers
- [ ] All agents share same task list ID
- [ ] Deployment only runs from main worktree
- [ ] All feature branches get merged
- [ ] Integration branch gets pushed
- [ ] Deployment command executes successfully
- [ ] Deployment logs created
- [ ] Deployment markers prevent re-running same commit
- [ ] Merge conflicts handled gracefully
- [ ] Missing deployment config handled gracefully
- [ ] CLAUDE.md configuration parsed correctly
- [ ] Environment variables override CLAUDE.md
- [ ] Stop hook feeds /fix back to continue loop
- [ ] Idle detection works (5 minute threshold)
- [ ] No duplicate deployments

## Troubleshooting

### Issue: Deployment not triggering

**Debug steps:**

```bash
# Check task list ID
echo $CLAUDE_CODE_TASK_LIST_ID
# Should be same in all terminals

# Check if agents are idle
grep -r '"status":"pending"\|"status":"in_progress"' .claude/tasks/*.json
# Should output nothing

# Check working tree clean
git status
# Should say "nothing to commit, working tree clean"

# Check commits pushed
git log @{u}..
# Should output nothing

# Check if main worktree
[[ -d .git ]] && echo "Main" || echo "Feature"
# Should say "Main" in coordinator terminal

# Check if already deployed
CURRENT_SHA=$(git rev-parse HEAD)
ls -la .git/agent-coordination/deployed-$CURRENT_SHA
# Should not exist if deployment should run
```

### Issue: Wrong agent trying to deploy

**Check:**

```bash
# Am I in main worktree?
ls -la .git
# Main worktree: drwxr-xr-x .git/ (directory)
# Feature worktree: -rw-r--r-- .git (file)

git worktree list
# First entry is main worktree
```

### Issue: Branches not merging

**Check:**

```bash
# Are branches pushed to origin?
git ls-remote origin | grep feature
# Should list your feature branches

# Can I fetch them?
git fetch origin feature/test-1:feature/test-1
# Should succeed

# Any conflicts?
git merge-base main feature/test-1
git merge --no-commit --no-ff feature/test-1
git merge --abort
```

### Issue: Deployment command not found

**Check priority order:**

```bash
# 1. Environment variable
echo $CLAUDE_CODE_DEPLOY_COMMAND

# 2. CLAUDE.md
grep -i "deploy.*staging" CLAUDE.md

# 3. Standard scripts
ls -la scripts/deploy-staging.sh
ls -la deploy.sh
```

## Performance Testing

### Test 9: Many Agents

**Goal:** Verify coordination scales to many agents.

**Setup:**

```bash
export CLAUDE_CODE_TASK_LIST_ID="test-many-agents-$(date +%Y%m%d-%H%M%S)"

# Create 10 worktrees
for i in {1..10}; do
  git worktree add ../test-multi-agent-wt$i -b feature/test-$i
done
```

**Expected:** All 10 branches merge successfully, single deployment.

### Test 10: Rapid Changes

**Goal:** Verify deployment doesn't run multiple times during rapid changes.

**Execution:**

1. Start with all agents idle (deployment triggered)
2. Immediately make new change in feature worktree
3. Push quickly

**Expected:**
- First deployment completes
- Second deployment waits for new commit SHA
- Only deploys once per unique commit

## Clean Up

```bash
# Remove all worktrees
cd ~/test-multi-agent
git worktree list | tail -n +2 | awk '{print $1}' | xargs -I {} git worktree remove {} --force

# Remove all feature branches
git branch | grep feature/ | xargs git branch -D

# Remove test project
cd ~
rm -rf test-multi-agent test-multi-agent-*
```

## Success Criteria

The multi-agent coordination feature is working correctly if:

1. ✅ Multiple agents can share a task list and coordinate
2. ✅ Main worktree automatically becomes coordinator
3. ✅ Feature worktrees automatically become workers
4. ✅ All feature branches merge into integration branch
5. ✅ Deployment executes exactly once when all idle
6. ✅ Same commit never deploys twice
7. ✅ Configuration works via CLAUDE.md, env vars, or command line
8. ✅ Errors handled gracefully (conflicts, missing config, etc.)
9. ✅ Loop continues after deployment
10. ✅ No race conditions or duplicate deployments

## Next Steps

After successful testing:

1. Document any issues found
2. Test in real project with actual deployment
3. Monitor for edge cases in production use
4. Consider adding telemetry/logging for debugging
5. Create PR to merge `parallel` branch to `main`
