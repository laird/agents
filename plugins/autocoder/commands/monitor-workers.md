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
4. **Restart unhealthy workers** — Detect workers that are stalled AND consuming high memory (e.g. a wedged agent that ran out of context), and restart them in place on the same worktree/issue
5. **Find unblocked issues** — List open issues without blocking labels
6. **Dispatch idle workers** — Send `/autocoder:fix <issue_number>` to idle workers via cmux/tmux
7. **Scale fleet if needed** — If the issue queue is backing up (more unblocked issues than workers) and the human asks, run `add-worker` to add a worker to the fleet
8. **Review blocked issues** — When all open issues are blocked and workers are idle, automatically run `/review-blocked` to surface issues for human review
9. **Deploy when ready** — When all workers complete all unblocked issues and integration has new commits, deploy

## Instructions

### Step 0: Context pressure check — handoff before compaction

Before doing anything else, check whether this manager session is approaching context limits. Read the manager's own tmux pane:

```bash
# The manager typically runs in window 1, pane 0 — adjust session/pane if different
SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null)
tmux capture-pane -t "${SESSION}:1.0" -p 2>/dev/null | grep -oE 'ctx [0-9]+%' | tail -1
```

`ctx NN%` comes from the status line this repo installs (`install-statusline.sh`) and always
means context **used**. Prefer it over anything in the built-in footer: that text is not a
stable contract across versions, and some of its forms report context *remaining*, so mixing
the two eventually inverts the reading. If no `ctx` segment appears, the status line is not
installed in this session — install it rather than guessing from the footer.

**If context pressure is detected** (`ctx NN%` where N ≥ 85, or an explicit "compressing
context" / "context limit" message):

1. Immediately invoke the handoff skill to save state:
   ```
   Use the Skill tool to invoke: autocoder:manager-handoff
   ```
2. After handoff completes, stop — do not proceed with the rest of monitor-workers. The user will run `/autocoder:manager-resume` in the fresh session.

**If no context pressure**: continue to Step 1.

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
# Resolve the autocoder script directory. A project-local tree only wins if it is
# a COMPLETE override — i.e. it actually contains the file we are about to source.
# Testing for the directory alone let a stale vendored .agent/ or plugins/autocoder/
# tree, left behind by an old project import, shadow the installed plugin: the
# source below then failed and every issue_* call silently used the wrong backend.
SCRIPT_DIR=$(
  for d in "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/issue-fns.sh" ]; then echo "$d"; exit 0; fi
  done
  find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
)
if [ ! -f "${SCRIPT_DIR}/issue-fns.sh" ]; then
  echo "autocoder: cannot locate issue-fns.sh (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi
source "${SCRIPT_DIR}/issue-fns.sh"

# Open unblocked issues (--state open returns only the open/ bucket;
# blocked-labeled issues live in blocked/ and are excluded by directory).
issue_list --state open | jq -r '.[] | "#\(.number): \(.title)"'

# Issues currently being worked (lives in working/ bucket)
issue_list --state working | jq -r '.[] | "#\(.number): \(.title)"'
```

### Step 3: Decide Which Workers Are Idle

Run the idle check. Do **not** eyeball a pane capture and judge for yourself —
that is how this step used to work, and it dispatched over live work:

```bash
worker-idle --all
# or a single pane, exit 0 = idle, 1 = busy:
worker-idle --pane <pane-id>
```

It samples each pane twice a few seconds apart and calls it BUSY on any change,
so a worker mid-`npm run build` — printing nothing for minutes — still reads as
busy. It marks the manager's own pane `SELF` and excludes it. Panes reported
`IDLE` with "verify before dispatch" were merely static: read those before
sending, since a worker stopped at a permission prompt looks identical.

**Never treat any of these as evidence of idleness:**

| Looks idle | Why it isn't |
|---|---|
| Bare `❯` prompt with no visible tool call | The TUI renders an empty input box at all times, including mid-turn. It says nothing about state. |
| No output in the last few lines | `tail -15` scrolls past the status line. Anchor on the status line or use the two-sample check. |
| A capture taken earlier in this iteration | Panes change by the second. Re-sample at the moment you dispatch, not before deliberating. |

The only positive idle signals are `IDLE_NO_WORK_AVAILABLE`, `Brewed for Xm`,
and "no pane change across the settle window" — which is what `worker-idle`
tests.

**Corroborate before dispatching.** A worker whose worktree has commits in the
last few minutes, or that already appears in the `working` list for the issue
you were about to assign, is not idle no matter what the pane looks like:

```bash
git -C <worktree> log -1 --format='%cr %s'
```

Two of the three panes that triggered this rule were already working the exact
PRs the manager then "assigned" them. Duplicate assignment is the loudest
symptom of a bad idle read — if the work you are about to hand out is already
in flight, your idle detection is wrong, not the worker.

If a dispatch does land on a busy worker, send a short correction to that pane
immediately ("disregard my previous message, continue what you were doing")
rather than leaving it to reconcile two conflicting instructions.

**cmux equivalent** (no two-sample helper yet — capture twice by hand):
```bash
cmux read-screen --workspace <ref> --lines 40 > /tmp/s1; sleep 4
cmux read-screen --workspace <ref> --lines 40 > /tmp/s2
diff -q /tmp/s1 /tmp/s2 >/dev/null && echo IDLE || echo BUSY
```

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
issue_release <number>
```

### Step 4b: Restart Unhealthy Workers (High Memory + Stalled)

A long-running worker can wedge — most commonly it exhausts its context window
and stops making progress while still holding a large resident memory footprint.
The manager detects this and restarts the worker **in place**: it kills the
wedged agent process and relaunches a fresh agent in the **same worktree** on the
**same branch**, so the worker resumes its assigned issue via the existing
"working" label. Committed progress is preserved; only uncommitted in-memory
state (already lost on a hung process) is discarded.

Run the health report (read-only). It measures each worker's resident memory by
matching processes whose working directory is the worktree — that cwd is the
shared key across both tmux and cmux, so it works regardless of multiplexer:

```bash
worker-health
# or, to tune thresholds:
worker-health --mem-threshold-mb 6000 --stall-min 60
```

A worker is flagged **UNHEALTHY** only when **BOTH** are true (conservative — a
busy-but-large worker or an idle-but-lean worker is left alone):
- **Stalled**: no commits for `--stall-min` minutes (default 60), and its screen
  shows no active work (reuse the Step 3 screen read to confirm)
- **High memory**: agent RSS at/above `--mem-threshold-mb` (default 6000 MB)

When memory cannot be measured (RSS shown as `?`), the worker is **never**
auto-restarted — surface it for manual review instead.

For each worker the report flags `UNHEALTHY`, confirm it is genuinely wedged
(re-read its screen), then restart it in place:

```bash
restart-worker --worktree <worktree_path>
# with explicit options:
restart-worker --worktree <worktree_path> --mux cmux --agent codex
```

`restart-worker` finds the worker's pane/workspace by its worktree path,
kills the hung process (`tmux respawn-pane -k` / `cmux close-workspace`), and
relaunches the agent's fix-loop in the same worktree. After restarting, re-read
the worker's screen after a few seconds to confirm it came back up.

**When to restart automatically vs. ask:** during `--watch`, restart `UNHEALTHY`
workers automatically (they are both wedged and bloated, so there is no progress
to lose). For one-shot runs, prefer confirming with the human first via
AskUserQuestion unless they have asked you to keep the fleet healthy unattended.

### Step 4c: Hand off workers approaching the context limit (≥95%)

**Every tick, read each worker's context percentage off its status line and hand off any
worker at ≥95% context — do NOT let it keep working up to 100% and wedge.** This is distinct from Step 4b
(which restarts a worker that is *already* wedged): Step 4c is **proactive**, triggered by
context %, and it **preserves** the worker's in-flight task via a handoff rather than
discarding uncommitted work.

Read each worker's context percentage from its pane. The swarm installs a status line
(`install-statusline.sh`, wired into every launch path) that renders one line per pane:

```
ctx 47% of 1M | mem 12 | Sonnet 5 | wt athena2-wt-3 | branch feature/issue-264
```

That line is the intended read for this step — it also tells you, in the same glance, which
worktree and branch the pane is actually on, which is how you catch two workers that have
drifted onto the same branch.

```bash
# per worker pane -- the status line is the ONLY reliable source
tmux capture-pane -t <session>:<window>.<pane> -p | grep -oE 'ctx [0-9]+%' | tail -1
```

**Do not fall back to the built-in footer.** The footer's context text is not a stable
contract: it varies across Claude Code versions and session states, it is suppressed on a
pane that has a custom status line, and — the trap that matters — **some forms report
context REMAINING, not USED**. `47% context used` and `Context left until auto-compact:
47%` are the same string shape carrying opposite meanings, so a grep that accepts whichever
matches will eventually read a worker at 53% used as 47% used, or a worker at 95% used as
comfortably fine. An inverted context alarm is worse than no alarm, because it fires
reassuringly at exactly the moment the worker is about to wedge.

`ctx NN%` from the status line always means **used**, on every pane, in every version,
because this repo renders it. If a pane shows no `ctx` segment, the status line is not
installed there — fix that (`install-statusline.sh`) rather than parsing the footer. A pane
with no `ctx` reading is **unknown**, not healthy; report it as unknown.

For **any worker at ≥95% context**, orchestrate handoff → clear → resume so nothing is lost:

1. **Handoff** — have the worker preserve state *before* clearing: commit its WIP to the
   branch (even partial, WIP-tagged) **and** post a handoff note (its plan, key findings,
   concrete next steps) as a comment on the GitHub issue it is working, so the state
   survives the clear. If the worker cannot self-handoff (already near 100%/jammed), the
   manager captures the handoff note on the issue on its behalf.
2. **`/clear`** — free the context window:
   ```bash
   tmux send-keys -t <session>:<window>.<pane> "/clear"
sleep 0.4          # let the TUI leave paste mode
tmux send-keys -t <session>:<window>.<pane> Enter    # separate call, or it never submits
   ```
3. **Resume** — a fresh-context session re-reads the handoff (issue + branch + note) and
   continues its assigned issue:
   ```bash
   tmux send-keys -t <session>:<window>.<pane> "/autocoder:fix <issue_number>"
sleep 0.4          # let the TUI leave paste mode
tmux send-keys -t <session>:<window>.<pane> Enter    # separate call, or it never submits
   ```

**Why 95%, not 100%:** a worker that runs to 100% wedges mid-task while holding a large
footprint, and at 100% the built-in `/clear` is often un-submittable via tmux (jammed
input) — forcing the heavier `restart-worker` (Step 4b), which **discards uncommitted
work**. Handing off at 95% — while `/clear` still works and the worker still has a working
context — avoids the wedge and loses nothing.

**Do NOT `/clear` a mid-task worker WITHOUT a handoff first** — that loses the task context.
(Only a worker that has *completed* its task may take a bare `/clear` + `/autocoder:fix-loop`.)

### Step 5: Dispatch Work to Idle Workers

Find unblocked claimable issues sorted by priority (the `--state open`
bucket already excludes blocked and working issues by directory):

```bash
issue_list --state open | jq -r 'sort_by(.labels | map(select(.name | test("^P[0-3]$"))) | .[0].name // "P9") | .[].number'
```

For each idle worker with an unworked issue available, send the fix command.

**The Enter must be its own `send-keys` call.** `send-keys "$text" Enter` in one
call reliably leaves the text sitting UNSUBMITTED in the agent's input box — the
TUI receives the burst as a single paste and treats the trailing newline as
pasted content, not as submit. The `sleep` is what lets the TUI leave paste
mode; zero works *sometimes*, which is worse than never working. Scripts should
call `send_tmux_text_enter` from `mux-send-lib.sh`, which does this correctly.

**Verifying delivery: grepping the pane for your marker is NOT enough.** Text
parked in the input box shows up in `capture-pane` exactly like text the agent
received, so a marker grep returns success on a dispatch that did nothing. Check
that the pane actually *submitted*:

```bash
sleep 8
tmux capture-pane -t <pane> -p | tail -6
# Submitted: prompt is clear and an activity marker (spinner/token meter) is present.
# NOT submitted: your prompt text is still visible above the status line with no
# activity marker -- send a bare `tmux send-keys -t <pane> Enter` and re-check.
```

**cmux:**
```bash
cmux send --workspace <ref> "/autocoder:fix <issue_number>"
cmux send-key --workspace <ref> Enter
```

**tmux:**
```bash
tmux send-keys -t <session>:<window>.<pane> "/autocoder:fix <issue_number>"
sleep 0.4          # let the TUI leave paste mode
tmux send-keys -t <session>:<window>.<pane> Enter    # separate call, or it never submits
```

**Codex workers:** send the shell wrapper instead of the Claude slash command.
The wrapper runs the issue-start handshake before launching Codex:
```bash
cmux send --workspace <ref> "bash scripts/codex-autocoder.sh fix <issue_number>"
cmux send-key --workspace <ref> Enter

tmux send-keys -t <session>:<window>.<pane> "bash scripts/codex-autocoder.sh fix <issue_number>"
sleep 0.4          # let the TUI leave paste mode
tmux send-keys -t <session>:<window>.<pane> Enter    # separate call, or it never submits
```

After dispatching, verify the worker started by reading its screen again after a few seconds.

### Step 5b: Add a Worker When the Queue Is Backing Up

If the human asks you to add a worker, or if the unblocked issue queue is significantly larger than the number of active workers, run:

```bash
add-worker
```

Or with explicit options:

```bash
add-worker --agent claude   # or gemini, codex, droid
add-worker --mux tmux       # or cmux
```

This creates a new worktree, adds a pane/workspace to the existing session, and focuses it so the new worker is immediately visible. The script is safe to call from within the manager session — it detects it's already inside tmux/cmux and skips re-attaching.

**When to add a worker:**
- Human explicitly asks ("add a worker", "scale up", "we need more workers")
- Unblocked issues > active workers and queue isn't draining

**When NOT to add a worker autonomously (require human confirmation):**
- Queue is draining normally
- Workers are catching up

### Step 5c: Run Review-Blocked When All Issues Are Blocked

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
  WORKING=$(issue_list --state working | jq 'length')
  UNBLOCKED=$(issue_list --state open | jq 'length')
  INT_HEAD=$(git rev-parse --short origin/integration)

  echo "[$(date +%H:%M:%S)] working=$WORKING unblocked=$UNBLOCKED integration=$INT_HEAD"

  # Check for stale working labels, restart unhealthy workers, and dispatch to
  # idle workers on each iteration (repeat Steps 3, 4, 4b, 5). Auto-restart any
  # UNHEALTHY worker (stalled AND high memory) via:
  #   worker-health
  #   restart-worker --worktree <path>   # for each flagged worktree

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
- **Restart wedged workers in place** — A worker that is stalled AND holding high memory has run out of headroom; kill and relaunch it on the same worktree/issue rather than letting it hang
- **Priority order** — Assign highest priority issues first (P0 > P1 > P2 > P3)
- **Don't double-assign** — Check "working" label before dispatching
- **Deploy only when ready** — All workers idle + no unblocked issues + new commits
- **Deploy to staging only** — Never deploy to production without explicit user request
