# Antigravity Integration

**Version**: 2.1.0
**Platform**: Antigravity Agent Engine
**Directory**: `.agent/`

## Overview

Antigravity is an agent engine that uses a `.agent/` directory structure to define rules, protocols, and workflows. This repository is **Antigravity-native** and includes all necessary configuration for immediate use.

## Directory Structure

```text
.agent/
├── README.md                     # Configuration overview
├── protocols/                    # Agent behavior protocols
│   ├── 00-PROTOCOL-INDEX.md     # Protocol index and navigation
│   ├── adr-lifecycle.md         # ADR lifecycle (7 stages)
│   ├── agent-logging.md         # HISTORY.md logging protocol
│   ├── agents-overview.md       # Agent coordination overview
│   ├── documentation-plan.md    # Documentation planning
│   ├── documentation-protocol.md # Documentation standards
│   ├── incremental-documentation.md # Status marker system
│   ├── protocols-overview.md    # Protocol index
│   ├── security-scanning-protocol.md # Security scanning
│   ├── testing-protocol.md      # 6-phase testing protocol
│   └── GENERIC-MIGRATION-PLANNING-GUIDE.md # Migration planning
├── rules/                        # Agent-specific rules
│   ├── architect.md             # Architect agent rules
│   ├── coder.md                 # Coder agent rules
│   ├── documentation.md         # Documentation agent rules
│   ├── migration-coordinator.md # Coordinator agent rules
│   ├── security.md              # Security agent rules
│   └── tester.md                # Tester agent rules
├── workflows/                    # Executable workflows
│   ├── assess.md                # Assessment workflow
│   ├── plan.md                  # Planning workflow
│   ├── modernize.md             # Modernization workflow
│   ├── retro.md                 # Retrospective workflow
│   ├── retro-apply.md           # Apply improvements workflow
│   ├── fix.md            # Autonomous issue resolution (v2.0.0)
│   ├── fix-loop.md       # Infinite loop with stop hook (v2.0.0)
│   ├── install-stop-hook.md     # Stop hook installation (v2.0.0)
│   ├── list-proposals.md        # List pending proposals (v2.0.0)
│   ├── full-regression-test.md  # Regression testing (v2.0.0)
│   ├── improve-test-coverage.md # Coverage improvement (v2.0.0)
│   └── debug-atomic.md          # Atomic debugging
└── scripts/
    ├── append-to-history.sh     # Log to HISTORY.md
    └── watchdog-fix.sh   # (Experimental) Watchdog script
```

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `protocols/` | Define agent behavior standards and methodologies |
| `rules/` | Agent-specific instructions and capabilities |
| `workflows/` | Executable workflow definitions (like slash commands) |
| `scripts/` | Helper scripts for automation |

## Installation

### Option 1: Copy Directory

Copy the `.agent/` directory to your project root:

```bash
cp -r /path/to/agents/.agent /your/project/
```

### Option 2: Symlink (Development)

```bash
ln -s /path/to/agents/.agent /your/project/.agent
```

### Requirements

- **Bash environment**: Required for shell scripts
- **Windows**: Use Git Bash or WSL

## Available Workflows

### Modernization Workflows

| Workflow | Description |
|----------|-------------|
| `assess.md` | Evaluate modernization viability |
| `plan.md` | Create execution strategy |
| `modernize.md` | Execute multi-phase modernization |
| `retro.md` | Analyze project for improvements |
| `retro-apply.md` | Apply retrospective findings |

### Autocoder Workflows (v2.0.0)

| Workflow | Description |
|----------|-------------|
| `fix.md` | Autonomous issue resolution with triage and proposals |
| `fix-loop.md` | Infinite loop wrapper with stop hook |
| `monitor-workers.md` | Check worker status, stale locks, and dispatch opportunities |
| `monitor-loop.md` | Continuous manager loop for worker coordination |
| `install.md` | Install stop hook, parallel scripts, and aliases |
| `stop-loop.md` | Stop the continuous fix loop |
| `review-blocked.md` | Interactively review and unblock blocked issues |
| `list-proposals.md` | Display pending AI-generated proposals |
| `approve-proposal.md` | Approve a proposal for implementation |
| `list-needs-design.md` | List issues requiring design work |
| `list-needs-feedback.md` | List issues requiring human feedback |
| `brainstorm-issue.md` | Brainstorm approaches for a blocked issue |
| `full-regression-test.md` | Comprehensive test suite execution |
| `improve-test-coverage.md` | Coverage analysis and improvement |
| `autocoder-help.md` | Show the autocoder command overview |

### Utility Workflows

| Workflow | Description |
|----------|-------------|
| `debug-atomic.md` | Atomic debugging methodology |

## Agent Rules

The `rules/` directory contains behavior definitions for 6 specialist agents:

| Agent | Role |
|-------|------|
| `architect.md` | Technology decisions, ADR creation |
| `coder.md` | Implementation and fixes |
| `documentation.md` | User-facing guides and changelogs |
| `migration-coordinator.md` | Multi-stage orchestration |
| `security.md` | Vulnerability scanning |
| `tester.md` | Comprehensive testing |

## Scripts

### append-to-history.sh

Logs agent activity to `HISTORY.md`:

```bash
./scripts/append-to-history.sh "Title" "Details" "Context" "Impact"
```

### watchdog-fix.sh

> **Warning**: Experimental and currently non-functional.

Intended for continuous monitoring of GitHub issues.

## Protocols

Protocols define standardized methodologies:

- **ADR Lifecycle**: 7-stage architectural decision process
- **Testing Protocol**: 6-phase testing (Unit → Integration → Build → Smoke → Security → Performance)
- **Agent Logging**: Structured HISTORY.md entries
- **Security Scanning**: CVE scanning and scoring
- **Documentation**: Incremental status markers (⚠️ → ✅ → 📝)

## Version History

| Version | Changes |
|---------|---------|
| 2.0.0 | Full Claude Code parity: expanded fix (~1200 lines), added fix-loop, install-stop-hook |
| 1.5.0 | Added proposal system, issue triage, list-proposals workflow |
| 1.0 | Initial Antigravity support |

## See Also

- [CLAUDE-CODE.md](./CLAUDE-CODE.md) - Claude Code integration
- [OPENCODE.md](./OPENCODE.md) - OpenCode integration
- [README.md](../README.md) - Main documentation
