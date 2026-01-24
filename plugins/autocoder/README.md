# Autocoder Plugin (Claude Code)

Autonomous GitHub issue resolution system with infinite loop support.

## Installation

```bash
# Add the plugin marketplace (one-time setup)
/plugin add-registry https://github.com/laird/agents

# Install the autocoder plugin
/plugin install autocoder

# Start the infinite loop (auto-installs stop hook)
/fix-loop
```

That's it! The `/fix-loop` command automatically configures the stop hook in your project's `.claude/settings.json` if not already present.

## Required Labels

The plugin automatically creates these labels on first run:

| Label | Color | Purpose |
|-------|-------|---------|
| `P0` | Red | Critical - system down, security, data loss |
| `P1` | Orange-Red | High - major feature broken, no workaround |
| `P2` | Orange | Medium - feature degraded, workaround exists |
| `P3` | Green | Low - minor issue, cosmetic |
| `bug` | Red | Something isn't working |
| `enhancement` | Cyan | New feature or request |
| `proposal` | Light Purple | AI-generated, awaiting human approval |
| `test-failure` | Light Red | Regression test failure |
| `needs-review` | Yellow | Requires human review |
| `in-progress` | Green | Currently being worked on |
| `working` | Blue | **Concurrency lock** - issue claimed by an agent |

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

## Commands

| Command | Description |
|---------|-------------|
| `/fix` | Fix the highest priority GitHub issue |
| `/fix-loop` | Start infinite loop that runs `/fix` forever |
| `/install-stop-hook` | Configure stop hook in project (one-time setup) |
| `/full-regression-test` | Run complete test suite and create issues for failures |
| `/improve-test-coverage` | Analyze and improve test coverage |
| `/list-proposals` | List pending enhancement proposals |

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
