# Agent Protocols and Definitions Repository

A comprehensive collection of **reusable agent protocols**, **agent definitions**, and **automation frameworks** for AI-assisted software development, testing, and documentation.

## Overview

This repository provides production-validated protocols and agent definitions that enable systematic, high-quality software development through AI coordination. Originally created for .NET framework migrations, these protocols are **universally applicable** to any software project requiring structured agent collaboration.

---

## Repository Structure

```
agents/
├── 📋 Protocol Documents (9 files)
│   ├── 00-PROTOCOL-INDEX.md                    # Master navigation hub
│   ├── GENERIC-ADR-LIFECYCLE-PROTOCOL.md       # Architecture decisions
│   ├── GENERIC-AGENT-LOGGING-PROTOCOL.md       # Audit trail & HISTORY.md
│   ├── GENERIC-AGENT-PROTOCOLS-README.md       # Protocol overview
│   ├── GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md  # Documentation planning
│   ├── GENERIC-DOCUMENTATION-PROTOCOL.md       # Unified docs guide
│   ├── GENERIC-TESTING-PROTOCOL.md             # Comprehensive testing
│   ├── INCREMENTAL-DOCUMENTATION-PROTOCOL.md   # Continuous documentation
│   └── VALIDATION-REPORT.md                    # File validation status
│
├── 🤖 Agent Definitions (6 files)
│   ├── generic-architect-agent.yaml            # Architecture & tech research
│   ├── generic-coder-agent.yaml                # Code implementation
│   ├── generic-documentation-agent.yaml        # Documentation creation
│   ├── generic-migration-coordinator.yaml      # Multi-stage orchestration
│   ├── generic-security-agent.yaml             # Vulnerability assessment
│   └── generic-tester-agent.yaml               # Quality assurance
│
├── 🔧 Automation Scripts (5 files)
│   ├── scripts/analyze-dependencies.sh         # Dependency analysis for parallelization
│   ├── scripts/append-to-history.sh            # HISTORY.md logging utility
│   ├── scripts/capture-test-baseline.sh        # Test baseline creation
│   ├── scripts/run-stage-tests.sh              # Stage-specific test execution
│   └── scripts/validate-migration-stage.sh     # Quality gate validation
│
├── 📄 Support Files (3 files)
│   ├── GENERIC-AGENT-YAML-README.md            # YAML specification guide
│   ├── README.md                               # This file
│   └── .gitignore                              # Git exclusion rules
│
└── 📁 Runtime (excluded from git)
    ├── .claude-flow/metrics/                   # Claude Flow metrics
    └── .swarm/                                 # Swarm coordination data
```

---

## Quick Start

### For New Projects

1. **Read the Index**: Start with `00-PROTOCOL-INDEX.md` for navigation
2. **Choose Your Protocols**: Select protocols relevant to your project type
3. **Configure Agents**: Use agent YAML files with claude-flow or similar tools
4. **Set Up Infrastructure**: Create logging scripts and test environments
5. **Begin Development**: Follow protocols for systematic, high-quality work

### For Existing Projects

1. **Integrate Protocols**: Reference protocols in your project's `CLAUDE.md` or agent instructions
2. **Adopt Incrementally**: Start with logging protocol, add testing, then documentation
3. **Customize**: Adapt protocols to your technology stack and requirements
4. **Scale**: Use multi-agent coordination patterns as complexity grows

---

## File Categories

### 1. Protocol Documents (9 files)

**Purpose**: Define standards, workflows, and best practices for agent behavior

#### Core Protocols

- **`00-PROTOCOL-INDEX.md`** (534 lines)
  - Central navigation hub for all protocols
  - Quick reference cards (1-page summaries)
  - Usage patterns and common workflows
  - Protocol compliance targets
  - **Use when**: Starting any new task, need to find specific protocol

- **`GENERIC-AGENT-LOGGING-PROTOCOL.md`** (436 lines)
  - Mandatory logging to HISTORY.md for audit trail
  - 7 logging templates (stage completion, fixes, ADRs, security, testing)
  - 4-parameter structure: WHAT, WHY, IMPACT, OUTCOME
  - Integration with `append-to-history.sh` script
  - **Use when**: After every significant action, completing stages, making decisions

- **`GENERIC-TESTING-PROTOCOL.md`** (577 lines)
  - 6 mandatory testing phases (Pre-test, Unit, Integration, Component, Performance, Samples)
  - Fix-and-retest cycle (max 3 iterations)
  - Success criteria (≥95% unit, ≥90% integration pass rates)
  - Test infrastructure templates (Docker, RabbitMQ, etc.)
  - **Use when**: After every code change, before stage progression, release validation

- **`GENERIC-MIGRATION-PLANNING-GUIDE.md`** (802 lines)
  - 5-phase framework: Discovery → Planning → Security → Execution → Validation
  - Phasing strategies (bottom-up, top-down, risk-based, hybrid)
  - Dependency analysis and timeline estimation
  - Risk assessment frameworks
  - **Use when**: Planning complex migrations, project start, timeline estimates needed

- **`GENERIC-ADR-LIFECYCLE-PROTOCOL.md`** (736 lines)
  - 7-stage ADR lifecycle (Creation → Review → Acceptance → Implementation → Validation → Review → Deprecation)
  - Critical naming convention: `ADR #### Title With Spaces.md` (spaces, not dashes!)
  - Incremental updates (commit after each alternative researched)
  - Post-implementation reviews (1-3 months after)
  - **Use when**: Before architectural decisions, technology selections, approach choices

#### Documentation Protocols

- **`GENERIC-DOCUMENTATION-PROTOCOL.md`**
  - Unified documentation guide integrating all documentation pillars
  - Part 1: HISTORY.md (audit trail)
  - Part 2: ADRs (architecture decisions)
  - Part 3: Inline documentation (code comments, READMEs)
  - **Use when**: Primary documentation reference, onboarding agents

- **`GENERIC-DOCUMENTATION-PLAN-TEMPLATE.md`**
  - Documentation strategy template
  - CHANGELOG, MIGRATION-GUIDE, ADR templates
  - Security documentation templates
  - Effort estimates by priority
  - **Use when**: Planning documentation for version migrations, major refactors

- **`INCREMENTAL-DOCUMENTATION-PROTOCOL.md`** (631 lines)
  - Continuous documentation throughout migration (not at end)
  - Update frequency guidelines
  - Anti-pattern: end-of-project documentation marathon
  - Time savings: 1-2 hours (documenting fresh vs. reconstructing)
  - **Use when**: Throughout entire project lifecycle

#### Guide Documents

- **`GENERIC-AGENT-PROTOCOLS-README.md`** (632 lines)
  - Overview of all agent protocols
  - Quick start guide with customization examples
  - Integration patterns (solo agent, multi-agent swarm, CI/CD)
  - Benefits and version history
  - **Use when**: Understanding protocol ecosystem, onboarding to system

- **`VALIDATION-REPORT.md`** (293 lines)
  - Automated validation of all files
  - 100% validation success rate
  - Protocol reference matrix
  - File organization overview
  - **Use when**: Verifying file integrity, understanding file relationships

### 2. Agent Definitions (6 YAML files)

**Purpose**: Specialized AI agents with defined capabilities, responsibilities, and workflows

#### Coordination Agents

- **`generic-migration-coordinator.yaml`** (11,069 bytes)
  - **Type**: Orchestration
  - **References**: 10 protocols (most comprehensive)
  - **Purpose**: Strategic oversight of multi-stage projects
  - **Key Capabilities**: Multi-stage planning, agent swarm coordination, risk assessment, progress tracking
  - **Use when**: Coordinating large-scale migrations with multiple stages and dependencies

#### Specialist Agents

- **`generic-architect-agent.yaml`** (45,585 bytes)
  - **Type**: Architecture Design Specialist
  - **References**: 3 protocols
  - **Purpose**: Research technology alternatives, make architectural decisions
  - **Key Capabilities**: Technology research, pattern selection, trade-off analysis, ADR creation
  - **Outputs**: ADR files (MADR 3.0.0 format), evaluation matrices, architecture diagrams
  - **Use when**: Selecting technologies, choosing patterns, infrastructure decisions

- **`generic-coder-agent.yaml`** (13,506 bytes)
  - **Type**: Development Specialist
  - **References**: 4 protocols (includes PARALLEL-MIGRATION, CONTINUOUS-TESTING)
  - **Purpose**: Code migration and API modernization
  - **Key Capabilities**: Framework migrations, dependency updates, API modernization, build fixes
  - **Parallel Execution**: Multiple coder agents can work independently
  - **Use when**: Migrating projects, updating packages, replacing obsolete APIs

- **`generic-tester-agent.yaml`** (17,030 bytes)
  - **Type**: Quality Assurance Specialist
  - **References**: 2 protocols
  - **Purpose**: Comprehensive testing with fix-and-retest cycles
  - **Key Capabilities**: Complete test suite execution, test infrastructure setup, test reporting
  - **Enforces**: ≥95% pass rate before progression
  - **Use when**: Validating migration quality, diagnosing test failures

- **`generic-documentation-agent.yaml`** (24,988 bytes)
  - **Type**: Documentation Specialist
  - **References**: 5 protocols (includes INCREMENTAL-DOCUMENTATION, ADR-LIFECYCLE)
  - **Purpose**: Comprehensive user-facing documentation
  - **Key Capabilities**: CHANGELOG creation, migration guides (800+ lines), release notes, ADRs
  - **Outputs**: CHANGELOG, migration guides, quick-starts, ADRs, platform guides
  - **Use when**: Documenting breaking changes, creating migration guides, release notes

- **`generic-security-agent.yaml`** (12,568 bytes)
  - **Type**: Security Specialist
  - **References**: 2 protocols
  - **Purpose**: Vulnerability assessment and remediation
  - **Key Capabilities**: CVE scanning, security score calculation (0-100), prioritized remediation plans
  - **Blocks**: CRITICAL/HIGH vulnerabilities block all progress until resolved
  - **Use when**: Addressing vulnerabilities, updating dependencies, enforcing security practices

### 3. Automation Scripts (5 files)

**Purpose**: Shell scripts that automate protocol workflows and quality gates

- **`scripts/analyze-dependencies.sh`**
  - Analyzes project dependencies to identify parallelization opportunities
  - Identifies independent projects that can be migrated concurrently
  - Outputs dependency graph and parallel execution recommendations
  - **Use when**: Planning parallel agent execution for multi-project migrations

- **`scripts/append-to-history.sh`**
  - Universal HISTORY.md logging utility
  - 4-parameter structure: TITLE, WHAT_CHANGED, WHY_CHANGED, IMPACT
  - Automatic timestamping and formatting
  - **Use when**: Logging agent activities, decisions, or significant events

- **`scripts/capture-test-baseline.sh`**
  - Captures test results as baseline for regression detection
  - Creates snapshots of test pass rates, execution times, and coverage
  - **Use when**: Before starting migration stage, establishing quality benchmarks

- **`scripts/run-stage-tests.sh`**
  - Stage-specific test execution with filtering
  - Supports strict mode (fail on any test failure)
  - Integrates with fix-and-retest protocol
  - **Use when**: Validating migration stages, running continuous tests

- **`scripts/validate-migration-stage.sh`**
  - Comprehensive quality gate validation
  - Checks: build success, test pass rate, security scan, documentation updates
  - Automated pass/fail determination
  - **Use when**: Before advancing to next migration stage, pre-release validation

### 4. Support Files (3 files)

- **`GENERIC-AGENT-YAML-README.md`**
  - YAML agent specification guide
  - File structure and field definitions
  - Best practices for agent creation
  - **Use when**: Creating new agent definitions

- **`VALIDATION-REPORT.md`** (293 lines)
  - Automated validation of all files
  - 100% validation success rate
  - Protocol reference matrix
  - File organization overview
  - **Use when**: Verifying file integrity, understanding file relationships

- **`.gitignore`**
  - Git exclusion rules for runtime-generated files
  - Excludes `.claude-flow/metrics/` and `.swarm/`
  - Excludes common OS and editor files

### 5. Runtime Directories (excluded from git)

- **`.claude-flow/metrics/`**
  - Claude Flow coordination metrics
  - Agent performance data (JSON)
  - Task metrics and system metrics (JSON)
  - Auto-generated during agent execution

- **`.swarm/`**
  - Swarm coordination database
  - Memory persistence for multi-agent systems
  - Auto-generated during swarm operations

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

## Key Features

### Production-Validated Protocols
- ✅ **100% file validation** - All 23 files properly formatted and validated
- ✅ **Comprehensive coverage** - 9 protocols + 5 automation scripts
- ✅ **Proven results** - Successfully guided 32/32 project migrations
- ✅ **Universal applicability** - Works with any software project, not just .NET

### Multi-Agent Coordination
- 🤖 **6 specialized agents** - Architecture, coding, testing, security, documentation, coordination
- 🔄 **Parallel execution** - Multiple agents work independently on separate tasks
- 📊 **Quality gates** - Automated validation at each stage (≥95% test pass rate)
- 📝 **Complete audit trail** - HISTORY.md logging for all agent activities

### Systematic Workflows
- 🗺️ **5-phase migration framework** - Discovery → Planning → Security → Execution → Validation
- 🧪 **6-phase testing protocol** - Pre-test → Unit → Integration → Component → Performance → Samples
- 📚 **7-stage ADR lifecycle** - Complete architectural decision documentation
- 🔁 **Fix-and-retest cycles** - Systematic quality improvement (max 3 iterations)

### Automation & Tooling
- 🔧 **5 automation scripts** - Dependency analysis, logging, testing, validation
- 📊 **Quality gate enforcement** - Automated validation before stage progression
- 📝 **HISTORY.md logging** - Structured audit trail with timestamping
- 🧪 **Test baseline tracking** - Regression detection and performance monitoring

### Real-World Results
- **32/32 projects** migrated successfully (100% success rate)
- **96.4% test pass rate** (exceeds 95% threshold)
- **Security improvement** from 0/100 → 45/100 (CRITICAL CVEs eliminated)
- **Zero P0/P1** blocking issues in production
- **1,500+ lines** of documentation auto-generated

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

## Use Cases

### Software Migrations
- Framework upgrades (.NET, Node.js, Python, etc.)
- Language migrations (Java to Kotlin, JavaScript to TypeScript)
- Cloud platform migrations (AWS, Azure, GCP)
- Database migrations (SQL to NoSQL, version upgrades)

### Development Projects
- Greenfield application development
- Microservices architecture implementation
- API development and modernization
- Legacy code refactoring

### Quality Assurance
- Test suite creation and maintenance
- Performance testing and optimization
- Security vulnerability assessment
- Compliance and audit trail requirements

### Documentation
- Technical documentation generation
- API documentation and examples
- Architecture decision records
- Migration guides for end-users

---

## References

### Protocol Documentation
- **Start here**: `00-PROTOCOL-INDEX.md` - Master navigation hub
- **Agent overview**: `GENERIC-AGENT-PROTOCOLS-README.md` - Protocol ecosystem guide
- **Validation**: `VALIDATION-REPORT.md` - File integrity and relationships

### External Tools
- [Claude Flow](https://github.com/ruvnet/claude-flow) - Multi-agent orchestration
- [MADR 3.0.0](https://adr.github.io/madr/) - ADR format specification
- [Keep a Changelog](https://keepachangelog.com/) - CHANGELOG format

### Related Resources
- [.NET Migration Guides](https://docs.microsoft.com/en-us/dotnet/core/porting/)
- [Architecture Decision Records](https://adr.github.io/)
- [Semantic Versioning](https://semver.org/)

---

## Contributing

This repository is designed to be forked and customized for your specific needs:

1. **Fork the repository** - Create your own copy
2. **Customize protocols** - Adapt to your technology stack
3. **Create project-specific agents** - Build on generic definitions
4. **Share improvements** - Consider contributing back generalizable enhancements

---

## License

These protocols and agent definitions are provided as templates for your use. Customize freely for your projects.

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.0 | 2025-10-17 | Updated README with comprehensive file explanations and repository structure |
| 1.0 | 2025-10-10 | Initial release with 13 protocols and 6 agent definitions |

---

**Repository**: https://github.com/laird/agents
**Status**: Production-validated
**Applicability**: Universal (all software projects)
**Original Context**: .NET Framework Migration
**Maintained By**: AI-assisted development community
