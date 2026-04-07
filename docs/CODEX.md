# Codex Integration

**Platform**: Codex CLI
**Directory**: `.codex-plugin/`, `codex-plugins/`, `skills/`, and `scripts/`

## Overview

Codex support in this repository is additive. It does not replace or reinterpret:

- Claude Code plugins in `plugins/`
- Antigravity / Gemini assets in `agents/`

Codex uses:

- `.codex-plugin/` and `codex-plugins/` for marketplace plugin metadata
- `skills/` for Codex-native skill entrypoints
- `scripts/` for loop wrappers and runtime helpers
- existing repo scripts where they are already platform-agnostic

## Current Codex Assets

### Marketplace Plugins

- `.codex-plugin/marketplace.json` - Codex marketplace registry
- `codex-plugins/autocoder/.codex-plugin/plugin.json` - Autocoder Codex plugin manifest
- `codex-plugins/modernize/.codex-plugin/plugin.json` - Modernize Codex plugin manifest

Codex marketplace install:

```bash
/plugin add marketplace https://github.com/laird/agents
```

### Skills

- `skills/autocoder/` - autonomous GitHub issue workflow
- `skills/modernize/` - modernization assess/plan/execute workflow

### Runtime Scripts

- `scripts/codex-autocoder.sh` - run one Codex autocoder pass
- `scripts/codex-fix-loop.sh` - repeat autocoder passes using shell control
- `scripts/codex-manage-workers.sh` - one manager pass for worker coordination
- `scripts/codex-manage-workers-loop.sh` - repeat manager coordination
- `scripts/codex-monitor-workers.sh` - inspect Codex worker status
- `scripts/codex-monitor-loop.sh` - repeat worker monitoring
- `scripts/codex-stop-loop.sh` - stop Codex loop scripts
- `scripts/start-parallel-codex.sh` - backward-compatible Codex swarm launcher (defaults to tmux, supports cmux)
- `plugins/autocoder/scripts/start-parallel-agents.sh --agent codex` - shared multi-platform swarm launcher

### Shell Alias Snippet

- `scripts/codex-shell-aliases.sh` - source from `~/.zshrc` or `~/.bashrc`
- `scripts/install-codex.sh` - install Codex skills, parallel-agent commands, and alias sourcing
- `scripts/codex-start-parallel.sh` - stable Codex-specific wrapper around the shared parallel launcher

Example:

```bash
source /path/to/agents/scripts/codex-shell-aliases.sh
```

Standalone installer:

```bash
bash /path/to/agents/scripts/install-codex.sh /path/to/target-repo
```

The installer also links the `codex-*.sh` runtime wrappers into the target repo's `scripts/` directory so repo-local commands like `bash scripts/codex-fix-loop.sh` work from the main checkout.

The parallel launchers invoked by `startct` and `startcc` use the shared `agents/scripts/` runtime directly for Codex, so new worktrees can start worker and manager loops even before any repo-local wrapper symlinks are present there.

This defines:

- `startct 3` - start 1 manager + 3 Codex workers in tmux
- `startcc 3` - start 1 manager + 3 Codex workers in cmux
- `joinct` - rejoin the current repo's tmux Codex session
- `joincc` - list/select cmux workspaces

## Basic Usage

### One-pass autocoder run

```bash
bash scripts/codex-autocoder.sh fix
```

When a fix pass makes code changes, the Codex prompt instructs the agent to run the relevant tests, commit the changes, and push the current branch if the repo's git rules allow that push target.

### Continuous fix loop

```bash
bash scripts/codex-fix-loop.sh
```

### Monitor worker status once

```bash
bash scripts/codex-monitor-workers.sh
```

### Continuous manager loop

```bash
bash scripts/codex-monitor-loop.sh 15
```

The manager loop dispatches specific issue numbers to idle Codex worker worktrees by writing worktree-local dispatch files. Idle workers wake early, process the assigned issue, and then return to the general fix loop automatically.

### Stop running loops

```bash
bash scripts/codex-stop-loop.sh all
```

### Start a parallel Codex swarm

```bash
startct 3
# or
startcc 3
```

## Design Notes

- Codex has no built-in equivalent to Claude Code's `/loop` command in this repo's local CLI, so loop behavior is implemented with shell scripts.
- Codex workers run `bash scripts/codex-fix-loop.sh`.
- Codex managers run `bash scripts/codex-manage-workers-loop.sh`.
- Both coordinate through GitHub issue state and labels, parallel to the Claude and Gemini flows.
- Shared scripts remain shared. New Codex scripts only cover runtime gaps that depend on Claude-specific loop or hook behavior.
