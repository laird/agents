# Claude Code Plugin Integration

**Version**: 3.14.0
**Platform**: [Claude Code](https://claude.ai/code)
**Directory**: `.claude-plugin/`

## Overview

Claude Code is Anthropic's official CLI for Claude. This repository provides a plugin marketplace with two plugins (**modernize** and **autocoder**) that extend Claude Code with specialized workflows for software development.

## Directory Structure

```
.claude-plugin/
├── marketplace.json              # Marketplace metadata and plugin registry
└── plugins/
    ├── modernize/
    │   └── plugin.json           # Modernize plugin definition (v3.2.0)
    └── autocoder/
        └── plugin.json           # Autocoder plugin definition (v3.7.3)
```

### Key Files

| File | Purpose |
|------|---------|
| `marketplace.json` | Registry of available plugins, versions, and metadata |
| `plugins/*/plugin.json` | Individual plugin definitions with commands and metadata |

### Plugin Source Locations

The actual plugin implementations (commands, protocols) are in the `plugins/` directory at the repository root:

```
plugins/
├── modernize/
│   ├── commands/          # 6 slash commands (.md protocol files)
│   ├── agents/            # 6 specialist agent definitions
│   └── protocols/         # 10 supporting protocol documents
└── autocoder/
    ├── commands/          # 15 slash commands
    ├── scripts/           # 9 automation scripts
    └── hooks/             # 2 hook scripts (stop-hook)
```

## Installation

### Add the Marketplace

```bash
/plugin add marketplace https://github.com/laird/agents
```

### Install Plugins

```bash
# Install modernize plugin
/plugin install modernize

# Install autocoder plugin
/plugin install autocoder

# Install both
/plugin install modernize autocoder
```

### Verify Installation

```bash
/plugin list
```

## Available Commands

### Modernize Plugin (v3.2.0)

| Command | Description |
|---------|-------------|
| `/assess` | Evaluate modernization readiness (outputs ASSESSMENT.md) |
| `/plan` | Create detailed execution strategy (outputs PLAN.md) |
| `/modernize` | Execute 7-phase modernization with 6 specialist agents |
| `/retro` | Analyze project history for improvements (outputs IMPROVEMENTS.md) |
| `/retro-apply` | Apply retrospective recommendations |
| `/modernize-help` | Show modernize workflow overview and help |

### Autocoder Plugin (v3.7.3)

| Command | Description |
|---------|-------------|
| `/fix` | Autonomous GitHub issue resolution |
| `/fix-loop` | Continuous autonomous resolution loop |
| `/stop-loop` | Stop the continuous loop |
| `/install` | One-time setup for continuous mode (hooks, labels) |
| `/monitor-workers` | Monitor workers, dispatch idle agents, deploy when done |
| `/monitor-loop` | Continuous manager monitoring loop |
| `/review-blocked` | Review and unblock labeled issues |
| `/list-proposals` | View pending AI-generated proposals |
| `/approve-proposal` | Approve a proposal for implementation |
| `/list-needs-design` | List issues needing design work |
| `/list-needs-feedback` | List issues needing feedback |
| `/brainstorm-issue` | Brainstorm design for an issue |
| `/full-regression-test` | Run comprehensive test suite |
| `/improve-test-coverage` | Analyze and improve test coverage |
| `/autocoder-help` | Show autocoder workflow overview and help |

## Configuration

Claude Code reads project-specific settings from `CLAUDE.md` in your project root. The autocoder plugin auto-generates configuration on first run:

```markdown
## Automated Testing & Issue Management

### Regression Test Suite
```bash
npm test
```

### Build Verification
```bash
npm run build
```
```

## How It Works

1. **Marketplace**: The `.claude-plugin/marketplace.json` registers this repo as a plugin source
2. **Plugin Discovery**: Each `plugin.json` defines commands by referencing `.md` files in `plugins/`
3. **Command Execution**: When you run a slash command, Claude Code loads the protocol from the `.md` file
4. **Protocol-Driven**: Each command is a comprehensive protocol document containing:
   - Agent coordination instructions
   - Phase-by-phase workflows
   - Quality gates and success criteria
   - Examples and troubleshooting

## Platform-Specific Features

Features unique to Claude Code (not available on other platforms):

- **Plugin marketplace** with automatic updates
- **Stop hook** for graceful loop termination (`plugins/autocoder/hooks/stop-hook.sh`)
- **Agent tool** for spawning specialized sub-agents (used by `/modernize` and `/fix`)
- **CronCreate** for scheduling recurring tasks (used by `/monitor-loop`)

## Version History

| Version | Changes |
|---------|---------|
| 3.14.0 | Added `/monitor-workers` and `/monitor-loop` for parallel agent swarm management |
| 3.11.1 | Added SRE monitoring, issue decomposition, `/review-blocked`, `/install` |
| 3.4.0 | Renamed `/fix-github` → `/fix`, added design workflow commands and help |
| 3.3.0 | Added proposal system, issue triage, `/list-proposals` command |
| 3.0.0 | Added autocoder plugin with `/fix` |
| 2.6.0 | Applied 5 retrospective improvements |
| 2.5.0 | Added `/retro` and `/retro-apply` commands |

## See Also

- [ANTIGRAVITY.md](./ANTIGRAVITY.md) - Antigravity integration
- [OPENCODE.md](./OPENCODE.md) - OpenCode integration
- [README.md](../README.md) - Main documentation
