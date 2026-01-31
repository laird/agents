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
# MULTI-AGENT COORDINATION FUNCTIONS
# ============================================================

# Check if all agents sharing task list are idle
# Returns 0 if all idle, 1 if any agent has active work
check_all_agents_idle() {
    # No pending or in_progress tasks in shared task list
    [[ -d ".claude/tasks" ]] || return 0  # No tasks = idle

    if grep -q '"status":"pending"\|"status":"in_progress"' \
        .claude/tasks/*.json 2>/dev/null; then
        return 1  # Some agent still has work
    fi

    return 0  # All agents idle
}

# Check if integration branch is ready for deployment
# Returns 0 if ready, 1 if not
check_integration_ready() {
    local integration_branch="${CLAUDE_CODE_INTEGRATION_BRANCH:-main}"

    # Git working tree clean (no uncommitted changes)
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        return 1  # Uncommitted changes
    fi

    # Check if we're on the integration branch
    local current_branch=$(git branch --show-current 2>/dev/null)
    if [[ "$current_branch" != "$integration_branch" ]]; then
        # If not on integration branch, check if it exists and is up to date
        if ! git rev-parse --verify "origin/$integration_branch" &>/dev/null; then
            return 1  # Integration branch doesn't exist on remote
        fi
    fi

    # No unpushed commits on current branch
    if [[ -n "$(git log @{u}.. 2>/dev/null)" ]]; then
        return 1  # Unpushed commits
    fi

    return 0  # Integration ready
}

# Check if this is the main worktree (not a feature worktree)
# Returns 0 if main, 1 if feature worktree
is_main_worktree() {
    # Main worktree has .git as directory, feature worktrees have .git as file
    [[ -d ".git" ]] && return 0
    return 1
}

# Check if deployment already happened for this set of changes
# Returns 0 if already done, 1 if not done
deployment_already_done() {
    mkdir -p .git/agent-coordination 2>/dev/null || true

    # Get current HEAD sha
    local current_sha=$(git rev-parse HEAD 2>/dev/null)

    # Check if we already deployed this exact commit
    if [[ -f ".git/agent-coordination/deployed-$current_sha" ]]; then
        return 0  # Already deployed this commit
    fi

    return 1  # Not deployed yet
}

# Get deployment command from project configuration
get_deployment_command() {
    # Priority 1: Environment variable
    if [[ -n "${CLAUDE_CODE_DEPLOY_COMMAND:-}" ]]; then
        echo "$CLAUDE_CODE_DEPLOY_COMMAND"
        return 0
    fi

    # Priority 2: Extract from CLAUDE.md
    for claude_file in CLAUDE.md claude.md README.md; do
        if [[ -f "$claude_file" ]]; then
            # Look for deployment command patterns
            local cmd=$(grep -i "deploy.*staging\|staging.*deploy" "$claude_file" | \
                grep -Eo '(\.?/)?[a-zA-Z0-9_/-]+\.sh\s+[a-zA-Z0-9_. /-]*' | \
                head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            if [[ -n "$cmd" ]]; then
                echo "$cmd"
                return 0
            fi
        fi
    done

    # Priority 3: Look for common deployment scripts
    if [[ -f "scripts/deploy-staging.sh" ]]; then
        echo "scripts/deploy-staging.sh"
        return 0
    elif [[ -f ".agent/scripts/deploy-staging.sh" ]]; then
        echo ".agent/scripts/deploy-staging.sh"
        return 0
    elif [[ -f "deploy.sh" ]]; then
        echo "deploy.sh staging"
        return 0
    fi

    # No deployment command found
    return 1
}

# Get branches from feature worktrees that need to be merged
get_worktree_branches() {
    local integration_branch="${CLAUDE_CODE_INTEGRATION_BRANCH:-main}"
    local branches=()

    # Get all worktrees except main
    while IFS= read -r line; do
        local worktree_path=$(echo "$line" | awk '{print $1}')
        local branch=$(echo "$line" | awk '{print $3}' | tr -d '[]')

        # Skip main/master/integration branch and detached HEAD
        if [[ "$branch" != "$integration_branch" ]] && \
           [[ "$branch" != "master" ]] && \
           [[ "$branch" != "(detached" ]]; then
            branches+=("$branch")
        fi
    done < <(git worktree list | tail -n +2)  # Skip first line (main worktree)

    printf '%s\n' "${branches[@]}"
}

# Execute deployment to staging
execute_deployment() {
    local deployment_log=".claude/deployment-$(date +%Y%m%d-%H%M%S).log"
    local integration_branch="${CLAUDE_CODE_INTEGRATION_BRANCH:-main}"

    echo "🚀 Deploying to staging..." >&2

    {
        echo "=== Deployment Started: $(date -Iseconds) ==="
        echo "Triggered by: Multi-agent idle detection"
        echo "Task list: $CLAUDE_CODE_TASK_LIST_ID"
        echo "Integration branch: $integration_branch"
        echo ""

        # Step 1: Ensure we're on integration branch
        local current_branch=$(git branch --show-current)
        if [[ "$current_branch" != "$integration_branch" ]]; then
            echo ">>> Switching to $integration_branch"
            git checkout "$integration_branch" 2>&1 || {
                echo "ERROR: Failed to checkout $integration_branch"
                return 1
            }
        fi

        # Step 2: Commit any uncommitted changes in main worktree
        if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
            echo ">>> Committing changes in main worktree"
            git add -A 2>&1
            git commit -m "chore: auto-commit before deployment

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>" 2>&1 || {
                echo "ERROR: Failed to commit changes"
                return 1
            }
        fi

        # Step 3: Push integration branch (if we committed)
        if [[ -n "$(git log @{u}.. 2>/dev/null)" ]]; then
            echo ">>> Pushing $integration_branch"
            git push origin "$integration_branch" 2>&1 || {
                echo "ERROR: Failed to push $integration_branch"
                return 1
            }
        fi

        # Step 4: Pull latest integration branch
        echo ">>> Pulling latest $integration_branch"
        git pull origin "$integration_branch" 2>&1 || {
            echo "ERROR: Failed to pull $integration_branch"
            return 1
        }

        # Step 5: Get branches from worktrees
        local branches=($(get_worktree_branches))

        if [[ ${#branches[@]} -gt 0 ]]; then
            echo ""
            echo ">>> Feature branches to merge: ${branches[*]}"
            echo ""

            # Step 6: Merge each feature branch
            for branch in "${branches[@]}"; do
                echo ""
                echo ">>> Fetching $branch"
                git fetch origin "$branch:$branch" 2>&1 || {
                    echo "WARN: Failed to fetch $branch (may not be pushed yet)"
                    continue
                }

                echo ">>> Merging $branch into $integration_branch"
                git merge "$branch" --no-edit -m "chore: merge $branch for deployment

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>" 2>&1 || {
                    echo "ERROR: Failed to merge $branch"
                    echo "       You may need to resolve conflicts manually"
                    return 1
                }
            done

            # Step 7: Push merged integration branch
            echo ""
            echo ">>> Pushing $integration_branch"
            git push origin "$integration_branch" 2>&1 || {
                echo "ERROR: Failed to push $integration_branch"
                return 1
            }
        else
            echo ">>> No feature branches to merge (all work on $integration_branch)"
        fi

        # Step 8: Execute deployment command
        echo ""
        local deploy_cmd=$(get_deployment_command)

        if [[ -n "$deploy_cmd" ]]; then
            echo ">>> Executing deployment: $deploy_cmd"
            bash -c "$deploy_cmd" 2>&1
        else
            echo "WARN: No deployment command configured"
            echo ""
            echo "To configure deployment, use one of:"
            echo "  1. Set CLAUDE_CODE_DEPLOY_COMMAND environment variable"
            echo "     export CLAUDE_CODE_DEPLOY_COMMAND='deploy.sh staging .'"
            echo ""
            echo "  2. Document in CLAUDE.md:"
            echo "     ## Deployment"
            echo "     Deploy to staging: deploy.sh staging ."
            echo ""
            echo "  3. Create scripts/deploy-staging.sh"
            echo ""
            echo "Skipping deployment execution (branches merged successfully)"
        fi

        echo ""
        echo "=== Deployment Complete: $(date -Iseconds) ==="

    } | tee "$deployment_log"

    # Mark deployment as done (prevents deploying same commit twice)
    mkdir -p .git/agent-coordination
    local deployed_sha=$(git rev-parse HEAD 2>/dev/null)
    touch ".git/agent-coordination/deployed-$deployed_sha"

    # Also create timestamped log reference
    echo "$deployment_log" > ".git/agent-coordination/last-deployment"

    # Log to HISTORY.md if script exists
    local merged_branches="${branches[*]}"
    if [[ -f "scripts/append-to-history.sh" ]]; then
        bash scripts/append-to-history.sh \
            "Automated deployment to staging" \
            "Merged branches: $merged_branches into $integration_branch" \
            "Task list: $CLAUDE_CODE_TASK_LIST_ID" \
            "All agents idle, integration ready" 2>/dev/null || true
    elif [[ -f ".agent/scripts/append-to-history.sh" ]]; then
        bash .agent/scripts/append-to-history.sh \
            "Automated deployment to staging" \
            "Merged branches: $merged_branches into $integration_branch" \
            "Task list: $CLAUDE_CODE_TASK_LIST_ID" \
            "All agents idle, integration ready" 2>/dev/null || true
    fi

    echo "✅ Deployment completed - log: $deployment_log" >&2
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
INTEGRATION_BRANCH=$(echo "$FRONTMATTER" | grep '^integration_branch:' | sed 's/integration_branch: *//' || echo "main")
DEPLOY_COMMAND=$(echo "$FRONTMATTER" | grep '^deploy_command:' | sed 's/deploy_command: *//')

# Export for functions to use
export CLAUDE_CODE_INTEGRATION_BRANCH="$INTEGRATION_BRANCH"
export CLAUDE_CODE_DEPLOY_COMMAND="$DEPLOY_COMMAND"

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
# MULTI-AGENT COORDINATION - Automatic Deployment
# ============================================================

# Only coordinate if CLAUDE_CODE_TASK_LIST_ID is set (shared task list)
if [[ -n "${CLAUDE_CODE_TASK_LIST_ID:-}" ]]; then
    echo "🔗 Coordination mode: Shared task list detected ($CLAUDE_CODE_TASK_LIST_ID)" >&2

    # Check: Are all agents idle?
    if check_all_agents_idle; then
        echo "   ✅ All agents idle" >&2

        # Check: Is integration branch ready?
        if check_integration_ready; then
            echo "   ✅ Integration branch ready" >&2

            # Check: Am I the main worktree?
            if is_main_worktree; then
                echo "   ✅ Main worktree (deployer role)" >&2

                # Check: Already deployed recently?
                if deployment_already_done; then
                    echo "   ⏭️  Deployment already done (within last hour)" >&2
                else
                    # All conditions met - deploy!
                    execute_deployment

                    # Give deployment a moment before continuing loop
                    sleep 5
                fi
            else
                echo "   📍 Feature worktree (worker role) - skipping deployment" >&2
                echo "      Main worktree will handle deployment" >&2
            fi
        else
            echo "   ⏳ Integration branch not ready (uncommitted or unpushed changes)" >&2
        fi
    else
        echo "   ⏳ Other agents still have active work" >&2
    fi
fi

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
    SYSTEM_MSG="🔄 Fix-github iteration $NEXT_ITERATION/$MAX_ITERATIONS"
else
    SYSTEM_MSG="🔄 Fix-github iteration $NEXT_ITERATION (unlimited)"
fi

# Add coordination status if enabled
if [[ -n "${CLAUDE_CODE_TASK_LIST_ID:-}" ]]; then
    if is_main_worktree; then
        SYSTEM_MSG="$SYSTEM_MSG | 🔗 Coordinator (will deploy when all idle)"
    else
        SYSTEM_MSG="$SYSTEM_MSG | 🔗 Worker (${CLAUDE_CODE_TASK_LIST_ID:0:12}...)"
    fi
fi

SYSTEM_MSG="$SYSTEM_MSG | To stop: output STOP_FIX_GITHUB_LOOP or press Ctrl+C"

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
