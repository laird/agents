# Swarm Quickstart: Android Studio Droid (Factory)

Run an autonomous multi-agent swarm using Droid / Factory (`.factory/` convention).

## Prerequisites

- Droid CLI installed and authenticated
- [`tmux`](https://github.com/tmux/tmux/wiki/Installing) or [`cmux`](https://github.com/nicholasgasior/cmux) installed
- GitHub CLI (`gh`) installed and authenticated
- This repo cloned and its runtime installed (see below)

## Install

```bash
git clone https://github.com/laird/agents ~/src/agents

# Install skills and runtime wrappers into your project
bash ~/src/agents/scripts/install-droid.sh /path/to/your-project

# Reload shell aliases
source ~/.zshrc
```

The installer symlinks `.factory/skills/autocoder`, `.factory/droids/*.md`, and plugin commands into your project, and links runtime scripts into `~/.local/bin`.

## Quick Start

```bash
cd /path/to/your-project

# 1 manager + 3 workers, issue source = GitHub Issues
start-parallel-agents.sh --agent droid --workers 3 --issue-source github

# Short aliases (after sourcing droid-shell-aliases.sh):
startdt 3    # tmux swarm with 3 Droid workers
startdc 3    # cmux swarm with 3 Droid workers
```

## Fresh Context

Each worker runs `droid-fix-loop.sh` as a shell loop, launching a new Droid subprocess per issue. This gives every fix a clean context with no accumulation from previous issues.

## Attach / Detach

```bash
tmux attach -t autocoder   # attach to swarm
Ctrl-b d                   # detach (leave running)

# Or rejoin via alias:
joindt    # rejoin tmux Droid session
joindc    # list/select cmux Droid workspaces
```

## Manager Routing

With `--route manager`, the manager dispatches issues one-by-one to workers, eliminating claim races:

```bash
start-parallel-agents.sh --agent droid --workers 3 --route manager
```

## Stop

```bash
stop-parallel-agents.sh
```

## Tips

- Workers and manager run in separate visible tmux panes — attach to any pane to intervene
- Skills are loaded from `.factory/skills/` — add project-specific guidance there
- Use `--paused` to create the swarm without starting loops

## See Also

- [Droid install docs](DROID-INSTALL.md)
- [Droid platform docs](DROID.md)
- [Other platforms](../docs/)
