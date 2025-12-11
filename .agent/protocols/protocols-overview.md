---
name: protocols-overview
description: Overview of all agent protocols with quick start guide and integration patterns
---

# Generic Agent Protocols for .NET Projects

**Version**: 1.0
**Last Updated**: 2025-10-10
**Purpose**: Reusable AI agent protocols for any .NET codebase

---

## Overview

This directory contains **universal agent protocol templates** designed to work with any .NET project undergoing migration, modernization, or significant refactoring. These protocols have been designed for broad applicability across different .NET framework migrations.

---

## Available Protocols

### 1. **GENERIC-AGENT-LOGGING-PROTOCOL.md**

**Purpose**: Universal logging protocol for AI agents

**What it provides**:

- Mandatory logging requirements for all agent activities
- Structured logging format with 4 required parameters
- Templates for common scenarios (migrations, security fixes, dependency updates)
- Integration with `append-to-history.sh` script
- Enforcement guidelines and validation procedures

**When to use**:

- Any project requiring audit trail of AI agent work
- Migration projects needing historical documentation
- Enterprise projects with compliance requirements
- Team projects where multiple agents work concurrently

**Customization needed**: Minimal - mostly project name replacements

---

### 2. **GENERIC-TESTING-PROTOCOL.md**

**Purpose**: Comprehensive testing requirements for any .NET project

**What it provides**:

- 6 mandatory testing phases (Pre-test, Unit, Integration, Component, Performance, Samples)
- Fix-and-retest cycle procedures
- Success criteria (Green/Yellow/Red go/no-go decisions)
- Test infrastructure templates (docker-compose, setup scripts)
- Test reporting templates
- Common mistakes and best practices

**When to use**:

- Any .NET project migration or modernization
- Release validation
- Quality gate enforcement
- CI/CD pipeline testing

**Customization needed**:

- Replace external dependency examples (RabbitMQ, PostgreSQL, Redis) with your stack
- Adjust pass rate thresholds for your context
- Add project-specific test categories

---

### 3. **GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md**

**Purpose**: Documentation strategy template for migrations

**What it provides**:

- Complete documentation plan structure
- CHANGELOG.md template
- MIGRATION-GUIDE.md template
- ADR (Architecture Decision Records) template
- Security documentation template
- Sample application documentation templates
- Effort estimates by priority
- Quality validation checklists

**When to use**:

- Planning documentation for version migrations
- Major refactoring or architectural changes
- Open source projects needing user migration paths
- Enterprise projects with documentation requirements

**Customization needed**:

- Fill in project-specific details throughout
- Adjust ADR topics for your architectural decisions
- Customize effort estimates for project size
- Prioritize based on release timeline

---

### 4. **GENERIC-MIGRATION-PLANNING-GUIDE.md**

**Purpose**: Systematic framework for planning .NET migrations

**What it provides**:

- 5 planning phases (Discovery, Strategy, Execution Planning, Execution, Validation)
- Current state analysis procedures
- Dependency analysis templates
- Migration phasing strategies (Bottom-Up, Top-Down, Risk-Based)
- Risk assessment frameworks
- Stage execution checklists
- Issue tracking templates
- Completion criteria

**When to use**:

- Planning any .NET framework migration
- Initial project assessment
- Creating migration roadmap
- Risk analysis and mitigation planning

**Customization needed**:

- Run discovery phase for your specific project
- Choose phasing strategy appropriate for your architecture
- Adjust timeline estimates for team size
- Add project-specific risks

---

### 5. **ADR-LIFECYCLE-PROTOCOL.md**

**Purpose**: Living document lifecycle management for Architecture Decision Records

**What it provides**:

- 7-stage ADR lifecycle (Problem → Research → Evaluation → Decision → Implementation → Review → Superseded)
- Incremental update requirements (commit after each alternative researched)
- Mandatory HISTORY.md logging when decisions accepted
- Post-implementation review procedures (1-3 months after implementation)
- Status transition rules (proposed → accepted → superseded)
- Commit message patterns for each lifecycle stage
- Quality gates for ADR completeness

**When to use**:

- **BEFORE** researching architectural alternatives (not after implementation)
- When evaluating technology choices
- During architectural refactoring
- For major dependency upgrades
- When architectural patterns change

**Customization needed**:

- Adjust post-implementation review timeframe (default: 1-3 months)
- Define project-specific evaluation criteria weights
- Customize commit message prefixes

---

### 6. **DOCUMENTATION-PROTOCOL.md**

**Purpose**: Comprehensive unified documentation guide integrating all documentation pillars

**What it provides**:

- **Part 1: HISTORY.md** - Chronological audit trail requirements (integrates GENERIC-AGENT-LOGGING-PROTOCOL.md)
- **Part 2: ADRs** - Complete 7-stage lifecycle (integrates ADR-LIFECYCLE-PROTOCOL.md)
- **Part 3: Inline Documentation** - Code comments, README files, migration guides, API docs
- Documentation workflows by agent type (architect, coder, tester, security, documentation, coordinator)
- Documentation quality gates
- Best practices (Do's and Don'ts)
- Integration with development workflow (planning → execution → review → maintenance)

**When to use**:

- **MANDATORY for all agents** - Single authoritative source for documentation requirements
- Throughout entire development lifecycle
- When onboarding new agents to project
- For documentation validation and quality checks

**Customization needed**: Minimal - comprehensive protocol covering all documentation needs

**Key Principle**: This protocol **integrates** the ADR lifecycle and logging protocols into a unified documentation strategy. Use this as the primary reference, with ADR-LIFECYCLE-PROTOCOL.md and GENERIC-AGENT-LOGGING-PROTOCOL.md as detailed specifications for those specific areas.

---

## Model Selection Guide (Opus 4.5)

When spawning agents via Claude Code's Task tool, use the `model` parameter to optimize for task complexity and cost:

### Quick Reference

| Agent | Default | Use Opus When | Use Haiku When |
|-------|---------|---------------|----------------|
| **Architect** | Opus | ADRs, technology evaluation, risk assessment | Formatting, index updates |
| **Migration Coordinator** | Opus | Planning, GO/NO-GO, complex coordination | Status updates, simple validations |
| **Security** | Sonnet | Novel vulnerabilities, architecture decisions | Report formatting, simple configs |
| **Coder** | Sonnet | Complex refactoring, novel API migrations | Find-and-replace, boilerplate |
| **Tester** | Sonnet | Complex failure diagnosis, GO/NO-GO escalations | Simple test runs, result formatting |
| **Documentation** | Sonnet | Migration guides, architecture docs | Formatting, simple updates |

### Model Capabilities

**Opus (model="opus")**

- Best for: Complex reasoning, architectural decisions, trade-off analysis
- Use when: Multiple factors, novel problems, strategic decisions
- Cost: Higher, but worth it for complex tasks

**Sonnet (model="sonnet")**

- Best for: Standard implementation work, routine operations
- Use when: Well-understood tasks, documented patterns
- Cost: Balanced quality and cost for most work

**Haiku (model="haiku")**

- Best for: Simple transformations, formatting, boilerplate
- Use when: Mechanical tasks, no judgment required
- Cost: Lowest, ideal for high-volume simple tasks

### Example Usage

```javascript
// Complex architectural decision - use Opus
Task("architect", "Evaluate messaging patterns for event-driven migration...", model="opus")

// Standard implementation - use Sonnet
Task("coder", "Update package references to .NET 9...", model="sonnet")

// Simple formatting - use Haiku
Task("documentation", "Fix markdown formatting in README...", model="haiku")
```

### Cost Optimization Strategy

1. **Start with the default** for each agent type
2. **Escalate to Opus** when encountering complexity or blockers
3. **Drop to Haiku** for simple mechanical tasks
4. **Track patterns** - if an agent type consistently needs Opus, update the default

---

## Quick Start Guide

### Step 1: Choose Your Protocols

Select which protocols are relevant for your project:

```bash
# Essential for ALL projects (use these first)
DOCUMENTATION-PROTOCOL.md                # MANDATORY - Unified documentation guide
GENERIC-AGENT-LOGGING-PROTOCOL.md        # Track all agent work (integrated in DOCUMENTATION-PROTOCOL.md)
GENERIC-TESTING-PROTOCOL.md              # Ensure quality

# For architectural decisions
ADR-LIFECYCLE-PROTOCOL.md                # ADR lifecycle management (integrated in DOCUMENTATION-PROTOCOL.md)

# For planning phase
GENERIC-MIGRATION-PLANNING-GUIDE.md      # Create migration plan

# For documentation planning
GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md   # Plan documentation work
```

---

### Step 2: Customize for Your Project

#### Option A: Create Project-Specific Copies

```bash
# Copy to your project
cp GENERIC-AGENT-LOGGING-PROTOCOL.md ../AGENT-LOGGING-PROTOCOL.md
cp GENERIC-TESTING-PROTOCOL.md ../TESTING-PROTOCOL.md
cp GENERIC-MIGRATION-PLANNING-GUIDE.md ../docs/modernization-plan.md
cp GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md ../DOCUMENTATION-PLAN.md

# Edit and customize
# Replace [Project Name], [Old Version], [New Version], etc.
```

#### Option B: Reference Directly

Add to your `CLAUDE.md` or agent instructions:

```markdown
## Agent Protocols

All agents MUST follow these protocols:
- Logging: docs/agents/GENERIC-AGENT-LOGGING-PROTOCOL.md
- Testing: docs/agents/GENERIC-TESTING-PROTOCOL.md
- Planning: docs/agents/GENERIC-MIGRATION-PLANNING-GUIDE.md
```

---

### Step 3: Set Up Required Infrastructure

#### Create Logging Script

```bash
# Create scripts directory
mkdir -p scripts

# Create append-to-history.sh
cat > scripts/append-to-history.sh << 'EOF'
#!/bin/bash
# append-to-history.sh - Universal history logging

HISTORY_FILE="docs/HISTORY.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if [ ! -f "$HISTORY_FILE" ]; then
    mkdir -p docs
    cat > "$HISTORY_FILE" << 'HEADER'
# Project History

This file tracks all significant changes, migrations, and decisions.

HEADER
fi

if [ $# -ne 4 ]; then
    echo "Error: Requires exactly 4 parameters"
    echo "Usage: $0 \"TITLE\" \"WHAT_CHANGED\" \"WHY_CHANGED\" \"IMPACT\""
    exit 1
fi

cat >> "$HISTORY_FILE" << ENTRY

---

## $TIMESTAMP - $1

**What Changed**: $2

**Why Changed**: $3

**Impact**: $4

ENTRY

echo "✅ Entry added to $HISTORY_FILE"
EOF

# Make executable
chmod +x scripts/append-to-history.sh

# Test it
./scripts/append-to-history.sh "Setup: Logging System" "Created append-to-history.sh script and initialized HISTORY.md" "Enable agent logging for audit trail and documentation" "Logging infrastructure ready for agent use"
```

#### Create Test Infrastructure

```bash
# Create docker-compose for test dependencies
cat > docker-compose.test.yml << 'EOF'
version: '3.8'

services:
  # Add your external dependencies here
  # Examples provided in GENERIC-TESTING-PROTOCOL.md

  # Uncomment and customize as needed:
  # postgres:
  #   image: postgres:16
  #   environment:
  #     POSTGRES_USER: testuser
  #     POSTGRES_PASSWORD: testpass
  #     POSTGRES_DB: testdb
  #   ports:
  #     - "5432:5432"
EOF
```

---

### Step 4: Configure Agent Instructions

Add to your project's `CLAUDE.md` or equivalent:

```markdown
## Agent Protocols (MANDATORY)

All agents working on this project MUST follow these protocols:

### 1. Documentation Protocol (PRIMARY REFERENCE)
- **MANDATORY** - Unified documentation guide covering all aspects
- See: docs/agents/DOCUMENTATION-PROTOCOL.md
- Covers: HISTORY.md logging, ADR lifecycle, inline documentation
- Defines workflows by agent type
- Use this as single authoritative source

### 2. ADR Lifecycle Protocol
- **MANDATORY** for architectural decisions
- See: docs/agents/ADR-LIFECYCLE-PROTOCOL.md (detailed specification)
- Create ADRs with status 'proposed' BEFORE research
- Update incrementally as each alternative is researched
- Log to HISTORY.md when decision accepted
- Conduct post-implementation reviews 1-3 months later

### 3. Logging Protocol
- **ALWAYS** log completed work to HISTORY.md using `./scripts/append-to-history.sh`
- See: docs/agents/GENERIC-AGENT-LOGGING-PROTOCOL.md (detailed specification)
- Required parameters: TITLE, WHAT_CHANGED, WHY_CHANGED, IMPACT
- Integrated in DOCUMENTATION-PROTOCOL.md Part 1

### 4. Testing Protocol
- **ALWAYS** run complete test suites (not partial)
- **ALWAYS** fix and retest until pass rate = 100%
- See: docs/agents/GENERIC-TESTING-PROTOCOL.md
- Required phases: Pre-test Setup, Unit, Integration, Component, Performance, Samples

### 5. Planning Protocol
- Use for initial migration planning
- See: docs/agents/GENERIC-MIGRATION-PLANNING-GUIDE.md
- Follow 5 phases: Discovery, Strategy, Execution Planning, Execution, Validation

### 6. Documentation Planning
- Plan documentation work comprehensively
- See: docs/agents/GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md
- Create: CHANGELOG, MIGRATION-GUIDE, ADRs, Security docs
```

---

## Protocol Integration Patterns

### Pattern 1: Solo Agent with Logging

**Scenario**: Single agent performing migration work

```markdown
**Agent Instructions**:
1. Follow GENERIC-MIGRATION-PLANNING-GUIDE.md for planning
2. Execute migration stages systematically
3. After EACH stage:
   - Run tests per GENERIC-TESTING-PROTOCOL.md
   - Log to HISTORY.md per GENERIC-AGENT-LOGGING-PROTOCOL.md
4. Create documentation per GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md
```

---

### Pattern 2: Multi-Agent Swarm with Coordination

**Scenario**: Multiple agents working in parallel

```markdown
**Coordinator Agent**:
- Spawn specialized agents with protocol requirements
- Each agent MUST log their work independently
- Coordinator verifies all agents logged properly

**Specialized Agents**:
- All agents: MUST follow DOCUMENTATION-PROTOCOL.md (primary reference)
- Architect Agent: Uses ADR-LIFECYCLE-PROTOCOL.md for architectural decisions
- Migration Agent: Uses GENERIC-MIGRATION-PLANNING-GUIDE.md
- Testing Agent: Uses GENERIC-TESTING-PROTOCOL.md
- Documentation Agent: Uses GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md
- All agents: Log via GENERIC-AGENT-LOGGING-PROTOCOL.md (integrated in DOCUMENTATION-PROTOCOL.md)

**Coordination**:
- All agents log to same HISTORY.md
- Timestamps show concurrent work
- Each agent signs their entries
```

---

### Pattern 3: CI/CD Integration

**Scenario**: Automated validation in pipeline

Use GitHub Actions or your CI/CD platform to automate validation:

- Validate HISTORY.md is updated on every commit
- Run test protocol with 100% pass rate requirement
- Validate documentation updates
- Enforce quality gates before merging

---

## Customization Examples

### Example 1: Web Application Migration

```markdown
# My Web App Migration

## Protocols Used
- GENERIC-MIGRATION-PLANNING-GUIDE.md (full)
- GENERIC-TESTING-PROTOCOL.md (customized for web testing)
- GENERIC-AGENT-LOGGING-PROTOCOL.md (as-is)
- GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md (API docs focus)

## Customizations
- Added Phase 6 to Testing Protocol: "E2E Browser Tests"
- External dependencies: PostgreSQL, Redis, Elasticsearch
- Additional ADR topics: API versioning, CORS policies, Auth migration
```

---

### Example 2: Library/NuGet Package Migration

```markdown
# My Library Migration

## Protocols Used
- GENERIC-MIGRATION-PLANNING-GUIDE.md (bottom-up phasing)
- GENERIC-TESTING-PROTOCOL.md (unit + integration focus)
- GENERIC-AGENT-LOGGING-PROTOCOL.md (as-is)
- GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md (API docs + samples)

## Customizations
- Removed "Sample Apps" from testing (not applicable)
- Added "Public API Surface" analysis to planning
- Added "Breaking Changes Impact Analysis" phase
- Multi-targeting strategy for backward compatibility
```

---

### Example 3: Microservices Migration

```markdown
# Microservices Platform Migration

## Protocols Used
- GENERIC-MIGRATION-PLANNING-GUIDE.md (service-by-service phasing)
- GENERIC-TESTING-PROTOCOL.md (added contract testing)
- GENERIC-AGENT-LOGGING-PROTOCOL.md (per-service logging)
- GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md (per-service docs)

## Customizations
- Phasing: One service per stage, validate before next
- Testing: Added contract tests, added service mesh validation
- Logging: Each service has own HISTORY.md
- Documentation: Per-service migration guides, API gateway updates
```

---

## Benefits of Using These Protocols

### 1. Consistency

- All agents follow same standards
- Predictable outcomes
- Easier coordination

### 2. Quality Assurance

- Mandatory testing catches issues early
- Fix-and-retest cycle prevents defect accumulation
- Clear success criteria

### 3. Auditability

- Complete history of all changes
- Traceable decisions
- Compliance-ready documentation

### 4. Reusability

- Templates save planning time
- Proven patterns reduce risk
- Learn from past migrations

### 5. Scalability

- Works for small and large projects
- Supports solo agents or swarms
- Integrates with existing workflows

---

## Support and Maintenance

### Reporting Issues

If you find issues with these protocols:

1. Document the problem clearly
2. Suggest improvements
3. Share your customizations that worked well

### Contributing Improvements

These protocols improve through use. Consider contributing:

- Additional templates for specific scenarios
- Lessons learned from your migrations
- Tool integrations and automations
- Additional customization examples

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-10-10 | Initial generic protocols extracted from RawRabbit migration |

---

## Related Resources

### Microsoft Documentation

- [.NET Migration Guides](https://docs.microsoft.com/en-us/dotnet/core/porting/)
- [Breaking Changes](https://docs.microsoft.com/en-us/dotnet/core/compatibility/)
- [What's New in .NET](https://docs.microsoft.com/en-us/dotnet/core/whats-new/)

### Tools

- [.NET Upgrade Assistant](https://dotnet.microsoft.com/en-us/platform/upgrade-assistant)
- [API Portability Analyzer](https://github.com/microsoft/dotnet-apiport)
- [BenchmarkDotNet](https://benchmarkdotnet.org/)

### Best Practices

- [Keep a Changelog](https://keepachangelog.com/)
- [Semantic Versioning](https://semver.org/)
- [Architecture Decision Records](https://adr.github.io/)

---

## License

These protocols are provided as templates for your use. Customize freely for your projects.

---

## Quick Reference Card

```
┌─────────────────────────────────────────────────────────────┐
│ Generic Agent Protocols - Quick Reference                   │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│ 0. DOCUMENTATION PROTOCOL (PRIMARY - MANDATORY)              │
│    See: DOCUMENTATION-PROTOCOL.md                            │
│    Integrates: Logging + ADR lifecycle + Inline docs        │
│    Use as: Single authoritative source                      │
│                                                              │
│ 1. ADR LIFECYCLE (MANDATORY for Architects)                 │
│    Create: BEFORE research (status: proposed)               │
│    Update: After each alternative researched (commit)       │
│    Decide: Change status to accepted, log to HISTORY.md     │
│    Review: 1-3 months post-implementation                   │
│                                                              │
│ 2. LOGGING (MANDATORY)                                       │
│    ./scripts/append-to-history.sh "TITLE" "WHAT" "WHY" "IMP"│
│    After: Every completed stage/task                         │
│                                                              │
│ 3. TESTING (MANDATORY)                                       │
│    Phases: Pre-test → Unit → Integration → Component        │
│           → Performance → Samples                            │
│    Target: 100% (all test types)                            │
│    Fix-and-retest until criteria met                        │
│                                                              │
│ 4. PLANNING (Initial Phase)                                 │
│    Phases: Discovery → Strategy → Execution Planning        │
│           → Execution → Validation                           │
│    Output: Migration plan with stages, risks, timeline      │
│                                                              │
│ 5. DOCUMENTATION (Throughout)                                │
│    Create: CHANGELOG, MIGRATION-GUIDE, ADRs, Security docs  │
│    Update: README, API docs, samples                        │
│    Validate: All links work, all code compiles              │
│                                                              │
│ SUCCESS CRITERIA                                             │
│    ✅ All builds pass                                        │
│    ✅ Tests 100% pass                                        │
│    ✅ Zero P0 issues                                         │
│    ✅ HISTORY.md updated                                     │
│    ✅ ADRs updated at all lifecycle stages                   │
│    ✅ Documentation complete                                 │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

**Template Version**: 1.0
**Last Updated**: 2025-10-10
**Status**: Production Ready
**Applicability**: All .NET projects

**Remember**: These protocols are guides, not constraints. Adapt them to your project's specific needs while maintaining their core principles: **completeness, quality, and auditability**.
