---
name: agent-yaml-spec
description: YAML agent specification guide with structure, fields, and best practices
---

# Generic Agent YAML Specifications

**Version**: 1.0
**Last Updated**: 2025-10-10
**Purpose**: Reusable AI agent specifications for .NET migrations

---

## Overview

This directory contains **generic YAML specifications** for 5 specialized AI agents designed to execute systematic .NET migrations. These specifications define capabilities, responsibilities, workflows, and success criteria for each agent role.

---

## Available Agent Specifications

### 1. **generic-migration-coordinator.yaml**
**Role**: Orchestrator/Coordinator
**Category**: Orchestration

**Responsibilities**:
- Multi-stage migration planning
- Agent swarm coordination
- Quality gate enforcement
- Progress tracking and reporting
- Documentation coordination

**Key Features**:
- 3 phasing strategies (bottom-up, top-down, risk-based)
- Customizable stages (4-12 phases)
- Metrics tracking
- Parallel agent execution coordination

**When to use**: As the main orchestrator for any .NET migration project

---

### 2. **generic-security-agent.yaml**
**Role**: Security Specialist
**Category**: Security

**Responsibilities**:
- CVE vulnerability scanning
- Security score calculation (0-100 scale)
- Dependency vulnerability assessment
- Insecure code pattern detection
- Security fix implementation

**Key Features**:
- 4 severity levels (CRITICAL/HIGH/MEDIUM/LOW)
- Security patterns for common vulnerabilities
- Remediation workflow (5 phases)
- CVSS-based scoring

**When to use**: Before and during migration to ensure security posture

---

### 3. **generic-coder-agent.yaml**
**Role**: Development Specialist
**Category**: Development

**Responsibilities**:
- Framework migration (.csproj updates)
- Dependency version updates
- API modernization
- Breaking change mitigation
- Build fix implementation

**Key Features**:
- Common API replacement patterns
- Conditional compilation cleanup
- Multi-targeting management
- Breaking change documentation

**When to use**: For actual code migration work in each stage

---

### 4. **generic-tester-agent.yaml**
**Role**: Quality Assurance Specialist
**Category**: Testing

**Responsibilities**:
- Comprehensive test execution (6 phases)
- Test infrastructure setup
- Failure diagnosis and categorization
- Fix-and-retest cycle management
- Test report generation

**Key Features**:
- Multiple test types (unit, integration, component, performance, e2e)
- Infrastructure templates (PostgreSQL, SQL Server, RabbitMQ, Kafka, Redis)
- Fix-and-retest workflow
- Quality gates (≥95% unit, ≥90% integration)

**When to use**: After each migration stage for validation

---

### 5. **generic-documentation-agent.yaml**
**Role**: Documentation Specialist
**Category**: Documentation

**Responsibilities**:
- CHANGELOG.md creation
- Migration guide authoring
- Release notes generation
- ADR writing
- Breaking change documentation

**Key Features**:
- 5 documentation types (changelog, migration guide, release notes, quick-start, ADR)
- Breaking change templates
- Platform-specific guides
- Quality checklist

**When to use**: Throughout migration, final documentation phase

---

## Agent YAML Structure

Each YAML file follows this structure:

```yaml
name: agent-name
version: 1.0
type: specialist | coordinator
category: orchestration | security | development | quality-assurance | documentation

description: |
  Detailed description of agent purpose and applicability

capabilities:
  - Capability 1
  - Capability 2

responsibilities:
  - Responsibility 1
  - Responsibility 2

tools:
  required:
    - Tool 1
    - Tool 2
  optional:
    - Tool 3

workflow:
  1_phase_name:
    - Step 1
    - Step 2

success_criteria:
  - Criterion 1
  - Criterion 2

best_practices:
  - Practice 1
  - Practice 2

anti_patterns:
  - Anti-pattern 1
  - Anti-pattern 2

outputs:
  - Output 1
  - Output 2

integration:
  coordinates_with:
    - agent 1
    - agent 2

metrics:
  - Metric 1: description
  - Metric 2: description

customization:
  project_specific:
    - Customization area 1
    - Customization area 2
```

---

## How to Use These Specifications

### Option 1: Agent Spawn Instructions

When spawning agents with Claude Code's Task tool, reference the YAML:

```javascript
Task(
  "Security Assessment and Remediation",
  `
  You are a security-agent following the specification in:
  docs/agents/generic-security-agent.yaml

  Your responsibilities:
  - Scan for vulnerabilities
  - Categorize by severity
  - Create remediation plan
  - Implement fixes
  - Validate with testing
  - Document in HISTORY.md

  Success criteria:
  - All CRITICAL/HIGH CVEs fixed
  - Security score ≥85/100
  - Complete security report generated
  `,
  "security-manager"
)
```

### Option 2: CLAUDE.md Integration

Add agent specifications to your project's CLAUDE.md:

```markdown
## Agent Specifications

When spawning specialized agents, follow these specifications:

### Security Agent
- **Spec**: docs/agents/generic-security-agent.yaml
- **Responsibilities**: CVE scanning, security fixes, scoring
- **Success**: Score ≥85/100, zero CRITICAL/HIGH CVEs

### Coder Agent
- **Spec**: docs/agents/generic-coder-agent.yaml
- **Responsibilities**: Framework migration, dependency updates
- **Success**: 100% build success, <5 warnings per project

### Tester Agent
- **Spec**: docs/agents/generic-tester-agent.yaml
- **Responsibilities**: Test execution, fix-and-retest cycles
- **Success**: ≥95% unit, ≥90% integration pass rates

### Documentation Agent
- **Spec**: docs/agents/generic-documentation-agent.yaml
- **Responsibilities**: CHANGELOG, migration guide, ADRs
- **Success**: All breaking changes documented

### Migration Coordinator
- **Spec**: docs/agents/generic-migration-coordinator.yaml
- **Responsibilities**: Overall orchestration, quality gates
- **Success**: All stages complete, full documentation
```

### Option 3: Swarm Initialization

Use with MCP tools for swarm coordination:

```bash
# Initialize swarm with agent specs
mcp__claude-flow__swarm_init \
  --topology mesh \
  --agents security-agent,coder-agent,tester-agent,documentation-agent \
  --coordinator migration-coordinator

# Reference YAML specs in agent spawn
Task("Security Agent", "Follow spec: generic-security-agent.yaml", "security-manager")
Task("Coder Agent", "Follow spec: generic-coder-agent.yaml", "coder")
Task("Tester Agent", "Follow spec: generic-tester-agent.yaml", "tester")
```

---

## Customization Guide

### 1. Copy and Customize

```bash
# Copy generic spec to project-specific
cp generic-security-agent.yaml my-project-security-agent.yaml

# Edit and customize
# - Add project-specific security patterns
# - Adjust severity thresholds
# - Add domain-specific vulnerabilities
```

### 2. Extend with Project-Specific Sections

```yaml
# Add to existing YAML
customization:
  my_project:
    additional_security_patterns:
      - "HIPAA PHI exposure: pattern..."
      - "PCI-DSS cardholder data: pattern..."

    custom_workflows:
      healthcare_compliance:
        - Scan for PHI exposure
        - Validate encryption
        - Check access controls
```

### 3. Adjust for Your Stack

```yaml
# Customize test infrastructure for your project
test_infrastructure:
  database:
    mongodb:  # Instead of PostgreSQL
      container_name: "mongo-test"
      image: "mongo:7"
      ports: ["27017:27017"]

  message_broker:
    azure_service_bus:  # Instead of RabbitMQ
      connection_string: "${AZURE_SERVICE_BUS_CONNECTION}"
```

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
| Tester | Unit pass rate | ≥95% | ≥85% |
| Tester | Integration pass rate | ≥90% | ≥80% |
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

## Example: Complete Migration Flow

```yaml
# 1. Initialize
coordinator:
  - Create migration plan (8 stages)
  - Define quality gates
  - Spawn agents

# 2. Stage 1: Security
security-agent:
  - Scan for CVEs
  - Fix CRITICAL/HIGH
  - Achieve score ≥85/100

# 3. Stages 2-7: Code Migration
coordinator:
  for each stage:
    - Spawn coder-agent
    - Wait for completion
    - Spawn tester-agent
    - Enforce quality gate
    - Continue or block

# 4. Stage 8: Documentation
documentation-agent:
  - Create CHANGELOG.md
  - Write MIGRATION-GUIDE.md
  - Generate release notes
  - Write ADRs
  - Update README.md

# 5. Final Validation
coordinator:
  - Verify all stages complete
  - Check all success criteria met
  - Generate final report
  - Approve for release
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-10-10 | Initial generic agent specifications |

---

## Related Documentation

- **GENERIC-AGENT-PROTOCOLS-README.md** - Protocol documentation (logging, testing, planning)
- **GENERIC-AGENT-LOGGING-PROTOCOL.md** - Logging requirements
- **GENERIC-TESTING-PROTOCOL.md** - Testing requirements
- **GENERIC-MIGRATION-PLANNING-GUIDE.md** - Migration planning framework
- **GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md** - Documentation strategy

---

## Support

These specifications are templates - customize freely for your project. They represent proven patterns from real-world .NET migrations and are designed to be adapted to your specific needs.

**Remember**: These are guidelines, not rigid constraints. Adapt them to your project's context, team size, timeline, and risk tolerance.
