# Autocoder Help

Start by examining the environment to give contextual guidance:

```bash
# Issue backend
ISSUE_SOURCE=$(python3 -c "
import json, os
d = json.load(open('.autocoder.json')) if os.path.exists('.autocoder.json') else {}
print(d.get('issueSource', 'not configured'))
" 2>/dev/null || echo "not configured")

# Installed agent CLIs
HAS_CLAUDE=$(command -v claude &>/dev/null && echo yes || echo no)
HAS_CODEX=$(command -v codex &>/dev/null && echo yes || echo no)
HAS_GEMINI=$(command -v gemini &>/dev/null && echo yes || echo no)
HAS_DROID=$(command -v droid &>/dev/null && echo yes || echo no)

# Muxers
HAS_TMUX=$(command -v tmux &>/dev/null && echo yes || echo no)
HAS_CMUX=$(command -v cmux &>/dev/null && echo yes || echo no)

# Active sessions
ACTIVE_SESSIONS=$(tmux list-sessions 2>/dev/null | grep -c "dev-loop\|claude-\|codex-\|gemini-\|droid-" || echo 0)

echo "Issue backend:  $ISSUE_SOURCE"
echo "Agents:         $(echo claude=$HAS_CLAUDE codex=$HAS_CODEX gemini=$HAS_GEMINI droid=$HAS_DROID)"
echo "Muxers:         tmux=$HAS_TMUX cmux=$HAS_CMUX"
echo "Active sessions: $ACTIVE_SESSIONS"
```

Based on what you find, give contextual guidance:

- **If issue source not configured**: "Run `/autocoder:set-issue-source` first to configure the issue backend (file or GitHub)."
- **If no agent CLIs detected**: List install links for claude, codex, gemini, droid.
- **If no muxer**: Suggest `brew install tmux` or cmux.
- **Otherwise**: Show the most relevant next steps based on context (active sessions, issue count, etc.).

---

## Commands by Category

### Issue Backend

| Command | Purpose |
|---------|---------|
| `/set-issue-source` | Switch issue backend (file or GitHub) |
| `/record-issue` | Create a new issue in the configured backend |
| `/list-issues` | List issues in the current backend |
| `/update-issue <number>` | Update an existing issue |
| `/close-issue <number>` | Close an issue |

### Issue Resolution

| Command | Purpose |
|---------|---------|
| `/dev` | Fix highest-priority issue or a specific issue |
| `/dev-loop` | Run continuous issue resolution |
| `/review-blocked` | Interactively review blocked issues (run alongside dev-loop) |
| `/stop-loop` | Stop the continuous loop |

### Design & Brainstorming

| Command | Purpose |
|---------|---------|
| `/brainstorm-issue [number]` | Brainstorm design for an issue |
| `/list-needs-design` | List issues needing design work |
| `/list-needs-feedback` | List issues needing human feedback |

### Proposal Management

| Command | Purpose |
|---------|---------|
| `/list-proposals` | List AI-generated proposals awaiting approval |
| `/approve-proposal <number>` | Approve a proposal for implementation |

### Testing & Quality

| Command | Purpose |
|---------|---------|
| `/full-regression-test` | Run comprehensive test suite |
| `/improve-test-coverage` | Analyze and improve test coverage |

### Setup

| Command | Purpose |
|---------|---------|
| `/install` | Install stop hook and parallel scripts |
| `/set-issue-source` | Configure the issue backend |

---

## Parallel Agents

```bash
start-parallel 3 --mux tmux --agent claude
start-parallel 4 --mux cmux --agent gemini
start-parallel 5 --mux tmux --agent codex --issue-source github --paused
add-worker --agent codex
add-worker 2 --agent codex
remove-worker 2 --agent codex
```

`start-parallel` is the primary launcher. It supports `--mux tmux|cmux`, `--agent claude|gemini|codex|droid`, `--issue-source file|github|jira|ado`, `--issue-dir PATH`, `--paused`, and `--no-worktrees`. If `--issue-source` is omitted, it uses the project issue source from `.autocoder.json`.

Use `--paused` to create the manager session and workers without starting the monitor loop or worker ticket-pulling loops. Use `add-worker [count]` when the user asks the manager to start idle workers or add and start more workers. Use `remove-worker WORKER_NUMBER [...]` when the user asks the manager to shut down selected workers.

---

## Workflow Patterns

### Pattern 1: Single Issue Fix

```
/dev 123
```

### Pattern 2: Continuous Autonomous Mode

```
/set-issue-source   # First time: configure file or GitHub backend
/install            # First time: install stop hook + parallel scripts
/dev-loop
```

### Pattern 3: Parallel Swarm (example: 3 Claude workers in tmux)

```bash
start-parallel 3 --mux tmux --agent claude
```

### Pattern 4: Paused Parallel Swarm

```bash
start-parallel 5 --mux tmux --agent codex --issue-source github --paused
add-worker --agent codex
```

### Pattern 5: Design-First

```
/list-needs-design
/brainstorm-issue 45
/dev 45
```

### Pattern 6: Proposal Review

```
/list-proposals
/approve-proposal 67
/dev
```

### Pattern 6: Fix-Loop + Parallel Review

```
# Window 1: autonomous worker
/dev-loop

# Window 2: unblock stuck issues
/review-blocked
```

---

## Priority System

| Priority | Description |
|----------|-------------|
| **P0** | Critical — system down, data loss, security |
| **P1** | High — major feature broken, no workaround |
| **P2** | Medium — degraded, workaround exists |
| **P3** | Low — minor, cosmetic |

Unlabeled issues are triaged automatically on first `/dev`.

## Blocking Labels

| Label | Meaning |
|-------|---------|
| `needs-approval` | Architectural decision required |
| `needs-design` | Requirements unclear |
| `needs-clarification` | Missing context |
| `too-complex` | Beyond autonomous capability |

## See Also

- `/autocoder:install` — full interactive setup
- `/modernize-help` — modernization workflow help
- Project `CLAUDE.md` for test command configuration
