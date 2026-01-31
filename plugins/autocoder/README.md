# Autocoder Plugin (Claude Code)

Autonomous GitHub issue resolution system with infinite loop support.

## ⚠️ Compatibility Notice

**This plugin is primarily developed for personal use.** While it should work on Linux, macOS, and WSL (Windows Subsystem for Linux), there are no guarantees it will work in all environments. Use at your own risk.

**Tested Platforms:**
- ✅ Linux
- ✅ macOS
- ✅ WSL (Windows Subsystem for Linux)
- ❌ Windows (native) - Not supported

## Installation

```bash
# Add the plugin marketplace (one-time setup)
/plugin add-registry https://github.com/laird/agents

# Install the autocoder plugin
/plugin install autocoder

# Run the installer (installs stop hook + parallel scripts)
/install
```

The `/install` command will:
1. Install stop hook for `/fix-loop` (project-local)
2. Install `start-parallel` and `join-parallel` scripts (global)
3. Optionally create shell aliases: `start` and `join`

Each step is explained clearly and requires your approval before making changes.

## Updating

If you cloned this repository and want to sync the installed plugin with the latest changes:

```bash
# From anywhere
bash ~/src/agents/scripts/update-plugin.sh

# Or from the repo
bash scripts/update-plugin.sh
```

The script auto-detects the repository location and updates:
- Commands (13 files)
- Scripts (7 files)
- Hooks (1 file)
- plugin.json (version info)

Alternatively, update via Claude Code (if available):
```bash
/plugin update autocoder
```

## Required Labels

The plugin automatically creates these labels on first run:

### Priority Labels

| Label | Color | Purpose |
|-------|-------|---------|
| `P0` | Red | Critical - system down, security, data loss |
| `P1` | Orange-Red | High - major feature broken, no workaround |
| `P2` | Orange | Medium - feature degraded, workaround exists |
| `P3` | Green | Low - minor issue, cosmetic |

### Status Labels

| Label | Color | Purpose |
|-------|-------|---------|
| `bug` | Red | Something isn't working |
| `enhancement` | Cyan | New feature or request |
| `proposal` | Light Purple | AI-generated, awaiting human approval |
| `test-failure` | Light Red | Regression test failure |
| `needs-review` | Yellow | Requires human review |
| `in-progress` | Green | Currently being worked on |
| `working` | Blue | **Concurrency lock** - issue claimed by an agent |

### Blocking Labels

These labels indicate why fix-loop cannot autonomously work on an issue:

| Label | Color | When Applied | Example |
|-------|-------|--------------|---------|
| `needs-approval` | `e99695` (red) | Architectural decisions, major changes, security implications | "Should we migrate from REST to GraphQL?" |
| `needs-design` | `fbca04` (yellow) | Requirements unclear, multiple valid approaches, needs design phase | "Add user dashboard" (what features? layout?) |
| `needs-clarification` | `d4c5f9` (purple) | Incomplete information, missing context, questions needed | "Fix the bug in checkout" (which bug? what's failing?) |
| `too-complex` | `b60205` (dark red) | Beyond autonomous capability, requires deep expertise/judgment | "Refactor entire auth system for multi-tenancy" |

**Note**: Blocking labels are independent from priority labels. An issue can have both `P0` + `needs-design`, meaning it's critical but needs design work before implementation.

## Workflow Priority

1. **Triage** - Assign P0-P3 to any unprioritized issues first
2. **Bugs** - Fix P0 → P1 → P2 → P3 issues
3. **Regression Tests** - Run tests, create issues for failures
4. **Approved Enhancements** - Implement enhancements without `proposal` label
5. **Proposals** - Keep generating proposals until nothing useful to propose
6. **Idle Sleep** - Sleep 60 min (configurable), then check for new work

Proposals are tagged with `proposal` label and never auto-implemented. When a human removes the label, the workflow will implement it.

## Parallel Agent Support

The `working` label provides concurrency control when multiple agents run in parallel:

### How It Works

1. **Claim**: When an agent starts work on an issue, it adds the `working` label
2. **Filter**: All issue queries exclude issues with the `working` label
3. **Release**: When work completes (success, skip, or failure), the label is removed

### Benefits

- **No duplicate work**: Multiple agents won't pick up the same issue
- **Visible status**: GitHub UI shows which issues are actively being worked on
- **Automatic cleanup**: Label is removed on completion, skip, or when an issue is closed

### Manual Override

If an agent crashes or disconnects without releasing the lock:

```bash
# Remove the working label manually
gh issue edit <issue_number> --remove-label "working"
```

### Example: Running Multiple Agents

```bash
# Terminal 1: Start first agent
/fix-loop

# Terminal 2: Start second agent (different working directory or repo clone)
/fix-loop

# Both agents will work on different issues without conflict
```

## Blocked Issue Review Workflow

When fix-loop encounters issues it cannot handle autonomously, it adds blocking labels (`needs-approval`, `needs-design`, `needs-clarification`, `too-complex`) and moves on. Use `/review-blocked` in a separate session to review and unblock these issues.

### Workflow

```bash
# Terminal 1: Run fix-loop continuously
/fix-loop

# Terminal 2: Review blocked issues interactively (in parallel)
/review-blocked
```

### Interactive Review Process

1. **Overview**: Shows summary of blocked issues by category and priority
   ```
   Found 5 blocked issues:
   - 3 needs-design (1 P0, 2 P1)
   - 2 needs-approval (1 P1, 1 P2)
   - 0 needs-clarification
   - 0 too-complex
   ```

2. **Highest Priority First**: Proposes the highest priority blocked issue
   ```
   Start with P0 needs-design issue #123: Add user authentication system?
   ```

3. **Analysis & Recommendations**: Presents 2-3 approaches with pros/cons
   ```markdown
   ### Recommended Approaches

   **Option A: OAuth 2.0 with JWT** (Recommended)
   - Pros: Industry standard, scalable, supports SSO
   - Cons: More complex initial setup
   - Effort: Medium

   **Option B: Session-based auth**
   - Pros: Simpler, well-understood
   - Cons: Harder to scale, no SSO support
   - Effort: Small
   ```

4. **Decision**: Choose how to proceed
   - **Approve** → Removes blocking label, fix-loop will implement on next iteration
   - **Explore further** → Use `/brainstorm`, `/q1-hypothesize`, or ask questions
   - **Reject** → Closes issue with reason
   - **Skip** → Leaves blocked, moves to next issue

### Command Options

```bash
/review-blocked                     # Review all blocked issues
/review-blocked --label needs-design    # Filter to specific blocking label
/review-blocked --priority P0       # Filter to specific priority
/review-blocked 123                 # Jump directly to issue #123
```

### Benefits

- **Non-blocking**: Runs in separate session, doesn't interrupt fix-loop
- **Priority-driven**: Always surfaces most important blocked issues first
- **Lightweight**: Quick recommendations, dive deeper with other skills if needed
- **Clear transitions**: Issues move from blocked → approved with proper labels

## Commands

| Command | Description |
|---------|-------------|
| `/fix` | Fix the highest priority GitHub issue |
| `/fix-loop` | Start infinite loop that runs `/fix` forever |
| `/review-blocked` | Interactive review of blocked issues (run in parallel with fix-loop) |
| `/install` | Install stop hook and parallel agent scripts (with clear explanations) |
| `/stop-loop` | Stop the continuous fix loop |
| `/full-regression-test` | Run complete test suite and create issues for failures |
| `/improve-test-coverage` | Analyze and improve test coverage |
| `/list-proposals` | List pending enhancement proposals |

## Parallel Agent System

Run multiple Claude Code agents in parallel using tmux and git worktrees for coordinated autonomous work.

### Quick Start

```bash
# 1. Install autocoder components (one-time, inside Claude Code)
/install

# Approve when prompted:
# - Stop hook: Yes (for /fix-loop)
# - Parallel scripts: Yes (for terminal commands)
# - Shell aliases: Optional (shorter commands)

# 2. Start parallel agents (from terminal, in your project)
cd ~/src/myproject
start-parallel 3        # 3 agents: 1 coordinator + 2 workers
# or: start 3 (if you installed aliases)

# 3. Detach when done watching
# Ctrl+b then d

# 4. Rejoin anytime
join-parallel          # or: join (if using aliases)
```

### How It Works

Creates a tmux session with 2 windows:

**Window 0: Parallel Fix Agents**
- 3+ panes running `/fix-loop` simultaneously
- Pane 0: Main repo (coordinator, handles deployment)
- Pane 1-N: Git worktrees (workers, each in separate feature branch)
- All share task list via `CLAUDE_CODE_TASK_LIST_ID`
- Prevents duplicate work with `working` label
- Coordinator merges and deploys when all agents idle

**Window 1: Review/Planning**
- 1 pane running `/review-blocked`
- Interactive review of issues needing human decisions
- Non-blocking to autonomous agents

### Terminal Commands

After running `/install`:

| Command | Purpose | Usage |
|---------|---------|-------|
| `start-parallel` | Launch parallel agent system | `start-parallel [num_agents] [--no-worktrees]` |
| `join-parallel` | Rejoin existing session | `join-parallel [session_name]` |
| `end-parallel` | End session and clean up | `end-parallel [session_name] [--keep-worktrees]` |

**Examples:**
```bash
# Starting
start-parallel              # 3 agents (default)
start-parallel 5            # 5 agents (1 coordinator + 4 workers)
start-parallel 3 --no-worktrees  # No git worktrees, same directory

# Joining
join-parallel              # Auto-detect based on current directory
join-parallel claude-myproject  # Explicit session name

# Ending
end-parallel               # End session and optionally remove worktrees
end-parallel --keep-worktrees  # End session but keep worktrees
end-parallel claude-myproject  # End specific session
```

### Git Worktrees

For each worker agent:
- **Worktree path**: `<project>-wt-1`, `<project>-wt-2`, etc. (sibling directories)
- **Branch**: `<current-branch>-wt-1`, `<current-branch>-wt-2`, etc.
- **Isolation**: Each agent works on independent branch without conflicts
- **Integration**: Main agent merges completed work when deploying

**Note**: Use `--no-worktrees` to run all agents in same directory (no git operations).

### Session Management

**Session naming**: `claude-<project-name>`

**Recommended workflow:**
- End session: `end-parallel` (kills tmux session + optionally removes worktrees)
- Detach temporarily: `Ctrl+b` then `d` (session keeps running)

**Tmux commands:**
- Switch windows: `Ctrl+b` then `0` or `1`
- Detach: `Ctrl+b` then `d`
- Manual kill: `tmux kill-session -t claude-<project-name>` (leaves worktrees behind)

### Benefits

- **Parallel work**: Multiple agents tackle independent issues simultaneously
- **Zero conflicts**: Git worktrees provide isolation
- **Coordinated**: Shared task list prevents duplicate work
- **Non-blocking review**: Handle blocked issues without interrupting agents
- **Automatic deployment**: Coordinator merges and deploys when ready

### Example Workflow

```bash
# Terminal: Start the system
cd ~/src/myproject
start-parallel 3

# [Window 0 shows 3 agents working in parallel]
# - Main agent: Fixing P0 issue #45
# - Worker 1: Fixing P1 issue #67
# - Worker 2: Running regression tests

# [Switch to Window 1 with Ctrl+b then 1]
# - Review agent prompts: "Issue #89 needs-design. Review?"
# - You approve Option A
# - Issue unblocked, agents can work on it

# Detach and let it run
# Ctrl+b then d

# Later: Check on progress
join-parallel
```

## Utility Scripts

The plugin includes utility scripts in `scripts/` directory for automating common tasks:

### Parallel Agent Management

| Script | Purpose | Usage |
|--------|---------|-------|
| `start-parallel-agents.sh` | Launch multi-agent tmux session | `start-parallel [num_agents] [--no-worktrees]` (after install) |
| `join-parallel-agents.sh` | Rejoin existing tmux session | `join-parallel [session_name]` (after install) |

### Blocked Issue Management

| Script | Purpose | Usage |
|--------|---------|-------|
| `fetch-blocked-issues.sh` | Fetch and filter blocked issues | `bash ~/.claude/plugins/autocoder/scripts/fetch-blocked-issues.sh [--label LABEL] [--priority PRIORITY] [ISSUE_NUM]` |
| `add-blocking-label.sh` | Add blocking label with explanation | `bash ~/.claude/plugins/autocoder/scripts/add-blocking-label.sh <issue_num> <label> <reason>` |
| `approve-blocked-issue.sh` | Approve and unblock an issue | `bash ~/.claude/plugins/autocoder/scripts/approve-blocked-issue.sh <issue_num> <label> <approach>` |
| `reject-blocked-issue.sh` | Reject and close a blocked issue | `bash ~/.claude/plugins/autocoder/scripts/reject-blocked-issue.sh <issue_num> <reason>` |

### Testing

| Script | Purpose | Usage |
|--------|---------|-------|
| `regression-test.sh` | Run comprehensive regression tests | `bash ~/.claude/plugins/autocoder/scripts/regression-test.sh` |

### Script Features

- **Portable**: Work across different plugin installations and environments
- **Standalone**: Can be run directly from command line for automation
- **Idempotent**: Safe to run multiple times (creates labels if missing)
- **Standards-based**: Uses GitHub CLI (`gh`) for all GitHub operations

### Example: Manual Workflow

```bash
# Fetch all needs-design issues
bash ~/.claude/plugins/autocoder/scripts/fetch-blocked-issues.sh --label needs-design | jq

# Approve an issue after manual review
bash ~/.claude/plugins/autocoder/scripts/approve-blocked-issue.sh 123 "needs-design" "Option A: OAuth 2.0"

# Add blocking label to an issue
bash ~/.claude/plugins/autocoder/scripts/add-blocking-label.sh 456 "needs-approval" "Breaking API change requires approval"
```

These scripts are called by the commands but can also be used independently for custom workflows or CI/CD integration.

## Infinite Loop Setup

The `/fix-loop` command uses Claude Code's stop hook mechanism to run forever.

### How It Works

1. Creates state file: `.claude/fix-loop.local.md`
2. Stop hook intercepts session exit
3. If state file exists, feeds `/fix` back as input
4. Loop continues until manually stopped

### Usage

```bash
# Start infinite loop
/fix-loop

# Limit to 100 iterations
/fix-loop 100

# Custom idle sleep time (default 60 min)
/fix-loop --sleep 120
```

### Stopping the Loop

1. **Ctrl+C** - Manual interrupt
2. **Output `STOP_FIX_GITHUB_LOOP`** - Explicit stop signal
3. **Max iterations** - If configured, stops when reached
4. **Delete state file** - `rm .claude/fix-loop.local.md`
5. **Critical errors** - Auto-pauses on auth/rate limit issues

### Idle Behavior

When no work is available (no bugs, no approved enhancements, nothing useful to propose), the loop sleeps for 60 minutes (configurable with `--sleep`) then wakes to check for:
- New human-created issues
- Comments on existing issues
- Approved proposals (human removed `proposal` label)

### State File

The loop state is stored in `.claude/fix-loop.local.md`:

```markdown
---
iteration: 5
max_iterations: 0
idle_sleep_minutes: 60
started: 2024-01-15T10:30:00-05:00
---

/fix
```

The `.local.md` suffix ensures it's gitignored.

## Comparison with Watchdog Script

| Feature | Stop Hook | Watchdog Script |
|---------|-----------|-----------------|
| Runs inside Claude | Yes | External |
| Maintains context | Yes | Fresh start |
| Configurable limits | Yes | No |
| Smart stop signals | Yes | No |
| Error recovery | Pauses | Restarts |
| Requires external process | No | Yes |

The stop hook approach is more reliable because:
- Claude maintains conversation context across iterations
- No gap between exit and restart
- Smart detection of when to pause (proposals, errors)
- Can set iteration limits
