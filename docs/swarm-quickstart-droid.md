# Swarm Quickstart: Droid (Factory)

Run an autonomous multi-agent swarm using Droid / Factory (`.factory/` convention).

## Prerequisites

- Droid CLI installed and authenticated
- [`tmux`](https://github.com/tmux/tmux/wiki/Installing) installed
- GitHub CLI (`gh`) installed and authenticated

> **macOS:** [`cmux`](https://github.com/nicholasgasior/cmux) is also supported as an alternative multiplexer. Pass `--mux cmux` to `start-parallel` if you prefer it.

---

## Install

**In your terminal:**

```bash
git clone https://github.com/laird/agents /path/to/agents

# Install skills, droids, and runtime scripts into your project
bash /path/to/agents/scripts/install-droid.sh /path/to/your-project

source ~/.zshrc    # or ~/.bashrc
```

The installer symlinks `.factory/skills/autocoder`, `.factory/droids/*.md`, and plugin commands into your project, and links `start-parallel`, `stop-parallel`, and related scripts into `~/.local/bin`.

---

## Quick Start

**In your terminal:**

```bash
cd /path/to/your-project
start-parallel 3 --agent droid --issue-source github
```

Then attach to the tmux session that was just created:

```bash
tmux attach -t droid-<project-name>
```

Each worker runs `droid-fix-loop.sh`, launching a new Droid subprocess per issue — every fix gets a clean context window with no accumulation from previous issues.

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
│ [droid-myproject]  0:agents*  1:review                          │
└─────────────────────────────────────────────────────────────────┘
```

Press `Ctrl-b 1` to switch to **window 1 "review"** — the manager:

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  droid-manage-workers-loop.sh                                   │
│                                                                 │
│  Swarm status — droid-myproject (3 workers)                     │
│  ──────────────────────────────────────────                     │
│  worker-1   fixing #42  feature/issue-42   running 4m          │
│  worker-2   fixing #43  feature/issue-43   running 2m          │
│  worker-3   idle        —                  waiting             │
│                                                                 │
│  Queue: 7 open issues (2 P1, 3 P2, 2 P3)                       │
│  _                                                              │
├─────────────────────────────────────────────────────────────────┤
│ [droid-myproject]  0:agents  1:review*                          │
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
tmux attach -t droid-<project-name>

# Forgot the session name? List sessions:
tmux ls
```

---

## Stop

**In your terminal:**

```bash
stop-parallel
```

---

## Tips

- Skills are loaded from `.factory/skills/` — add project-specific guidance there
- Use `--route manager` so the manager dispatches issues one-by-one — no worker claim races
- Use `--paused` to create the swarm layout without launching loops; start workers later with `start-workers.sh`

---

## See Also

- [Droid install docs](DROID-INSTALL.md)
- [Droid platform docs](DROID.md)
- [Claude quickstart](swarm-quickstart-claude.md)
- [Gemini quickstart](swarm-quickstart-gemini.md)
- [Codex quickstart](swarm-quickstart-codex.md)
