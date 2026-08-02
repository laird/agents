# Swarm Quickstart: OpenAI Codex CLI

Run an autonomous multi-agent swarm using the Codex CLI (`codex`).

## Prerequisites

- [`codex`](https://github.com/openai/codex) CLI installed and authenticated
- [`tmux`](https://github.com/tmux/tmux/wiki/Installing) or [`cmux`](https://github.com/nicholasgasior/cmux) installed
- GitHub CLI (`gh`) installed and authenticated
- This repo cloned and its skills installed (see below)

## Install

```bash
git clone https://github.com/laird/agents ~/src/agents

# Install skills and runtime wrappers into your project
bash ~/src/agents/scripts/install-codex.sh /path/to/your-project

# Reload shell aliases
source ~/.zshrc
```

The installer symlinks `skills/autocoder` and `skills/modernize` into `~/.codex/skills`, and links the runtime scripts into `~/.local/bin`.

## Quick Start

```bash
cd /path/to/your-project

# 1 manager + 3 workers, issue source = GitHub Issues
start-parallel-agents.sh --agent codex --workers 3 --issue-source github

# Short alias (after sourcing codex-shell-aliases.sh):
startcc 3    # cmux swarm with 3 Codex workers
startct 3    # tmux swarm with 3 Codex workers
```

## Worker Modes

Codex workers run in one of two modes depending on whether `/goal` is available:

| Mode | Description |
|------|-------------|
| **interactive `/goal`** | Long-lived Codex session; Codex manages its own loop internally |
| **shell fallback** | `codex-fix-loop.sh` subprocess per issue; provides fresh context each time |

The shell fallback is preferred for fresh context. The interactive `/goal` mode is used when the probe script confirms `/goal` is available.

## Manager Routing

With `--route manager`, the manager dispatches issues directly to workers via `/autocoder:fix <N>`, eliminating worker claim races:

```bash
start-parallel-agents.sh --agent codex --workers 3 --route manager
```

## Attach / Detach

```bash
tmux attach -t autocoder   # attach
Ctrl-b d                   # detach
```

## Stop

```bash
stop-parallel-agents.sh
```

## Tips

- Workers use `start-issue-work.sh` to claim issues atomically before editing — this is mandatory for collision safety
- If a worker gets stuck in the interactive `/goal` mode, attach to its pane and guide it
- Use `--paused` to create the swarm topology without launching loops

## See Also

- [Codex install docs](CODEX-INSTALL.md)
- [Other platforms](../docs/)
