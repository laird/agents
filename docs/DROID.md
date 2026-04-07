# Droid Integration

**Platform**: [Factory Droid](https://docs.factory.ai/)
**Directories**: `.factory/`, `.factory-plugin/`, and `scripts/`

## Overview

Droid is Factory's AI coding agent CLI. This repository provides full Droid support through:

- `.factory-plugin/` for plugin marketplace integration
- `.factory/skills/` for Droid-native skill entrypoints
- `.factory/droids/` for 6 specialist custom droids (subagents)
- `.factory/commands/` for slash commands (linked from `plugins/`)
- `.factory/settings.json` for hooks (stop hook for continuous operation)
- `scripts/droid-*.sh` for loop wrappers and runtime helpers

Droid support is additive. It does not replace or reinterpret:

- Claude Code plugins in `plugins/`
- Antigravity / Gemini assets in `.agent/`
- Codex assets in `skills/` and `scripts/codex-*.sh`

## Directory Structure

```
.factory/
├── settings.json                 # Hooks configuration (stop hook)
├── skills/
│   ├── autocoder/
│   │   ├── SKILL.md             # Autocoder skill definition
│   │   └── references/
│   │       ├── command-mapping.md
│   │       └── workflow-map.md
│   └── modernize/
│       ├── SKILL.md             # Modernize skill definition
│       └── references/
│           ├── lifecycle.md
│           └── source-map.md
├── droids/
│   ├── architect.md             # Architectural decisions and ADRs
│   ├── coder.md                 # Code implementation and migration
│   ├── documentation.md         # Documentation and changelogs
│   ├── migration-coordinator.md # Multi-stage orchestration
│   ├── security.md              # Vulnerability scanning and remediation
│   └── tester.md                # Testing and quality assurance
└── commands/                     # Symlinked from plugins/ (created by installer)

.factory-plugin/
├── marketplace.json             # Marketplace metadata (2 plugins)
└── plugins/
    ├── modernize/
    │   └── plugin.json          # Modernize plugin definition
    └── autocoder/
        └── plugin.json          # Autocoder plugin definition

scripts/
├── droid-autocoder.sh           # Run one Droid autocoder pass
├── droid-fix-loop.sh            # Repeat autocoder passes using shell control
├── droid-manage-workers.sh      # One manager pass for worker coordination
├── droid-manage-workers-loop.sh # Repeat manager coordination
├── droid-monitor-workers.sh     # Inspect Droid worker status
├── droid-monitor-loop.sh        # Repeat worker monitoring
├── droid-stop-loop.sh           # Stop Droid loop scripts
├── droid-start-parallel.sh      # Start a tmux/cmux-based Droid worker swarm
├── droid-shell-aliases.sh       # Shell aliases for swarm startup
└── install-droid.sh             # Install Droid skills, droids, and aliases
```

## Installation

### Option 1: Plugin Marketplace (Recommended)

Add this repository as a plugin marketplace in Droid:

```bash
# From the droid CLI
/plugins
# Then: Marketplaces tab → Add new marketplace → https://github.com/laird/agents

# Or via CLI
droid plugin marketplace add https://github.com/laird/agents
```

Install plugins:

```bash
droid plugin install modernize@plugin-marketplace
droid plugin install autocoder@plugin-marketplace
```

### Option 2: Standalone Installer

Run the installer to set up skills, droids, commands, and runtime scripts:

```bash
bash /path/to/agents/scripts/install-droid.sh /path/to/target-repo
```

Example:

```bash
bash /Users/Laird.Popkin/src/agents/scripts/install-droid.sh /Users/Laird.Popkin/src/my-project
```

The installer:

- Symlinks `.factory/skills/autocoder` and `.factory/skills/modernize` into the target repo
- Symlinks `.factory/droids/*.md` into the target repo
- Symlinks all plugin commands into `.factory/commands/`
- Symlinks `droid-start-parallel`, `start-parallel`, `join-parallel`, `end-parallel`, and `stop-parallel` into `~/.local/bin`
- Symlinks the `droid-*.sh` runtime wrappers into the target repo's `scripts/` directory
- Appends `source .../droid-shell-aliases.sh` to your shell rc file if needed

### Option 3: Copy `.factory/` Directory

```bash
cp -r /path/to/agents/.factory /your/project/
```

### Shell Aliases

After installation, source the aliases:

```bash
source /path/to/agents/scripts/droid-shell-aliases.sh
```

This defines:

- `startdt 3` - start 1 manager + 3 Droid workers in tmux
- `startdc 3` - start 1 manager + 3 Droid workers in cmux
- `joindt` - rejoin the current repo's tmux Droid session
- `joindc` - list/select cmux workspaces

## Current Droid Assets

### Skills

Skills are loaded automatically by Droid when relevant to the current task, or invoked explicitly via `/skill-name`.

- `.factory/skills/autocoder/` - autonomous GitHub issue workflow
- `.factory/skills/modernize/` - modernization assess/plan/execute workflow

### Custom Droids (Subagents)

Custom droids are invoked via the Task tool for specialized work:

| Droid | Role |
|-------|------|
| `architect` | Technology decisions, ADR creation (MADR 3.0.0) |
| `coder` | Implementation, migration, and fixes |
| `documentation` | CHANGELOGs, migration guides, release notes |
| `migration-coordinator` | Multi-stage project orchestration |
| `security` | CVE scanning, vulnerability remediation |
| `tester` | 6-phase testing and quality gate enforcement |

### Hooks

The stop hook in `.factory/settings.json` enables continuous operation (fix-loop). It runs the same `plugins/autocoder/hooks/stop-hook.sh` used by Claude Code.

### Runtime Scripts

```bash
# Run one autocoder pass
bash scripts/droid-autocoder.sh fix

# Run one autocoder pass for a specific issue
bash scripts/droid-autocoder.sh fix 42

# Run the continuous fix loop
bash scripts/droid-fix-loop.sh

# Run the manager monitor loop
bash scripts/droid-monitor-loop.sh 15

# Monitor worker status once
bash scripts/droid-monitor-workers.sh

# Stop running loops
bash scripts/droid-stop-loop.sh all

# Start a parallel Droid swarm
bash scripts/droid-start-parallel.sh tmux 3
```

## Available Commands

When installed as a plugin or via the installer, these slash commands are available:

### Modernize Plugin

| Command | Description |
|---------|-------------|
| `/assess` | Evaluate modernization readiness (outputs ASSESSMENT.md) |
| `/plan` | Create detailed execution strategy (outputs PLAN.md) |
| `/modernize` | Execute 7-phase modernization with 6 specialist agents |
| `/retro` | Analyze project history for improvements (outputs IMPROVEMENTS.md) |
| `/retro-apply` | Apply retrospective recommendations |
| `/modernize-help` | Overview of modernization workflow |

### Autocoder Plugin

| Command | Description |
|---------|-------------|
| `/fix` | Autonomous GitHub issue resolution |
| `/fix-loop` | Continuous autonomous resolution |
| `/stop-loop` | Stop the continuous loop |
| `/monitor-workers` | Monitor workers, dispatch idle agents |
| `/review-blocked` | Review and unblock labeled issues |
| `/list-proposals` | View pending AI-generated proposals |
| `/approve-proposal` | Approve a proposal for implementation |
| `/list-needs-design` | List issues needing design work |
| `/list-needs-feedback` | List issues needing feedback |
| `/brainstorm-issue` | Brainstorm design for an issue |
| `/full-regression-test` | Run comprehensive test suite |
| `/improve-test-coverage` | Analyze and improve test coverage |
| `/install` | Install all autocoder plugin components |
| `/autocoder-help` | Overview of autonomous coding workflow |

## Basic Usage

### Interactive Mode

```bash
cd /path/to/your/project
droid
```

Then use slash commands:

```
/fix              # Fix highest priority issue
/assess           # Assess modernization readiness
/fix-loop         # Run continuously
```

### Headless Mode (droid exec)

```bash
# One-pass autocoder run
bash scripts/droid-autocoder.sh fix

# Fix a specific issue
bash scripts/droid-autocoder.sh fix 42
```

### Continuous Fix Loop

```bash
bash scripts/droid-fix-loop.sh
```

### Parallel Worker Swarm

```bash
startdt 3    # 1 manager + 3 workers in tmux
startdc 3    # 1 manager + 3 workers in cmux
```

### Monitor Worker Status

```bash
bash scripts/droid-monitor-workers.sh
```

### Stop Running Loops

```bash
bash scripts/droid-stop-loop.sh all
```

## Design Notes

- Droid uses `droid exec --auto high` for headless autonomous operation (equivalent to Codex's `codex exec --full-auto`).
- Loop behavior is implemented with shell scripts (same approach as Codex), not with Droid-specific hook mechanisms.
- Workers run `bash scripts/droid-fix-loop.sh`.
- Managers run `bash scripts/droid-manage-workers-loop.sh`.
- Both coordinate through GitHub issue state and labels, parallel to the Claude, Gemini, and Codex flows.
- Shared scripts remain shared. New Droid scripts only cover runtime gaps.
- The `.factory-plugin/` marketplace manifest enables Droid's plugin system to discover and install the plugins.
- Skills in `.factory/skills/` are the Droid-native equivalent of Codex skills in `skills/`.
- Custom droids in `.factory/droids/` are the Droid equivalent of Claude Code agents in `plugins/modernize/agents/`.

## See Also

- [CLAUDE-CODE.md](./CLAUDE-CODE.md) - Claude Code integration
- [ANTIGRAVITY.md](./ANTIGRAVITY.md) - Antigravity integration
- [CODEX.md](./CODEX.md) - Codex integration
- [README.md](../README.md) - Main documentation
