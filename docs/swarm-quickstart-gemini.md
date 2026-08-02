# Swarm Quickstart: Gemini CLI (Antigravity)

Run an autonomous multi-agent swarm using the Gemini CLI (`gemini` / Antigravity).

## Prerequisites

- [`gemini`](https://github.com/google-gemini/gemini-cli) CLI installed and authenticated (`gemini auth login`)
- [`tmux`](https://github.com/tmux/tmux/wiki/Installing) or [`cmux`](https://github.com/nicholasgasior/cmux) installed
- GitHub CLI (`gh`) installed and authenticated
- This repo cloned to disk

## Install

```bash
git clone https://github.com/laird/agents ~/src/agents
```

The Gemini (Antigravity) workflows live in `.agent/workflows/` and are loaded automatically when `gemini` runs from your project root.

## Quick Start

```bash
cd /path/to/your-project

# 1 manager + 3 workers, issue source = GitHub Issues
~/src/agents/plugins/autocoder/scripts/start-parallel-agents.sh \
  --agent gemini --workers 3 --issue-source github

# With manager routing (no claim races):
~/src/agents/plugins/autocoder/scripts/start-parallel-agents.sh \
  --agent gemini --workers 3 --route manager
```

Each worker runs `gemini-fix-loop.sh` in its own tmux pane. The loop calls `gemini -p` as a subprocess per issue, giving each fix a fresh context. The manager runs an interactive Gemini session using `/monitor-loop`.

## Attach / Detach

```bash
tmux attach -t autocoder   # attach to swarm
Ctrl-b d                   # detach (leave running)
```

## Fresh Context

Workers call `gemini -p "<prompt>"` as a subprocess for each issue — no session state carries over between fixes. This matches the Claude behavior.

## Stop

```bash
~/src/agents/plugins/autocoder/scripts/stop-parallel-agents.sh
```

## Tips

- Workers run `--sandbox=false` by default (required for file edits and shell commands)
- You can enter any worker's tmux pane and type to interact with it directly
- Run `/monitor-loop` in the manager pane to see worker status

## See Also

- [Antigravity platform docs](../docs/ANTIGRAVITY.md)
- [Other platforms](../docs/)
