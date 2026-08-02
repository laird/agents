# Swarm Quickstart: Claude Code

Run an autonomous multi-agent swarm using Claude Code (the `claude` CLI).

## Prerequisites

- [`claude`](https://docs.anthropic.com/en/docs/claude-code) CLI installed and authenticated
- [`tmux`](https://github.com/tmux/tmux/wiki/Installing) installed
- GitHub CLI (`gh`) installed and authenticated

---

## Install

**Step 1 — Inside a Claude Code session** (slash commands typed in the Claude chat):

```
/plugin add marketplace https://github.com/laird/agents
/plugin install autocoder
/autocoder:install
```

`/autocoder:install` sets up shell scripts by symlinking `start-parallel`, `join-parallel`, `stop-parallel`, and related commands into `~/.local/bin`. Reload your shell after it finishes:

**Step 2 — In your terminal:**

```bash
source ~/.zshrc    # or ~/.bashrc
```

---

## Quick Start

**In your terminal:**

```bash
cd /path/to/your-project

# 1 manager + 3 workers
start-parallel --agent claude --workers 3 --issue-source github

# With manager routing (eliminates worker claim races):
start-parallel --agent claude --workers 3 --route manager
```

Then attach to the tmux session that was just created:

```bash
tmux attach -t claude-<project-name>
```

---

## What You'll See

The swarm creates two tmux windows. You land on **window 0 "agents"**, with each worker in its own side-by-side pane:

```
┌─────────────────────┬─────────────────────┬─────────────────────┐
│ worker-1            │ worker-2            │ worker-3            │
│                     │                     │                     │
│ Claimed #42         │ Claimed #43         │ Waiting for issue…  │
│ Created feature/    │ Running tests…      │                     │
│   issue-42          │                     │                     │
│                     │  ✓ 47/47 passed     │                     │
│ Editing src/auth.ts │                     │                     │
│ _                   │ Opening PR… _       │ _                   │
├─────────────────────┴─────────────────────┴─────────────────────┤
│ [claude-myproject]  0:agents*  1:review                         │
└─────────────────────────────────────────────────────────────────┘
```

Press `Ctrl-b 1` to switch to **window 1 "review"** — the manager:

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  /autocoder:monitor-workers                                     │
│                                                                 │
│  Swarm status — claude-myproject (3 workers)                    │
│  ──────────────────────────────────────────                     │
│  worker-1   fixing #42  feature/issue-42   running 4m          │
│  worker-2   fixing #43  feature/issue-43   running 2m          │
│  worker-3   idle        —                  waiting             │
│                                                                 │
│  Queue: 7 open issues (2 P1, 3 P2, 2 P3)                       │
│  _                                                              │
├─────────────────────────────────────────────────────────────────┤
│ [claude-myproject]  0:agents  1:review*                         │
└─────────────────────────────────────────────────────────────────┘
```

The status bar at the bottom shows both windows; `*` marks the active one.

---

## Navigating tmux

| Keys | Action |
|------|--------|
| `Ctrl-b 0` | Switch to workers (window 0) |
| `Ctrl-b 1` | Switch to manager (window 1) |
| `Ctrl-b ←` / `Ctrl-b →` | Move between worker panes within a window |
| `Ctrl-b d` | Detach — leave swarm running in background |

You can type directly into any pane to interact with that worker. For everything else, see the [tmux cheat sheet](https://tmuxcheatsheet.com).

---

## Reattach After Detaching

**In your terminal:**

```bash
tmux attach -t claude-<project-name>

# Forgot the session name? List sessions:
tmux ls
```

---

## Override Models

**In your terminal:**

```bash
WORKER_MODEL=claude-haiku-4-5-20251001 \
MANAGER_MODEL=claude-opus-5 \
  start-parallel --agent claude --workers 4
```

---

## Stop

**In your terminal:**

```bash
stop-parallel
```

---

## Tips

- Use `--route manager` so the manager dispatches issues one-by-one — no worker claim races
- Use `--paused` to create the swarm layout without launching loops; start workers later with `start-workers.sh`
- The manager window is where to run **Claude Code slash commands** like `/autocoder:monitor-workers` or `/fix 42`

---

## See Also

- [Full autocoder docs](../plugins/autocoder/)
- [Gemini quickstart](swarm-quickstart-gemini.md)
- [Codex quickstart](swarm-quickstart-codex.md)
- [Droid quickstart](swarm-quickstart-droid.md)
