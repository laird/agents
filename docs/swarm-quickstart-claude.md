# Swarm Quickstart: Claude Code

Run an autonomous multi-agent swarm using Claude Code (the `claude` CLI).

## Prerequisites

- [`claude`](https://docs.anthropic.com/en/docs/claude-code) CLI installed and authenticated
- [`tmux`](https://github.com/tmux/tmux/wiki/Installing) or [`cmux`](https://github.com/nicholasgasior/cmux) installed
- GitHub CLI (`gh`) installed and authenticated
- This repo cloned to disk and `CLAUDE.md` present in your target project

## Install

```bash
# From within your target project repo
claude mcp add https://github.com/laird/agents   # or clone locally and use local path
```

Or install by cloning:

```bash
git clone https://github.com/laird/agents ~/src/agents
```

## Quick Start

```bash
cd /path/to/your-project

# 1 manager + 3 workers, issue source = GitHub Issues
~/src/agents/plugins/autocoder/scripts/start-parallel-agents.sh \
  --agent claude --workers 3 --issue-source github

# With manager routing (no claim races):
~/src/agents/plugins/autocoder/scripts/start-parallel-agents.sh \
  --agent claude --workers 3 --route manager
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
  start-parallel-agents.sh --agent claude --workers 4
```

## Stop

```bash
~/src/agents/plugins/autocoder/scripts/stop-parallel-agents.sh
```

## Tips

- Each worker pane shows live output — you can attach to any pane and type to un-stick an agent
- Run `/autocoder:monitor-workers` in the manager pane to get a live status table
- Use `--route manager` to have the manager dispatch issues one-by-one and eliminate worker claim collisions
- Use `--paused` to create the swarm without launching loops, then start workers with `start-workers.sh` when ready

## See Also

- [Full autocoder docs](../plugins/autocoder/)
- [Other platforms](../docs/)
