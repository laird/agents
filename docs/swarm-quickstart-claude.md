# Swarm Quickstart: Claude Code

Run an autonomous multi-agent swarm using Claude Code (the `claude` CLI).

## Prerequisites

- [`claude`](https://docs.anthropic.com/en/docs/claude-code) CLI installed and authenticated
- [`tmux`](https://github.com/tmux/tmux/wiki/Installing) or [`cmux`](https://github.com/nicholasgasior/cmux) installed
- GitHub CLI (`gh`) installed and authenticated

## Install

From within your target project, run these slash commands inside Claude Code:

```
/plugin add marketplace https://github.com/laird/agents
/plugin install autocoder
```

Then run the install command to set up shell scripts and aliases:

```
/autocoder:install
```

This symlinks `start-parallel`, `join-parallel`, `stop-parallel`, and related scripts into `~/.local/bin` and optionally adds shell aliases to your rc file.

## Quick Start

```bash
cd /path/to/your-project

# 1 manager + 3 workers, issue source = GitHub Issues
start-parallel --agent claude --workers 3 --issue-source github

# With manager routing (no claim races):
start-parallel --agent claude --workers 3 --route manager

# Or using the shell alias (after sourcing claude-shell-aliases.sh):
startclt 3    # 1 manager + 3 Claude workers in tmux
startclc 3    # 1 manager + 3 Claude workers in cmux
```

Each worker opens a visible tmux pane running `claude-worker-loop.sh`, which restarts a fresh `claude` process per issue (no context accumulation). The manager runs `claude-opus-5`; workers default to `claude-sonnet-5`.

## Attach / Detach

```bash
# Attach to the swarm session
tmux attach -t autocoder

# Detach (leave running)
Ctrl-b d
```

## Override Models

```bash
WORKER_MODEL=claude-haiku-4-5-20251001 \
MANAGER_MODEL=claude-opus-5 \
  start-parallel --agent claude --workers 4
```

## Stop

```bash
stop-parallel
```

## Tips

- Each worker pane shows live output — you can attach to any pane and type to un-stick an agent
- Run `/autocoder:monitor-workers` in the manager pane to get a live status table
- Use `--route manager` to have the manager dispatch issues one-by-one and eliminate worker claim collisions
- Use `--paused` to create the swarm without launching loops, then start workers with `start-workers.sh` when ready

## See Also

- [Full autocoder docs](../plugins/autocoder/)
- [Other platforms](../docs/)
