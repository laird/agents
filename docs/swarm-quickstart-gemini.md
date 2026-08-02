# Swarm Quickstart: Gemini CLI (Antigravity)

Run an autonomous multi-agent swarm using the Gemini CLI (`gemini` / Antigravity).

## Prerequisites

- [`gemini`](https://github.com/google-gemini/gemini-cli) CLI installed and authenticated (`gemini auth login`)
- [`tmux`](https://github.com/tmux/tmux/wiki/Installing) installed
- GitHub CLI (`gh`) installed and authenticated

> **macOS:** [`cmux`](https://github.com/nicholasgasior/cmux) is also supported as an alternative multiplexer. Pass `--mux cmux` to `start-parallel` if you prefer it.

---

## Install

**In your terminal:**

```bash
git clone https://github.com/laird/agents /path/to/agents

# Link start-parallel, stop-parallel, and related scripts into ~/.local/bin
bash /path/to/agents/scripts/install-shell-aliases.sh --agent gemini

source ~/.zshrc    # or ~/.bashrc
```

The Gemini workflows live in `.agent/workflows/` and are loaded automatically when `gemini` runs from your project root. No separate plugin install step is needed.

---

## Quick Start

**In your terminal:**

```bash
cd /path/to/your-project
start-parallel --agent gemini --workers 3 --issue-source github
```

Then attach to the tmux session that was just created:

```bash
tmux attach -t gemini-<project-name>
```

Each worker runs `gemini-fix-loop.sh`, which calls `gemini -p` as a subprocess per issue — no session state carries over between fixes. The manager runs an interactive Gemini session using `/monitor-loop`.

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
│ [gemini-myproject]  0:agents*  1:review                         │
└─────────────────────────────────────────────────────────────────┘
```

Press `Ctrl-b 1` to switch to **window 1 "review"** — the manager:

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  /monitor-loop                                                  │
│                                                                 │
│  Swarm status — gemini-myproject (3 workers)                    │
│  ──────────────────────────────────────────                     │
│  worker-1   fixing #42  feature/issue-42   running 4m          │
│  worker-2   fixing #43  feature/issue-43   running 2m          │
│  worker-3   idle        —                  waiting             │
│                                                                 │
│  Queue: 7 open issues (2 P1, 3 P2, 2 P3)                       │
│  _                                                              │
├─────────────────────────────────────────────────────────────────┤
│ [gemini-myproject]  0:agents  1:review*                         │
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
tmux attach -t gemini-<project-name>

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

- Workers run `--sandbox=false` by default (required for file edits and shell commands)
- Use `--route manager` so the manager dispatches issues one-by-one — no worker claim races
- Use `--paused` to create the swarm layout without launching loops; start workers later with `start-workers.sh`

---

## See Also

- [Antigravity platform docs](ANTIGRAVITY.md)
- [Claude quickstart](swarm-quickstart-claude.md)
- [Codex quickstart](swarm-quickstart-codex.md)
- [Droid quickstart](swarm-quickstart-droid.md)
