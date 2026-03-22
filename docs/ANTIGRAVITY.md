# Antigravity Integration

**Version**: 3.14.0
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
│   ├── modernize-help.md        # Modernize help
│   ├── fix.md                   # Autonomous issue resolution
│   ├── fix-loop.md              # Continuous autonomous resolution
│   ├── stop-loop.md             # Stop the continuous loop
│   ├── install.md               # Install all plugin components
│   ├── monitor-workers.md       # Monitor workers, dispatch idle agents
│   ├── monitor-loop.md          # Continuous manager monitoring loop
│   ├── review-blocked.md        # Review and unblock labeled issues
│   ├── list-proposals.md        # List pending proposals
│   ├── approve-proposal.md      # Approve a proposal
│   ├── list-needs-design.md     # List issues needing design
│   ├── list-needs-feedback.md   # List issues needing feedback
│   ├── brainstorm-issue.md      # Brainstorm design for an issue
│   ├── full-regression-test.md  # Regression testing
│   ├── improve-test-coverage.md # Coverage improvement
│   ├── autocoder-help.md        # Autocoder help
│   └── debug-atomic.md          # Atomic debugging (Antigravity-only)
├── hooks/
│   └── stop-hook.sh             # Stop hook for infinite loops
└── scripts/
    ├── append-to-history.sh     # Log to HISTORY.md
    ├── start-parallel-agents.sh # Start parallel agent workers
    ├── join-parallel-agents.sh  # Wait for parallel agents to finish
    ├── stop-parallel-agents.sh  # Stop parallel agent workers
    ├── end-parallel-agents.sh   # End and clean up parallel agents
    ├── fetch-blocked-issues.sh  # Fetch issues with blocking labels
    ├── add-blocking-label.sh    # Add blocking label to an issue
    ├── approve-blocked-issue.sh # Approve a blocked issue
    ├── reject-blocked-issue.sh  # Reject a blocked issue
    ├── watchdog-fix.sh          # (Experimental) Watchdog script
    ├── watchdog-fix-github.sh   # (Experimental) GitHub-specific watchdog
    └── watchdog-fix-nextgen.sh  # (Experimental) Next-gen watchdog
```

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `protocols/` | Define agent behavior standards and methodologies |
| `rules/` | Agent-specific instructions and capabilities |
| `workflows/` | Executable workflow definitions (like slash commands) |
| `scripts/` | Helper scripts for automation |
| `hooks/` | Event-driven scripts (stop hook for loop termination) |

## Installation

### Option 1: One-Liner Install

```bash
curl -sSL https://raw.githubusercontent.com/laird/agents/main/scripts/install.sh | bash
```

### Option 2: Copy Directory

Copy the `.agent/` directory to your project root:

```bash
cp -r /path/to/agents/.agent /your/project/
```

### Option 3: Symlink (Development)

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
| `modernize-help.md` | Show modernize workflow help |

### Autocoder Workflows

| Workflow | Description |
|----------|-------------|
| `fix.md` | Autonomous issue resolution with triage and proposals |
| `fix-loop.md` | Continuous autonomous resolution loop |
| `stop-loop.md` | Stop the continuous loop |
| `install.md` | Install all plugin components |
| `monitor-workers.md` | Monitor workers, dispatch idle agents, deploy |
| `monitor-loop.md` | Continuous manager monitoring loop |
| `review-blocked.md` | Review and unblock labeled issues |
| `list-proposals.md` | Display pending AI-generated proposals |
| `approve-proposal.md` | Approve a proposal for implementation |
| `list-needs-design.md` | List issues needing design work |
| `list-needs-feedback.md` | List issues needing feedback |
| `brainstorm-issue.md` | Brainstorm design for an issue |
| `full-regression-test.md` | Comprehensive test suite execution |
| `improve-test-coverage.md` | Coverage analysis and improvement |
| `autocoder-help.md` | Show autocoder workflow help |

### Utility Workflows

| Workflow | Description |
|----------|-------------|
| `debug-atomic.md` | Atomic debugging methodology (Antigravity-only) |

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

### Core Scripts

| Script | Purpose |
|--------|---------|
| `append-to-history.sh` | Log agent activity to HISTORY.md |
| `start-parallel-agents.sh` | Start parallel agent workers |
| `join-parallel-agents.sh` | Wait for parallel agents to finish |
| `stop-parallel-agents.sh` | Stop parallel agent workers |
| `end-parallel-agents.sh` | End and clean up parallel agents |
| `fetch-blocked-issues.sh` | Fetch issues with blocking labels |
| `add-blocking-label.sh` | Add blocking label to an issue |
| `approve-blocked-issue.sh` | Approve a blocked issue |
| `reject-blocked-issue.sh` | Reject a blocked issue |

### Experimental Scripts

| Script | Purpose |
|--------|---------|
| `watchdog-fix.sh` | Continuous monitoring of GitHub issues |
| `watchdog-fix-github.sh` | GitHub-specific watchdog variant |
| `watchdog-fix-nextgen.sh` | Next-generation watchdog variant |

> **Warning**: Watchdog scripts are experimental and may not work in all environments.

## Platform-Specific Features

Features unique to or different in Antigravity:

- **`debug-atomic.md`** workflow (not available in Claude Code)
- **Watchdog scripts** for continuous monitoring (experimental)
- **`GENERIC-MIGRATION-PLANNING-GUIDE.md`** protocol (additional migration guidance)
- **No plugin marketplace** - install by copying the `.agent/` directory

## Protocols

Protocols define standardized methodologies:

- **ADR Lifecycle**: 7-stage architectural decision process
- **Testing Protocol**: 6-phase testing (Unit → Integration → Build → Smoke → Security → Performance)
- **Agent Logging**: Structured HISTORY.md entries
- **Security Scanning**: CVE scanning and scoring
- **Documentation**: Incremental status markers
- **Migration Planning**: Generic migration planning guide

## Version History

| Version | Changes |
|---------|---------|
| 3.14.0 | Full parity with Claude Code: added monitor-workers, monitor-loop, all autocoder workflows |
| 2.1.0 | Added design workflow commands, help workflows |
| 2.0.0 | Full Claude Code parity: expanded fix, added fix-loop, install |
| 1.5.0 | Added proposal system, issue triage, list-proposals workflow |
| 1.0 | Initial Antigravity support |

## See Also

- [CLAUDE-CODE.md](./CLAUDE-CODE.md) - Claude Code integration
- [OPENCODE.md](./OPENCODE.md) - OpenCode integration
- [README.md](../README.md) - Main documentation
