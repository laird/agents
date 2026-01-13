# OpenCode Integration

**Version**: 1.5.0
**Platform**: OpenCode
**Directory**: `agents/`

## Overview

OpenCode uses an `agents/` directory structure to define agent configurations, workflows, and specialist definitions. This repository provides two agent configurations: **modernize** and **autocoder**.

## Directory Structure

```
agents/
├── README.md                     # OpenCode agents overview
├── autocoder/                      # Autocoder agent configuration
│   ├── README.md                # Autocoder agent overview
│   ├── agent.md                 # Main agent definition (v1.5.0)
│   └── workflows/               # Autocoder workflows
│       ├── bug-resolution.md    # Bug fixing workflow
│       ├── regression-testing.md # Test suite workflow
│       └── enhancement.md       # Enhancement workflow
└── modernize/                    # Modernize agent configuration
    ├── README.md                # Modernize agent overview
    ├── coordinator.md           # Migration coordinator definition
    ├── specialists/             # Specialist agent definitions
    │   ├── architect.md         # Architect agent
    │   ├── coder.md             # Coder agent
    │   ├── documentation.md     # Documentation agent
    │   ├── security.md          # Security agent
    │   └── tester.md            # Tester agent
    └── workflows/               # Modernize workflows
        └── assessment.md        # Assessment workflow
```

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `autocoder/` | Autonomous GitHub issue resolution agent |
| `modernize/` | Multi-agent modernization orchestration |
| `*/workflows/` | Workflow definitions for each agent |
| `modernize/specialists/` | Individual specialist agent definitions |

## Installation

### Option 1: Copy Directory

Copy the `agents/` directory to your project:

```bash
cp -r /path/to/agents/agents /your/project/
```

### Option 2: Reference

Configure OpenCode to reference this repository's `agents/` directory.

## Available Agents

### Autocoder Agent (v1.5.0)

Autonomous GitHub issue resolution with intelligent testing and quality automation.

**File**: `agents/autocoder/agent.md`

**Capabilities**:
- Issue triage (assigns P0-P3 priority labels)
- Bug fixing workflow orchestration
- Regression testing with failure analysis
- Proposal system (creates enhancements for human approval)
- Approved enhancement implementation
- Continuous loop execution

**Workflows**:

| Workflow | Description |
|----------|-------------|
| `bug-resolution.md` | Fix prioritized bugs |
| `regression-testing.md` | Run comprehensive tests |
| `enhancement.md` | Implement approved enhancements |

### Modernize Agent (v1.0)

Multi-agent modernization orchestration for legacy software.

**Files**:
- `agents/modernize/coordinator.md` - Main coordinator
- `agents/modernize/specialists/*.md` - Specialist agents

**Specialists**:

| Specialist | Role |
|------------|------|
| `architect.md` | Technology decisions, ADR creation |
| `coder.md` | Implementation and fixes |
| `documentation.md` | User-facing guides |
| `security.md` | Vulnerability scanning |
| `tester.md` | Comprehensive testing |

**Workflows**:

| Workflow | Description |
|----------|-------------|
| `assessment.md` | Evaluate modernization viability |

## Agent Definition Format

Each agent is defined in a Markdown file with YAML frontmatter:

```yaml
---
name: autocoder
version: 1.5.0
type: agent
category: automation
---

# Agent Name

**Version**: 1.5.0
**Category**: Category
**Type**: Agent Type

## Description
...

## Capabilities
- Capability 1
- Capability 2

## Responsibilities
- Responsibility 1
- Responsibility 2

## Required Tools
- Tool 1
- Tool 2

## Workflow Phases
### Phase 1
...
```

## Autocoder Agent Details (v1.5.0)

### Workflow Phases

1. **Triage Phase** - Review unprioritized issues, assign P0-P3 labels
2. **Bug Fixing Phase** - Process highest priority bugs
3. **Regression Testing Phase** - Run full test suite
4. **Enhancement Phase** - Implement approved enhancements only
5. **Proposal Phase** - Create proposals for human review
6. **Continuous Loop** - Never stop until interrupted

### Proposal System

The autocoder agent creates enhancement proposals that require human approval:

- **Proposals** are tagged with `proposal` label
- **NOT auto-implemented** - requires human review
- **Approval**: Remove `proposal` label to allow implementation
- **Feedback**: Comment on issue for refinement
- **Rejection**: Close issue with reason

### Priority Labels

| Label | Severity |
|-------|----------|
| P0 | Critical - System down, security vulnerability |
| P1 | High - Major feature broken |
| P2 | Medium - Partial impact, workaround exists |
| P3 | Low - Minor, cosmetic |

## Version History

| Version | Changes |
|---------|---------|
| 1.5.0 | Added proposal system, issue triage, workflow phases |
| 1.0 | Initial OpenCode support |

## See Also

- [CLAUDE-CODE.md](./CLAUDE-CODE.md) - Claude Code integration
- [ANTIGRAVITY.md](./ANTIGRAVITY.md) - Antigravity integration
- [README.md](../README.md) - Main documentation
