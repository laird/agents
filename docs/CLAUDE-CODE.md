# Claude Code Plugin Integration

**Version**: 3.3.0
**Platform**: [Claude Code](https://claude.ai/code)
**Directory**: `.claude-plugin/`

## Overview

Claude Code is Anthropic's official CLI for Claude. This repository provides a plugin marketplace with two plugins (**modernize** and **autofix**) that extend Claude Code with specialized workflows for software development.

## Directory Structure

```
.claude-plugin/
├── marketplace.json              # Marketplace metadata and plugin registry
└── plugins/
    ├── modernize/
    │   └── plugin.json           # Modernize plugin definition (v3.1.0)
    └── autofix/
        └── plugin.json           # Autofix plugin definition (v1.5.0)
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
│   ├── commands/          # 5 slash commands (.md protocol files)
│   ├── agents/            # 6 specialist agent definitions
│   └── protocols/         # 10 supporting protocol documents
└── autofix/
    ├── commands/          # 4 slash commands
    └── scripts/           # Automation scripts
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

# Install autofix plugin
/plugin install autofix

# Install both
/plugin install modernize autofix
```

### Verify Installation

```bash
/plugin list
```

## Available Commands

### Modernize Plugin (v3.1.0)

| Command | Description |
|---------|-------------|
| `/assess` | Evaluate modernization readiness (outputs ASSESSMENT.md) |
| `/plan` | Create detailed execution strategy (outputs PLAN.md) |
| `/modernize` | Execute 7-phase modernization with 6 specialist agents |
| `/retro` | Analyze project history for improvements (outputs IMPROVEMENTS.md) |
| `/retro-apply` | Apply retrospective recommendations |

### Autofix Plugin (v1.5.0)

| Command | Description |
|---------|-------------|
| `/fix-github` | Autonomous GitHub issue resolution |
| `/full-regression-test` | Run comprehensive test suite |
| `/improve-test-coverage` | Analyze and improve test coverage |
| `/list-proposals` | View pending AI-generated proposals |

## Configuration

Claude Code reads project-specific settings from `CLAUDE.md` in your project root. The autofix plugin auto-generates configuration on first run:

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

## Version History

| Version | Changes |
|---------|---------|
| 3.3.0 | Added proposal system, issue triage, `/list-proposals` command |
| 3.2.0 | Added `/improve-test-coverage` command |
| 3.0.0 | Added autofix plugin with `/fix-github` |
| 2.6.0 | Applied 5 retrospective improvements |
| 2.5.0 | Added `/retro` and `/retro-apply` commands |

## See Also

- [ANTIGRAVITY.md](./ANTIGRAVITY.md) - Antigravity integration
- [OPENCODE.md](./OPENCODE.md) - OpenCode integration
- [README.md](../README.md) - Main documentation
