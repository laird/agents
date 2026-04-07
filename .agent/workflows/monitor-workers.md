# Monitor Workers

Monitor worker agents in worktrees, detect stale work, assign unblocked issues to idle workers via cmux/tmux, and surface blocked issues for review.

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
2. **Read worker screens** — Use cmux/tmux to check if workers are idle or active
3. **Detect stale "working" labels** — Find issues tagged `working` with no agent activity in the last hour; ask to remove
4. **Find unblocked issues** — List open issues without blocking labels
5. **Dispatch idle workers** — Send `/fix <issue_number>` to idle workers via cmux/tmux
6. **Review blocked issues** — When all open issues are blocked and workers are idle, run `/review-blocked` to surface issues for human review

## Instructions

### Step 1: Discover Workers

```bash
git worktree list
cmux tree --all 2>/dev/null
tmux list-sessions 2>/dev/null
tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}' 2>/dev/null
```

Map each worktree directory to its cmux workspace or tmux pane.

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
gh issue list --state open --json number,title,labels --jq '.[] | select(.labels | map(.name) | (contains(["needs-design"]) or contains(["needs-clarification"]) or contains(["future"]) or contains(["proposal"]) or contains(["needs-approval"]) or contains(["too-complex"])) | not) | "#\(.number): \(.title)"'

gh issue list --state open --label "working" --json number,title --jq '.[] | "#\(.number): \(.title)"'
```

### Step 3: Read Worker Screens

Use cmux or tmux to check whether workers are actually idle:

```bash
cmux read-screen --workspace <ref> --lines 15
tmux capture-pane -t <session>:<window>.<pane> -p | tail -15
```

Look for idle indicators such as `IDLE_NO_WORK_AVAILABLE`, a bare prompt, or completed-work output with no active tool usage.

### Step 4: Detect Stale `working` Labels

A `working` label is stale if all of these are true:

- No worktree has committed changes for that issue in the last 60 minutes
- No worker screen shows active work on that issue
- The issue's most recent update is older than 60 minutes

If a stale lock is detected, ask whether to remove it:

```bash
gh issue edit <number> --remove-label "working"
```

### Step 5: Dispatch Work to Idle Workers

Find unblocked issues not already being worked:

```bash
gh issue list --state open --json number,title,labels --jq '[.[] | select(.labels | map(.name) | (contains(["needs-design"]) or contains(["needs-clarification"]) or contains(["future"]) or contains(["proposal"]) or contains(["needs-approval"]) or contains(["too-complex"]) or contains(["working"])) | not)] | sort_by(.labels | map(select(.name | test("^P[0-3]$"))) | .[0].name // "P9") | .[].number'
```

Dispatch the next issue to each idle worker:

```bash
cmux send --workspace <ref> "/fix <issue_number>"
cmux send-key --workspace <ref> Enter

tmux send-keys -t <session>:<window>.<pane> "/fix <issue_number>" Enter
```

After dispatching, verify the worker started by reading its screen again after a few seconds.

### Step 6: Run Review-Blocked When All Issues Are Blocked

If there are no unblocked issues available, at least one blocked issue exists, and workers are idle, invoke `/review-blocked`.

### Step 7: Report Summary

Present a concise summary of:

- Worker status by worktree
- Open unblocked issues
- Issues currently labeled `working`
- Idle workers available
- Stale locks found
- Any actions taken this cycle

## Continuous Monitoring Mode (`--watch`)

When `--watch` is passed, repeat the monitoring cycle every 3 minutes until interrupted:

```bash
while true; do
  sleep 180
  # Repeat the monitoring steps above
done
```
