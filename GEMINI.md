# GEMINI.md

This file provides guidance to Gemini-based AI tools (including Antigravity) when working with code in this repository.

## Repository Overview

This is the **Modernize** framework - a production-validated system providing protocols, specialized agents, and automation for systematic AI-assisted software modernization and development. The framework supports a complete workflow: assess → plan → execute → improve.

**Key Characteristics**:
- Protocol-driven architecture where each workflow is a comprehensive protocol document
- Multi-agent coordination system with 6 specialized agents
- Originally created for .NET Framework migrations but universally applicable
- Emphasizes continuous improvement through retrospective analysis

## Issue Management

This project uses a pluggable issue source. Run the equivalent of `/set-issue-source` before running autonomous agents for the first time. Issue state is shared across all agents via `.issues/` at the repo root (file backend), via GitHub Issues (github backend), via a Jira project (jira backend), or via Azure DevOps work items (ado backend) — whichever is configured in `.autocoder.json`.

Each backend is a self-contained script implementing the same 9-verb contract (list, get, update, comment, close, create, claim, release, any-claimable): `issues-file.py`, `issues-gh.sh`, `issues-jira.sh`, and `issues-ado.sh`. Non-secret connection settings live in `.autocoder.json` and credentials come from the environment — secrets are never committed. Jira reads `baseUrl`/`project` from the `jira` object (`JIRA_EMAIL` + `JIRA_API_TOKEN`, or `JIRA_AUTH_HEADER`); Azure DevOps reads `orgUrl`/`project` from the `ado` object (`ADO_PAT`), mapping labels to work-item Tags. See `docs/jira-setup.md` and `docs/ado-setup.md`.

## Parallel Maintenance Requirement

**CRITICAL**: This repository maintains two parallel implementations that MUST stay in sync:

| Platform | Directory | Guidance File |
|----------|-----------|---------------|
| **Antigravity** | `.agent/` | `GEMINI.md` (this file) |
| **Claude Code** | `plugins/` | `CLAUDE.md` |

**When modifying any workflow, rule, or protocol:**

1. **Always update BOTH versions** - Changes to one must be mirrored to the other
2. **Check the mapping**:
   - `.agent/workflows/*.md` ↔ `plugins/autocoder/commands/*.md`
   - `.agent/rules/*.md` ↔ `plugins/modernize/agents/*.md`
3. **Verify parity** after changes: Both should have identical functionality
4. **Test both platforms** if possible before committing

**Key parallel files:**

| Workflow | Antigravity | Claude Code |
|----------|-------------|-------------|
| `/improve-test-coverage` | `.agent/workflows/improve-test-coverage.md` | `plugins/autocoder/commands/improve-test-coverage.md` |
| `/dev` | `.agent/workflows/dev.md` | `plugins/autocoder/commands/dev.md` |
| `/dev-loop` | `.agent/workflows/dev-loop.md` | `plugins/autocoder/commands/dev-loop.md` |
| `/fix`, `/fix-loop` (aliases) | `.agent/workflows/fix.md`, `fix-loop.md` | `plugins/autocoder/commands/fix.md`, `fix-loop.md` |
| `/monitor-workers` | `.agent/workflows/monitor-workers.md` | `plugins/autocoder/commands/monitor-workers.md` |
| `/monitor-loop` | `.agent/workflows/monitor-loop.md` | `plugins/autocoder/commands/monitor-loop.md` |
| `/full-regression-test` | `.agent/workflows/full-regression-test.md` | `plugins/autocoder/commands/full-regression-test.md` |
| `/review-blocked` | `.agent/workflows/review-blocked.md` | `plugins/autocoder/commands/review-blocked.md` |
| `/install` | `.agent/workflows/install.md` | `plugins/autocoder/commands/install.md` |

**Key parallel scripts:**

| Script | Antigravity | Claude Code |
|--------|-------------|-------------|
| `start-parallel-agents.sh` | `.agent/scripts/start-parallel-agents.sh` | `plugins/autocoder/scripts/start-parallel-agents.sh` |
| `join-parallel-agents.sh` | `.agent/scripts/join-parallel-agents.sh` | `plugins/autocoder/scripts/join-parallel-agents.sh` |
| `fetch-blocked-issues.sh` | `.agent/scripts/fetch-blocked-issues.sh` | `plugins/autocoder/scripts/fetch-blocked-issues.sh` |
| `add-blocking-label.sh` | `.agent/scripts/add-blocking-label.sh` | `plugins/autocoder/scripts/add-blocking-label.sh` |
| `approve-blocked-issue.sh` | `.agent/scripts/approve-blocked-issue.sh` | `plugins/autocoder/scripts/approve-blocked-issue.sh` |
| `reject-blocked-issue.sh` | `.agent/scripts/reject-blocked-issue.sh` | `plugins/autocoder/scripts/reject-blocked-issue.sh` |

## Workflows

Available workflows in `.agent/workflows/`:

### Primary Workflow Commands

```bash
# 1. Assessment - Evaluate modernization readiness
/assess
# Output: ASSESSMENT.md with viability analysis across 8 dimensions

# 2. Planning - Create detailed execution strategy
/plan
# Output: PLAN.md with phase breakdown, timeline, resource allocation

# 3. Execution - Orchestrate multi-agent modernization
/modernize
# Coordinates 6 specialist agents through 7 phases
```

### Continuous Improvement Commands

```bash
# 4. Retrospective - Analyze project history for improvements
/retro
# Output: IMPROVEMENTS.md with 3-5 evidence-based recommendations

# 5. Apply Improvements - Implement retrospective findings
/retro-apply
# Updates workflows, protocols, and automation based on IMPROVEMENTS.md
```

### Autocoder Workflows

```bash
# Autonomous issue resolution
/dev

# Continuous issue resolution loop
/dev-loop

# Test coverage improvement
/improve-test-coverage

# Full regression testing
/full-regression-test
```

**Recommended Workflow**: `/assess` → `/plan` → `/modernize` → `/retro` → `/retro-apply`

## Architecture

### Directory Structure

```
.agent/
├── README.md                     # Configuration overview
├── protocols/                    # Agent behavior protocols
│   ├── adr-lifecycle.md         # ADR lifecycle (7 stages)
│   ├── testing-protocol.md      # 6-phase testing protocol
│   └── ...                      # Other protocols
├── rules/                        # Agent-specific rules
│   ├── architect.md             # Architect agent rules
│   ├── coder.md                 # Coder agent rules
│   ├── tester.md                # Tester agent rules
│   └── ...                      # Other agent rules
├── workflows/                    # Executable workflows
│   ├── dev.md            # Autonomous issue resolution (fix.md = alias)
│   ├── improve-test-coverage.md # Coverage improvement
│   └── ...                      # Other workflows
└── scripts/
    └── append-to-history.sh     # Log to HISTORY.md
```

### Multi-Agent Coordination System

**6 Specialized Agents** work together through protocol-defined coordination:

1. **Migration Coordinator** - Strategic oversight, agent coordination
2. **Security Agent** - CVE scanning, vulnerability remediation
3. **Architect Agent** - Technology decisions, ADR creation
4. **Coder Agent** - Implementation and migration
5. **Tester Agent** - 6-phase testing protocol
6. **Documentation Agent** - HISTORY.md logging, guides

### Key Quality Gates

- **Security**: Score ≥45/100 before migration starts
- **Build**: 100% success before next stage
- **Tests**: 100% pass rate before proceeding
- **Issues**: All P0/P1 resolved before release

## Test Coverage Report

This repository uses a persistent `test-coverage.md` report for efficient coverage tracking:

- **Location**: `test-coverage.md` in project root
- **Purpose**: Track coverage by functional area without re-running full analysis
- **Update**: After adding tests, update the relevant section
- **Refresh**: Use `/improve-test-coverage --refresh` to regenerate

## Important Protocols

### Testing Protocol (6 Phases)

All code changes must pass:
1. Unit Tests
2. Integration Tests
3. Build Tests
4. Smoke Tests
5. Security Tests
6. Performance Tests

**Location**: `.agent/protocols/testing-protocol.md`

### Agent Logging Protocol

All agent work is logged to `HISTORY.md` using:
```bash
./.agent/scripts/append-to-history.sh "<title>" "<details>" "<context>" "<impact>"
```

## Parallel Agent System

### Setup and Coordination

Antigravity supports parallel agent coordination through git worktrees and workspace management:

**Start parallel agents:**
```bash
bash .agent/scripts/start-parallel-agents.sh [num_agents]
# Creates worktrees, generates config, attempts to launch Antigravity
```

**Join existing session:**
```bash
bash .agent/scripts/join-parallel-agents.sh
# Reads config, shows status, attempts to reopen workspaces
```

**How it works:**
- Creates N-1 git worktrees (one coordinator stays in main repo)
- Detects if `.agent/` is a symlink and replicates to each worktree
- Generates `.agent/parallel-workspaces.json` with workspace config
- Attempts to launch Antigravity and open workspaces
- Agents coordinate through GitHub issues and labels (working, needs-approval, P0-P3, etc.)

**Key difference from Claude Code:**
- No `CLAUDE_CODE_TASK_LIST_ID` environment variable
- Coordination is purely through GitHub API (labels, comments)
- No tmux - uses Antigravity GUI workspace model

### Installation Into Projects

Use `/install` workflow to install framework into target projects:

**Option 1: Symlink (Recommended)**
- Stays updated with framework improvements
- `git pull` in framework repo updates all linked projects
- Symlinks automatically replicated to worktrees by `start-parallel-agents.sh`

**Option 2: Copy (Custom)**
- Independent snapshot for customization
- No automatic updates
- Full control over protocols/rules

## References

- **MADR 3.0.0**: https://adr.github.io/madr/ - ADR format specification
- **Keep a Changelog**: https://keepachangelog.com/ - CHANGELOG format
- **Repository**: https://github.com/laird/agents
- **Antigravity Docs**: See `docs/ANTIGRAVITY.md`
