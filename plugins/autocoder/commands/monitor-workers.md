# Monitor Workers

Monitor worker agents in worktrees, detect stale work, assign unblocked issues to idle workers via cmux/tmux, and deploy when all work is complete.

**This command is designed for the manager session** — run it in the main project directory (not a worktree) alongside `/review-blocked`.

## Usage

```bash
# One-shot status check
/monitor-workers

# Continuous monitoring until all work complete
/monitor-workers --watch
```

## What This Does

1. **Check worktree status** — For each worker worktree, report branch, last commit time, and whether actively working
2. **Read worker screens** — Use cmux/tmux to check if agents are idle or active
3. **Detect stale "working" labels** — Find issues tagged "working" with no agent activity in the last hour; ask to remove
4. **Find unblocked issues** — List open issues without blocking labels
5. **Dispatch idle workers** — Send `/autocoder:fix <issue_number>` to idle workers via cmux/tmux
6. **Review blocked issues** — When all open issues are blocked and workers are idle, automatically run `/review-blocked` to surface issues for human review
7. **Deploy when ready** — When all workers complete all unblocked issues and integration has new commits, deploy

## Instructions

### Step 1: Discover Workers

```bash
# Find worktrees
git worktree list

# Find cmux workspaces (if cmux available)
cmux tree --all 2>/dev/null

# Find tmux sessions (if tmux available)
tmux list-sessions 2>/dev/null
tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}' 2>/dev/null
```

Map each worktree directory to its cmux workspace or tmux pane. Naming conventions:
- **cmux**: Workspaces named `claude-<project>-worker-N` or `wt<N>-<project>`
- **tmux**: Session named `claude-<project>`, workers in window 0 panes

### Step 2: Gather Status

For each worktree:

```bash
for wt_dir in $(git worktree list --porcelain | grep "^worktree " | sed 's/^worktree //' | grep -v "$(pwd)$"); do
  name=$(basename "$wt_dir")
  branch=$(cd "$wt_dir" && git branch --show-current)
  last_commit=$(cd "$wt_dir" && git log --oneline -1)
  last_time=$(cd "$wt_dir" && git log -1 --format=%cr)
  last_epoch=$(cd "$wt_dir" && git log -1 --format=%ct)
  now_epoch=$(date +%s)
  age_min=$(( (now_epoch - last_epoch) / 60 ))
  dirty=$(cd "$wt_dir" && git status --short | wc -l | tr -d ' ')

  echo "$name | branch=$branch | dirty=$dirty | last=$last_time ($age_min min ago)"
  echo "  $last_commit"
done
```

Also check GitHub state:

```bash
# Open unblocked issues
gh issue list --state open --json number,title,labels --jq '.[] | select(.labels | map(.name) | (contains(["needs-design"]) or contains(["needs-clarification"]) or contains(["future"]) or contains(["proposal"]) or contains(["needs-approval"]) or contains(["too-complex"])) | not) | "#\(.number): \(.title)"'

# Issues currently being worked
gh issue list --state open --label "working" --json number,title --jq '.[] | "#\(.number): \(.title)"'
```

### Step 3: Read Worker Screens

Use cmux or tmux to check if workers are truly idle:

**cmux:**
```bash
cmux read-screen --workspace <ref> --lines 15
```

**tmux:**
```bash
tmux capture-pane -t <session>:<window>.<pane> -p | tail -15
```

Look for these idle indicators:
- `IDLE_NO_WORK_AVAILABLE`
- Bare prompt `❯` with no active tool calls
- `Brewed for Xm` (completed work, waiting)

### Step 4: Detect Stale "working" Labels

For each issue with the "working" label, check if work is actually happening:

1. **Check worktree match**: Is there a worktree with a branch containing the issue number? If so, has it had commits in the last 60 minutes?
2. **Check screen**: Can you find an agent actively working on this issue via cmux/tmux screen?
3. **Check issue timestamps**: Is the issue's most recent comment/update older than 60 minutes?

**A "working" label is stale if ALL of these are true:**
- No worktree has committed changes for this issue in the last 60 minutes
- No agent screen shows active work on this issue
- The issue's most recent update is older than 60 minutes

**When a stale "working" label is detected**, use AskUserQuestion to ask:
> "Issue #N has the 'working' label but no agent appears to be actively working on it (no commits or file changes in the last hour). Remove the 'working' label so it can be picked up by another worker?"

If approved:
```bash
gh issue edit <number> --remove-label "working"
```

### Step 5: Dispatch Work to Idle Workers

Find unblocked issues not being worked (no "working" label), sorted by priority:

```bash
gh issue list --state open --json number,title,labels --jq '[.[] | select(.labels | map(.name) | (contains(["needs-design"]) or contains(["needs-clarification"]) or contains(["future"]) or contains(["proposal"]) or contains(["needs-approval"]) or contains(["too-complex"]) or contains(["working"])) | not)] | sort_by(.labels | map(select(.name | test("^P[0-3]$"))) | .[0].name // "P9") | .[].number'
```

For each idle worker with an unworked issue available, send the fix command:

**cmux:**
```bash
cmux send --workspace <ref> "/autocoder:fix <issue_number>"
cmux send-key --workspace <ref> Enter
```

**tmux:**
```bash
tmux send-keys -t <session>:<window>.<pane> "/autocoder:fix <issue_number>" Enter
```

After dispatching, verify the worker started by reading its screen again after a few seconds.

### Step 5b: Run Review-Blocked When All Issues Are Blocked

If there are **no unblocked issues available** for workers (all open issues have blocking labels like needs-design, needs-clarification, too-complex, etc.) AND there are **blocked issues that need review**, automatically invoke `/autocoder:review-blocked` using the Skill tool.

This lets the human manager approve, reject, or skip blocked issues — potentially unblocking work for idle workers on the next monitoring cycle.

**Conditions to trigger review-blocked:**
- Zero unblocked issues available (no work for workers to pick up)
- At least one blocked issue exists (something to review)
- Workers are idle (not actively working on anything)

**Do NOT trigger review-blocked if:**
- There are unblocked issues available (workers have work to do)
- Workers are actively working (let them finish — new issues may appear)

When triggered, use the Skill tool:
```
Use the Skill tool to invoke: autocoder:review-blocked
```

### Step 6: Check Deploy Readiness

All conditions must be true:
1. No issues with "working" label (all work complete)
2. No open unblocked issues remaining
3. Integration branch has commits newer than the last deploy

```bash
# Check integration branch for new commits
git fetch origin --quiet
git log origin/integration --oneline -5
```

If ready, deploy:
```bash
./deploy.sh ey-staging
```

### Step 7: Write Structured Status (for agents-tui)

If `/tmp/agents-ui/` exists (indicating agents-tui is running), write a JSON summary file so the TUI can update its display without polling GitHub:

```bash
if [ -d /tmp/agents-ui ]; then
  SESSION_NAME=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "unknown")

  # Build JSON with worker statuses — use the data gathered in Steps 2-5
  # Each worker entry should include pane, status, issue number, and title
  # Example:
  cat > "/tmp/agents-ui/${SESSION_NAME}-monitor.json" << MONITOR_EOF
  {
    "timestamp": "$(date -Iseconds)",
    "session": "${SESSION_NAME}",
    "workers": [WORKER_ENTRIES_HERE],
    "open_issues": OPEN_COUNT,
    "working_issues": WORKING_COUNT,
    "blocked_issues": BLOCKED_COUNT,
    "idle_workers": IDLE_COUNT,
    "actions": [ACTIONS_LIST_HERE]
  }
  MONITOR_EOF
fi
```

Construct the `workers` array from the status gathered in Steps 2-3. Each entry:
```json
{"pane": "claude-agents-ui:2.0", "worktree": "wt-2", "status": "working", "issue": 100, "title": "Issue detail view"}
```

Also update individual worker status files for each worker discovered:
```bash
if [ -d /tmp/agents-ui ]; then
  # For each worker, write/update its status file
  # This ensures the TUI sees fresh data even between monitor-workers runs
  for each worker pane:
    echo "{\"status\": \"${WORKER_STATUS}\", \"issue\": ${ISSUE_NUM:-null}, \"title\": \"${ISSUE_TITLE:-}\"}" > "/tmp/agents-ui/${PANE_ID}.json"
  done
fi
```

### Step 8: Report Summary

Present a clear summary table:

```markdown
| Worker | Status | Branch/Issue | Last Activity |
|--------|--------|--------------|---------------|
| wt-1   | idle   | fix/issue-X  | 2 hours ago   |
| wt-2   | active | fix/issue-Y  | 5 min ago     |
| wt-3   | idle   | fix/issue-Z  | 1 hour ago    |

Open unblocked issues: N
Currently being worked: M
Idle workers available: K
Stale "working" labels: S

Actions taken:
- Sent `/autocoder:fix 1234` to wt-1
- Sent `/autocoder:fix 5678` to wt-3
- Removed stale "working" label from #9999

Deploy status: 21 commits since last deploy, waiting for workers to complete
```

## Continuous Monitoring Mode (`--watch`)

When `--watch` is passed, poll every 3 minutes until all work is done:

```bash
for i in $(seq 1 60); do
  sleep 180

  git fetch origin --quiet 2>/dev/null
  WORKING=$(gh issue list --state open --label "working" --json number --jq 'length')
  UNBLOCKED=$(gh issue list --state open --json number,labels --jq '[.[] | select(.labels | map(.name) | (contains(["needs-design"]) or contains(["needs-clarification"]) or contains(["future"]) or contains(["proposal"]) or contains(["needs-approval"]) or contains(["too-complex"])) | not)] | length')
  INT_HEAD=$(git rev-parse --short origin/integration)

  echo "[$(date +%H:%M:%S)] working=$WORKING unblocked=$UNBLOCKED integration=$INT_HEAD"

  # Check for stale working labels and idle workers on each iteration
  # (repeat Steps 3-5)

  # All done? Deploy.
  if [ "$WORKING" -eq 0 ] && [ "$UNBLOCKED" -eq 0 ]; then
    echo "All work complete. Deploying..."
    break
  fi
done
```

## Key Principles

- **Use cmux/tmux to dispatch** — Send commands directly to idle workers, don't just report
- **Detect stale locks** — Ask before removing "working" labels that appear abandoned
- **Priority order** — Assign highest priority issues first (P0 > P1 > P2 > P3)
- **Don't double-assign** — Check "working" label before dispatching
- **Deploy only when ready** — All workers idle + no unblocked issues + new commits
- **Deploy to staging only** — Never deploy to production without explicit user request
