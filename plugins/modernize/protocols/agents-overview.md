---
name: agents-overview
description: Overview of 6 specialized agents for software modernization (markdown-based specifications)
---

# Generic Agent Specifications

**Version**: 2.0
**Last Updated**: 2025-10-26
**Purpose**: Reusable AI agent specifications for software modernization

---

## Overview

This directory contains **markdown specifications** for 6 specialized AI agents designed to execute systematic software modernization. These specifications define capabilities, responsibilities, workflows, and success criteria for each agent role.

**Agent Format**: Markdown files in `agents/` directory

---

## Available Agent Specifications

### 1. **migration-coordinator.md**
**Role**: Orchestrator/Coordinator
**Category**: Orchestration
**Location**: `agents/migration-coordinator.md`

**Responsibilities**:
- Multi-stage migration planning
- Agent team coordination
- Quality gate enforcement
- Progress tracking and reporting
- Documentation coordination

**When to use**: As the main orchestrator for any modernization project

---

### 2. **security.md**
**Role**: Security Specialist
**Category**: Security
**Location**: `agents/security.md`

**Responsibilities**:
- CVE vulnerability scanning
- Security score calculation (0-100 scale)
- Dependency vulnerability assessment
- Security fix implementation
- Security validation

**When to use**: For security assessment and remediation

---

### 3. **architect.md**
**Role**: Architecture & Design
**Category**: Planning
**Location**: `agents/architect.md`

**Responsibilities**:
- Architecture decisions (ADRs)
- Technology research
- Migration strategy
- Design patterns

**When to use**: For architectural decisions and planning

---

### 4. **coder.md**
**Role**: Implementation
**Category**: Development
**Location**: `agents/coder.md`

**Responsibilities**:
- Code migration
- API modernization
- Bug fixing
- Framework updates

**When to use**: For actual code implementation work

---

### 5. **tester.md**
**Role**: Quality Assurance
**Category**: Testing
**Location**: `agents/tester.md`

**Responsibilities**:
- Test execution
- Quality gate enforcement
- Fix-and-retest cycles
- 100% pass rate validation

**When to use**: For comprehensive testing and validation

---

### 6. **documentation.md**
**Role**: Documentation
**Category**: Knowledge Management
**Location**: `agents/documentation.md`

**Responsibilities**:
- CHANGELOG creation
- Migration guides
- ADR summaries
- Documentation updates

**When to use**: For comprehensive documentation

---

## Agent Markdown Structure

Each agent markdown file contains:
- **Name and Version**: Agent identification
- **Role and Category**: Agent specialization
- **Description**: Purpose and applicability
- **Capabilities**: What the agent can do
- **Responsibilities**: What the agent is accountable for
- **Workflow**: Step-by-step processes
- **Success Criteria**: Quality gates and completion criteria
- **Best Practices**: Recommended approaches
- **Anti-Patterns**: Common mistakes to avoid
- **Outputs**: Deliverables and artifacts
- **Integration**: How it coordinates with other agents

See `agents/*.md` files for complete specifications.

---

## How to Use These Specifications

### Option 1: Agent Spawn Instructions

When spawning agents with Claude Code's Task tool, reference the agent specification:

Example: Security Agent
```
You are a security-agent following the specification in: agents/security.md

Your responsibilities:
- Scan for vulnerabilities
- Categorize by severity
- Create remediation plan
- Implement fixes
- Validate with testing
- Document in HISTORY.md

Success criteria:
- All CRITICAL/HIGH CVEs fixed
- Security score ≥45
- Complete security report generated
```

### Option 2: Project Documentation

Reference agent specifications in your project documentation:

Available agents:
- **Security Agent** (`agents/security.md`): CVE scanning, security fixes, scoring
- **Coder Agent** (`agents/coder.md`): Code migration, dependency updates
- **Tester Agent** (`agents/tester.md`): Test execution, 100% pass rate enforcement
- **Documentation Agent** (`agents/documentation.md`): CHANGELOG, migration guides, ADRs
- **Architect Agent** (`agents/architect.md`): Architecture decisions, ADRs
- **Migration Coordinator** (`agents/migration-coordinator.md`): Overall orchestration, quality gates

### Option 3: Multi-Agent Coordination

Use the `/modernize-project` command which coordinates all agents automatically:
- Migration Coordinator orchestrates the workflow
- Security Agent handles vulnerability scanning
- Architect Agent makes design decisions
- Coder Agent implements changes
- Tester Agent validates everything
- Documentation Agent creates all docs

---

## Customization Guide

### 1. Understand Agent Specifications

Read the agent markdown files in the `agents/` directory to understand their capabilities and workflows. Each agent has detailed sections on:
- Responsibilities
- Workflows
- Success criteria
- Best practices
- Anti-patterns

### 2. Use with /modernize Commands

The agents work together through the modernization commands:
- `/modernize-assess`: Security + Architect agents assess project
- `/modernize-plan`: Coordinator + Architect create detailed plan
- `/modernize-project`: All agents work together through 7 phases

### 3. Customize for Your Project

Agents automatically adapt to your technology stack by:
- Detecting your framework and dependencies
- Adjusting security scans for your ecosystem
- Using appropriate testing tools
- Generating stack-specific documentation

---

## Integration Patterns

### Pattern 1: Single Coordinator, Multiple Workers

```
migration-coordinator (orchestrates)
  ├─> security-agent (Stage 1: Security fixes)
  ├─> coder-agent (Stage 2-N: Code migration)
  ├─> tester-agent (After each stage: Validation)
  └─> documentation-agent (Final stage: Documentation)
```

### Pattern 2: Parallel Execution

```
migration-coordinator
  ├─> coder-agent (Project A)
  ├─> coder-agent (Project B)
  ├─> coder-agent (Project C)
  └─> tester-agent (Validates all)
```

### Pattern 3: Feedback Loop

```
coder-agent → tester-agent (tests)
               ↓ (if failures)
            coder-agent (fixes)
               ↓ (retest)
            tester-agent
               ↓ (if pass)
         documentation-agent
```

---

## Success Metrics by Agent

| Agent | Key Metric | Target | Critical Threshold |
|-------|-----------|--------|-------------------|
| Coordinator | Stages complete | 100% | All |
| Security | Security score | ≥85/100 | CRITICAL/HIGH = 0 |
| Coder | Build success | 100% | 100% |
| Tester | Unit pass rate | 100% | 100% |
| Tester | Integration pass rate | 100% | 100% |
| Documentation | Docs complete | 100% | All breaking changes |

---

## Best Practices

1. **Always use coordinator** - Don't run agents independently without coordination
2. **Follow workflows** - Each agent has a defined workflow (1-5 phases)
3. **Enforce success criteria** - Don't proceed unless criteria met
4. **Document everything** - All agents must log to HISTORY.md
5. **Fix-and-retest** - Never skip retesting after fixes
6. **Parallel when possible** - Spawn multiple agents for independent work
7. **Sequential when required** - Some stages must complete before others start

---

## Common Customizations

### For Web Applications
- Add **e2e-tester-agent** (Selenium/Playwright)
- Customize security patterns for OWASP Top 10
- Add deployment validation to tester

### For Libraries/SDKs
- Add **api-compatibility-agent** (backward compatibility checks)
- Focus coder-agent on public API surface
- Add multi-framework testing to tester

### For Microservices
- Add **contract-tester-agent** (API contracts)
- Add service mesh configuration to coder
- Add distributed tracing to tester

### For Enterprise
- Add compliance checks to security-agent
- Add approval workflows to coordinator
- Add deployment runbooks to documentation-agent

---

## Example: Complete Modernization Flow

The `/modernize-project` command orchestrates a complete workflow:

**Phase 0: Discovery & Assessment**
- Coordinator + Security + Architect analyze project
- Baseline metrics captured
- Quality gates defined

**Phase 1: Security Remediation**
- Security Agent scans and fixes CVEs
- Must achieve security score ≥45
- Tester Agent validates no regressions

**Phases 2-6: Framework & Code Modernization**
- Architect creates ADRs
- Coder Agent(s) implement changes in parallel
- Tester Agent enforces 100% pass rate after each change
- Quality gates block progression if criteria not met

**Phase 7: Documentation & Validation**
- Documentation Agent creates CHANGELOG, migration guide
- Final testing across all test types
- Coordinator performs GO/NO-GO decision

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.0 | 2025-10-26 | Converted from YAML to markdown, updated for modernization workflow |
| 1.0 | 2025-10-10 | Initial specifications |

---

## Related Commands

- `/modernize-assess` - Assess project for modernization readiness
- `/modernize-plan` - Create detailed modernization plan
- `/modernize-project` - Execute modernization with agent coordination
- `/testing-protocol` - Testing requirements and quality gates
- `/agent-logging` - Logging protocol for all agents
- `/adr-lifecycle` - Architecture decision record management

---

## Summary

The agents work together as a coordinated team to modernize software projects. Each agent has a specific role and expertise:

- **Coordinator**: Orchestrates the entire workflow
- **Security**: Ensures security vulnerabilities are addressed
- **Architect**: Makes technology and design decisions
- **Coder**: Implements changes and migrations
- **Tester**: Validates quality with comprehensive testing
- **Documentation**: Captures all decisions and changes

Use the `/modernize-*` commands to leverage these agents for systematic project modernization.
