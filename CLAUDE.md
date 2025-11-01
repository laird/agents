# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is the **Modernize** Claude Code plugin - a production-validated framework providing protocols, specialized agents, and automation for systematic AI-assisted software modernization and development. The plugin supports a complete workflow: assess → plan → execute → improve.

**Key Characteristics**:
- Protocol-driven architecture where each command is a comprehensive protocol document
- Multi-agent coordination system with 6 specialized agents
- Originally created for .NET Framework migrations but universally applicable
- Emphasizes continuous improvement through retrospective analysis

## Commands

This plugin provides 5 slash commands that are comprehensive protocol documents:

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
# Requires: Optional ASSESSMENT.md and PLAN.md for best results
```

### Continuous Improvement Commands

```bash
# 4. Retrospective - Analyze project history for improvements
/retro
# Reviews git history, user corrections, agent mistakes
# Output: IMPROVEMENTS.md with 3-5 evidence-based recommendations

# 5. Apply Improvements - Implement retrospective findings
/retro-apply
# Updates commands, protocols, and automation based on IMPROVEMENTS.md
```

**Recommended Workflow**: `/assess` → `/plan` → `/modernize` → `/retro` → `/retro-apply`

## Architecture

### Directory Structure

```
agents/
├── commands/           # 5 slash commands (protocol documents)
│   ├── assess.md      # Assessment protocol with 8 evaluation dimensions
│   ├── plan.md        # Planning protocol with execution strategy
│   ├── modernize.md   # Full modernization protocol (7 phases, 6 agents)
│   ├── retro.md       # Retrospective analysis protocol
│   └── retro-apply.md # Improvement application protocol
├── agents/            # 6 specialist agent definitions
│   ├── migration-coordinator.md  # Orchestrator for multi-stage projects
│   ├── security.md              # Vulnerability scanning and remediation
│   ├── architect.md             # Technology decisions and ADRs
│   ├── coder.md                 # Implementation and migration
│   ├── tester.md                # Comprehensive testing and validation
│   └── documentation.md         # Knowledge management and docs
├── protocols/         # Supporting protocol documentation
├── scripts/          # Automation scripts (5 utilities)
└── docs/            # Additional documentation
```

### Multi-Agent Coordination System

**6 Specialized Agents** work together through protocol-defined coordination:

1. **Migration Coordinator** (Orchestrator)
   - Role: Strategic oversight, agent coordination, quality gate enforcement
   - Active: Throughout entire project
   - Invoked via: Task tool when complex multi-stage orchestration needed

2. **Security Agent** (Blocker)
   - Role: CVE scanning, security scoring, vulnerability remediation
   - Active: Phase 1 (blocks progress until CRITICAL/HIGH issues resolved)
   - Quality Gate: Security score ≥45/100 required to proceed

3. **Architect Agent** (Decision Maker)
   - Role: Technology research, architectural decisions, ADR creation
   - Active: Phases 1-2 (planning and design)
   - Outputs: ADR files following MADR 3.0.0 format

4. **Coder Agent** (Implementation)
   - Role: Framework updates, API replacement, build fixes
   - Active: Phases 3-4
   - Note: Multiple coder agents can run in parallel on independent components

5. **Tester Agent** (Quality Gate)
   - Role: 6-phase testing protocol, fix-and-retest cycles
   - Active: After every code change (blocks progression)
   - Quality Gate: 100% test pass rate required

6. **Documentation Agent** (Knowledge Management)
   - Role: HISTORY.md logging, ADRs, migration guides, changelogs
   - Active: Continuous throughout project
   - Templates: Follows structured documentation protocols

### Protocol-Driven Design

Each command file contains:
- **Agent coordination instructions** - How specialists work together
- **Phase-by-phase workflows** - Detailed steps with durations and deliverables
- **Quality gates** - Blocking criteria that must be satisfied
- **Success criteria** - Validation checkpoints
- **Examples and anti-patterns** - Real-world scenarios and pitfalls to avoid
- **Troubleshooting guides** - Common issues and resolutions

### Key Quality Gates

These are enforced throughout the modernization workflow:

- **Security**: Score ≥45/100 before migration starts
- **Build**: 100% success before next stage
- **Tests**: 100% pass rate before proceeding
- **Issues**: All P0/P1 resolved before release

## Utility Scripts

Located in `scripts/` directory:

```bash
# Log agent activity to HISTORY.md
./scripts/append-to-history.sh "Title" "Details" "Context" "Impact"

# Analyze project dependencies
./scripts/analyze-dependencies.sh

# Capture baseline test results
./scripts/capture-test-baseline.sh

# Run comprehensive stage testing
./scripts/run-stage-tests.sh

# Validate migration stage completion
./scripts/validate-migration-stage.sh
```

**Usage Pattern**: Agents invoke these scripts to maintain audit trails and enforce quality gates.

## Development Patterns

### Agent Invocation Pattern

When working with this repository:

1. **For exploration tasks**: Use `Task` tool with `subagent_type=Explore`
2. **For complex workflows**: Commands invoke agents via Task tool
3. **For protocol updates**: Follow continuous improvement cycle (retro → retro-apply)

### Protocol Update Workflow

When modifying protocols or commands:

1. Understand the protocol-driven architecture (each command IS a protocol)
2. Review existing agent coordination patterns
3. Maintain quality gate enforcement
4. Update related agent definitions if coordination changes
5. Consider running `/retro-apply` workflow for systematic improvements

### Continuous Improvement Philosophy

This repository practices what it preaches:

- **Git history is valuable data**: User corrections indicate agent behavior issues
- **Evidence-based improvements**: Recommendations backed by commit analysis
- **Self-improving system**: Each project makes the next one better
- **Protocol evolution**: Commands and agents updated based on retrospectives

## Important Protocols

### ADR Lifecycle (7 Stages)

Architectural Decision Records follow MADR 3.0.0 format through:
1. Problem Identification
2. Research
3. Evaluation
4. Decision
5. Implementation
6. Review
7. Superseded (when replaced)

**Location**: `protocols/adr-lifecycle.md` for details

### Testing Protocol (6 Phases)

All code changes must pass:
1. Unit Tests (isolated component validation)
2. Integration Tests (component interaction)
3. Build Tests (compilation and packaging)
4. Smoke Tests (critical path validation)
5. Security Tests (vulnerability scanning)
6. Performance Tests (regression detection)

**Location**: `protocols/testing-protocol.md` for details
**Enforcement**: 100% pass rate required by Tester agent

### Agent Logging Protocol

All agent work is logged to `HISTORY.md` using:
```bash
./scripts/append-to-history.sh "<title>" "<details>" "<context>" "<impact>"
```

**Templates Available**:
- Template 1: Migration Stage Completion
- Template 2: Security Remediation
- Template 3: Testing Results
- Template 4: Architectural Decision
- Template 5: Documentation Update

## Production Validation

This framework has proven results:
- **32/32 projects** migrated successfully (100% success rate)
- **100% test pass rate** achieved
- **Security improvement**: 0/100 → 45/100 (CRITICAL CVEs eliminated)
- **Zero P0/P1** blocking issues in production
- **1,500+ lines** of documentation auto-generated

## Plugin Configuration

**Plugin Metadata**: `.claude-plugin/plugin.json`
- Name: `modernize`
- Version: `0.2.0`
- Commands: 5 slash commands in `commands/`
- Agents: 6 specialist agents in `agents/`

**Installation**: Clone repository or copy `commands/` directory to target project.

## References

- **MADR 3.0.0**: https://adr.github.io/madr/ - ADR format specification
- **Keep a Changelog**: https://keepachangelog.com/ - CHANGELOG format
- **Repository**: https://github.com/laird/agents
- **Claude Code Docs**: https://docs.claude.com/en/docs/claude-code/
