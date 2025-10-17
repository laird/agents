# RawRabbit Agent Definitions

This directory contains agent definition files for use with claude-flow and multi-agent orchestration systems.

## Overview

These agent definitions document specialized agents, their capabilities, responsibilities, and integration patterns for systematic .NET framework migrations and software modernization projects.

---

## File Naming Convention

This directory uses a consistent naming convention to distinguish between generic, reusable content and project-specific customizations:

### Agent Definition Files (`.yaml`)

**Format**: `generic-[agent-name]-agent.yaml`

All agent definition files follow this format and are reusable across any .NET project:
- `generic-architect-agent.yaml`
- `generic-coder-agent.yaml`
- `generic-documentation-agent.yaml`
- `generic-migration-coordinator.yaml`
- `generic-security-agent.yaml`
- `generic-tester-agent.yaml`

### Protocol Files (`.md`)

Protocol files use prefixes to indicate their scope:

**Generic Protocols** - `GENERIC-*.md`
- Reusable protocols applicable to any .NET project
- Template protocols that can be customized for specific projects
- No project-specific content or examples
- Examples:
  - `GENERIC-AGENT-LOGGING-PROTOCOL.md` - Universal logging protocol
  - `GENERIC-DOCUMENTATION-PROTOCOL.md` - Generic documentation process
  - `GENERIC-TESTING-PROTOCOL.md` - Universal testing protocol
  - `GENERIC-MIGRATION-PLANNING-GUIDE.md` - Generic migration framework

**Project-Specific Protocols** - `project-*.md`
- Customizations of generic protocols for RawRabbit
- RawRabbit-specific examples, templates, and requirements
- References generic protocols and adds project-specific content
- Examples:
  - `project-agent-logging-protocol.md` - RawRabbit logging examples
  - `project-agent-workflow.md` - RawRabbit agent workflow
  - `project-comprehensive-testing-protocol.md` - RawRabbit testing specifics

**Key Principle**: Project-specific files should only contain RawRabbit-specific content. All reusable patterns belong in generic files. Project files should reference generic files and add only project-specific examples, policies, and customizations.

### Common Files

**`common-agent-sections.yaml`**
- Centralized repository of common patterns shared across all agent definitions
- Contains common protocols, tools, workflows, best practices, anti-patterns
- Referenced by all agent YAML files to reduce redundancy

**`README.md`**
- This file - catalog of agents and usage guide

---

## Agent Catalog

### 1. Migration Coordinator (`migration-coordinator.yaml`)
**Type**: Orchestration
**Purpose**: Strategic oversight of multi-stage migration projects

**Key Capabilities**:
- Multi-stage migration planning (8+ phases)
- Agent swarm coordination
- Risk assessment and quality gates
- Progress tracking and reporting

**Use When**: Coordinating large-scale codebase migrations with multiple stages and dependencies

---

### 2. Security Agent (`security-agent.yaml`)
**Type**: Security Specialist
**Purpose**: Vulnerability assessment and remediation

**Key Capabilities**:
- CVE vulnerability scanning
- Security score calculation (0-100)
- Prioritized remediation plans
- Compliance validation

**Use When**: Addressing security vulnerabilities, updating dependencies, enforcing secure coding practices

**Blocks**: CRITICAL/HIGH vulnerabilities block all migration progress until resolved

---

### 3. Coder Agent (`coder-agent.yaml`)
**Type**: Development Specialist
**Purpose**: Code migration and API modernization

**Key Capabilities**:
- Framework target migration
- Dependency version updates
- API modernization (obsolete → current)
- Build fix implementation

**Use When**: Migrating projects to new frameworks, updating packages, replacing obsolete APIs

**Parallel Execution**: Multiple coder agents can work on independent projects simultaneously

---

### 4. Tester Agent (`tester-agent.yaml`)
**Type**: Quality Assurance Specialist
**Purpose**: Comprehensive testing with fix-and-retest cycles

**Key Capabilities**:
- Complete test suite execution
- Test infrastructure setup (RabbitMQ, Docker)
- Fix-and-retest cycle management
- Test report generation

**Use When**: Validating migration quality, executing test suites, diagnosing test failures

**Enforces**: ≥95% pass rate requirement before progression

---

### 5. Documentation Agent (`documentation-agent.yaml`)
**Type**: Documentation Specialist
**Purpose**: Comprehensive user-facing documentation

**Key Capabilities**:
- CHANGELOG.md creation
- Migration guide authoring (800+ lines)
- Release notes generation
- ADR writing

**Use When**: Documenting breaking changes, creating migration guides, writing release notes

**Outputs**: CHANGELOG, migration guides, quick-starts, ADRs, platform guides

---

### 6. Architect Agent (`architect-agent.yaml`)
**Type**: Architecture Design Specialist
**Purpose**: Research technology alternatives and make architectural decisions

**Key Capabilities**:
- Technology research and evaluation
- Architectural pattern selection
- Trade-off analysis (performance, scalability, maintainability, cost)
- ADR creation and maintenance (MADR 3.0.0 format)
- Decision documentation

**Use When**: Selecting technologies, choosing architectural patterns, making infrastructure decisions, documenting design decisions

**Outputs**: ADR files (docs/ADR/), evaluation matrices, architecture diagrams, research summaries

**Decision Process**: Problem → Research (3+ alternatives) → Evaluation → Decision → Documentation → HISTORY.md log

---

## Usage with claude-flow

### Basic Agent Spawn

```yaml
# Example: Spawn security agent
claude-flow agent spawn security-agent \
  --task "Scan codebase for CVE vulnerabilities" \
  --output "security-assessment.md"
```

### Multi-Agent Orchestration

```yaml
# Example: Parallel coder agents for migration
claude-flow swarm init \
  --topology mesh \
  --agents coder-agent:3

# Assign projects to each agent
claude-flow task assign agent-1 "Migrate RawRabbit.Core"
claude-flow task assign agent-2 "Migrate RawRabbit.Operations"
claude-flow task assign agent-3 "Migrate RawRabbit.Enrichers"
```

### Agent Coordination Example

```yaml
# Complete migration workflow
stages:
  - name: security-remediation
    agent: security-agent
    blocks: true  # Block until CRITICAL/HIGH fixed

  - name: core-migration
    agent: coder-agent
    parallel: 3
    depends_on: security-remediation

  - name: validation
    agent: tester-agent
    depends_on: core-migration
    criteria: "pass_rate >= 95%"

  - name: documentation
    agent: documentation-agent
    depends_on: validation
```

## Agent Integration Patterns

### Sequential Pipeline
```
Migration Coordinator
  ↓
Security Agent → Blocks until score ≥45
  ↓
Coder Agent (Stage 1) → Core migration
  ↓
Tester Agent → Validates (≥95% pass)
  ↓
Coder Agent (Stage 2) → Operations
  ↓
Tester Agent → Validates (≥95% pass)
  ↓
Documentation Agent → Release docs
```

### Parallel Execution
```
Migration Coordinator
  ↓
  ├─ Coder Agent #1 (Project A)
  ├─ Coder Agent #2 (Project B)
  └─ Coder Agent #3 (Project C)
  ↓
Tester Agent (validates all)
```

### Fix-and-Retest Cycle
```
Tester Agent
  ↓ (finds failures)
Coder Agent
  ↓ (fixes issues)
Tester Agent
  ↓ (re-validates)
[Repeat until pass rate ≥95%]
```

## Project Results

Using these agent definitions, migrations have achieved:

### Quantitative Results
- **32/32 projects migrated** (100%)
- **Build success**: 31/31 (100%)
- **Test pass rate**: 96.4% (exceeds 95% threshold)
- **Security improvement**: 0/100 → 45/100 (CRITICAL eliminated)
- **27 NuGet packages** created and validated
- **1,500+ lines** of documentation generated

### Qualitative Results
- Zero P0/P1 blocking issues
- Complete audit trail (HISTORY.md)
- 7 ADRs documenting key decisions
- Comprehensive testing protocol established
- Production-ready in 8 systematic stages

## Best Practices

### 1. Agent Selection
- Use **migration-coordinator** for strategic oversight
- Use **security-agent** first to address vulnerabilities
- Use **coder-agent** in parallel for independent work
- Use **tester-agent** after every code change
- Use **documentation-agent** when work is complete

### 2. Quality Gates
- Security score ≥45 before migration starts
- Build success 100% before next stage
- Test pass rate ≥95% before proceeding
- All P0/P1 issues resolved before release

### 3. Documentation
- Log all agent activities to HISTORY.md
- Create ADRs for architectural decisions
- Generate stage reports after each phase
- Maintain comprehensive test reports

### 4. Parallel Execution
- Spawn multiple coder agents for independent projects
- Use single tester agent to validate all changes
- Coordinate through migration-coordinator
- Use TodoWrite to track all tasks

## Extending Agents

To create new agent definitions:

1. Copy an existing `.yaml` file as template
2. Define name, version, type, category
3. List capabilities and responsibilities
4. Document tools and workflow
5. Define success criteria
6. Provide integration patterns
7. Include examples and anti-patterns

## References

### Project Documentation
- [Comprehensive Testing Protocol](../test/COMPREHENSIVE-TESTING-PROTOCOL.md)
- [Agent Logging Protocol](../AGENT-LOGGING-PROTOCOL.md)
- [Migration Plan](../PLAN.md)
- [ADR Index](../ADR/README.md)

### External Resources
- [claude-flow Documentation](https://github.com/ruvnet/claude-flow)
- [Multi-Agent Orchestration Patterns](https://docs.anthropic.com/claude/docs/multi-agent-systems)

---

**Created**: 2025-10-10
**Project**: .NET Framework Migration
**Status**: Production-validated agent definitions
