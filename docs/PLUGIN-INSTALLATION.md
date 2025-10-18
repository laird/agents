# Agent Protocols Claude Code Plugin Installation Guide

## Overview

This repository provides production-validated agent protocols, definitions, and automation frameworks packaged as Claude Code plugins. Install these plugins to enhance your Claude Code environment with systematic AI-assisted software development capabilities.

## Available Plugins

### 1. Complete Agent Protocols Suite
**Plugin Name**: `agent-protocols-complete`

Complete suite including all 9 protocols, 6 specialized agents, and 5 automation scripts.

**Features**:
- 6 specialized agents (Coordinator, Architect, Coder, Tester, Documentation, Security)
- 9 production-validated protocols
- 5 automation scripts
- Multi-agent coordination
- Quality gates and validation
- Comprehensive audit trail

**Install**:
```bash
claude plugin install github:laird/agents#agent-protocols-complete
```

### 2. SPARC Development Workflow
**Plugin Name**: `sparc-workflow`

SPARC (Specification, Pseudocode, Architecture, Refinement, Completion) methodology with TDD workflow.

**Features**:
- 5-phase SPARC framework
- Test-Driven Development integration
- Slash commands for workflow execution
- Parallel and pipeline execution modes

**Install**:
```bash
claude plugin install github:laird/agents#sparc-workflow
```

**Commands**:
- `/sparc-modes` - List all available SPARC modes
- `/sparc-run <mode> "<task>"` - Execute specific SPARC mode
- `/sparc-tdd "<feature>"` - Run complete TDD workflow
- `/sparc-batch <modes> "<task>"` - Execute modes in parallel
- `/sparc-pipeline "<task>"` - Run full SPARC pipeline

### 3. Comprehensive Testing Framework
**Plugin Name**: `testing-framework`

6-phase testing protocol with automated validation and quality gates.

**Features**:
- 6 testing phases (Pre-test, Unit, Integration, Component, Performance, Samples)
- Fix-and-retest cycles (max 3 iterations)
- Quality gates (≥95% unit, ≥90% integration pass rates)
- Test baseline tracking for regression detection
- Automated validation scripts

**Install**:
```bash
claude plugin install github:laird/agents#testing-framework
```

### 4. Systematic Documentation System
**Plugin Name**: `documentation-system`

Complete documentation framework with automated generation and incremental updates.

**Features**:
- HISTORY.md logging with 7 templates
- ADR lifecycle (7 stages, MADR 3.0.0 format)
- Incremental documentation protocol
- Automated CHANGELOG and migration guide generation
- Documentation planning templates

**Install**:
```bash
claude plugin install github:laird/agents#documentation-system
```

### 5. Security Assessment & Remediation
**Plugin Name**: `security-scanner`

CVE vulnerability scanning with prioritized remediation and blocking quality gates.

**Features**:
- CVE vulnerability detection
- Security score calculation (0-100 scale)
- Prioritized remediation plans
- Blocking quality gates for CRITICAL/HIGH vulnerabilities
- Compliance validation

**Install**:
```bash
claude plugin install github:laird/agents#security-scanner
```

### 6. Architecture Decision Advisor
**Plugin Name**: `architecture-advisor`

Technology research, pattern selection, and ADR creation.

**Features**:
- Technology research and evaluation
- Architectural pattern selection
- Trade-off analysis (performance, scalability, maintainability, cost)
- ADR creation (MADR 3.0.0 format)
- Decision documentation and tracking

**Install**:
```bash
claude plugin install github:laird/agents#architecture-advisor
```

## Installation Methods

### Method 1: Install from GitHub (Recommended)

Install individual plugins:
```bash
claude plugin install github:laird/agents#<plugin-name>
```

Install the complete suite:
```bash
claude plugin install github:laird/agents#agent-protocols-complete
```

### Method 2: Install from Local Repository

1. Clone the repository:
```bash
git clone https://github.com/laird/agents.git
cd agents
```

2. Install plugins:
```bash
claude plugin install ./.claude-plugin/plugins/<plugin-name>
```

### Method 3: Add as Marketplace

Add the entire marketplace to your Claude Code:
```bash
claude marketplace add github:laird/agents
```

Then browse and install plugins:
```bash
claude plugin browse agent-protocols-marketplace
claude plugin install <plugin-name>
```

## Usage Examples

### Complete Agent Protocols Suite

```bash
# Install the complete suite
claude plugin install github:laird/agents#agent-protocols-complete

# Use the migration coordinator
claude agent spawn migration-coordinator \
  --task "Coordinate multi-stage .NET migration" \
  --output "migration-plan.md"

# Use the architect agent
claude agent spawn architect-agent \
  --task "Research logging frameworks and create ADR" \
  --output "docs/ADR/ADR 0001 Logging Framework.md"

# Use automation scripts
./scripts/append-to-history.sh \
  "Stage 1 Complete" \
  "Migrated core libraries to .NET 9" \
  "Enable modern framework features" \
  "All tests passing (96.4% pass rate)"
```

### SPARC Workflow

```bash
# Install SPARC workflow
claude plugin install github:laird/agents#sparc-workflow

# List available modes
/sparc-modes

# Run specification phase
/sparc-run spec-pseudocode "User authentication system"

# Run complete TDD workflow
/sparc-tdd "Add OAuth2 authentication"

# Execute parallel batch
/sparc-batch "spec-pseudocode architect" "Payment processing system"

# Run full pipeline
/sparc-pipeline "Implement real-time notifications"
```

### Testing Framework

```bash
# Install testing framework
claude plugin install github:laird/agents#testing-framework

# Spawn tester agent
claude agent spawn tester-agent \
  --task "Execute comprehensive test suite" \
  --criteria "pass_rate >= 95%"

# Capture test baseline
./scripts/capture-test-baseline.sh

# Run stage tests
./scripts/run-stage-tests.sh stage-1 --strict

# Validate migration stage
./scripts/validate-migration-stage.sh stage-1
```

### Documentation System

```bash
# Install documentation system
claude plugin install github:laird/agents#documentation-system

# Spawn documentation agent
claude agent spawn documentation-agent \
  --task "Create migration guide for v2.0" \
  --output "docs/MIGRATION-GUIDE.md"

# Log to HISTORY.md
./scripts/append-to-history.sh \
  "Feature Implementation Complete" \
  "Implemented user profile management" \
  "Enable user customization" \
  "Tests passing, docs updated"
```

### Security Scanner

```bash
# Install security scanner
claude plugin install github:laird/agents#security-scanner

# Spawn security agent
claude agent spawn security-agent \
  --task "Scan for CVE vulnerabilities and create remediation plan" \
  --output "security-assessment.md"
```

### Architecture Advisor

```bash
# Install architecture advisor
claude plugin install github:laird/agents#architecture-advisor

# Spawn architect agent
claude agent spawn architect-agent \
  --task "Research message queue alternatives and recommend solution" \
  --output "docs/ADR/ADR 0003 Message Queue Selection.md"
```

## Multi-Agent Workflows

### Sequential Pipeline

```bash
# 1. Security scan first (blocks until resolved)
claude agent spawn security-agent --blocking

# 2. Architecture decisions
claude agent spawn architect-agent

# 3. Implementation
claude agent spawn coder-agent

# 4. Testing and validation
claude agent spawn tester-agent --criteria "pass_rate >= 95%"

# 5. Documentation
claude agent spawn documentation-agent
```

### Parallel Execution

```bash
# Initialize swarm for parallel execution
claude-flow swarm init --topology mesh --agents 3

# Assign tasks to parallel coder agents
claude-flow task assign agent-1 "Migrate core libraries"
claude-flow task assign agent-2 "Migrate API projects"
claude-flow task assign agent-3 "Migrate test projects"

# Single tester validates all changes
claude agent spawn tester-agent --validate-all
```

## Requirements

- **Claude Code**: ≥2.0.0
- **npm**: ≥8.0.0 (for SPARC workflow)
- **Git**: For repository-based installation
- **claude-flow**: For multi-agent orchestration (optional)

## Configuration

### CLAUDE.md Integration

Add to your project's `CLAUDE.md` or `.claude/settings.json`:

```markdown
## Agent Protocols Configuration

### Installed Plugins
- agent-protocols-complete (v2.0.0)
- sparc-workflow (v2.0.0)
- testing-framework (v2.0.0)

### Quality Gates
- Unit test pass rate: ≥95%
- Integration test pass rate: ≥90%
- Security score: ≥45
- Build success: 100%

### Logging
All agent activities logged to HISTORY.md using:
./scripts/append-to-history.sh "<title>" "<what>" "<why>" "<impact>"
```

## Troubleshooting

### Plugin Not Found

If installation fails with "plugin not found":

1. Verify the repository is accessible:
```bash
git clone https://github.com/laird/agents.git
```

2. Install from local clone:
```bash
cd agents
claude plugin install ./.claude-plugin/plugins/<plugin-name>
```

### Missing Dependencies

If SPARC workflow commands fail:

```bash
npm install -g claude-flow@alpha
```

### Permission Issues

If scripts are not executable:

```bash
chmod +x scripts/*.sh
```

## Updates

Check for plugin updates:

```bash
claude plugin update agent-protocols-complete
```

Update all plugins:

```bash
claude plugin update --all
```

## Uninstallation

Remove individual plugin:

```bash
claude plugin uninstall <plugin-name>
```

Remove all plugins from this marketplace:

```bash
claude plugin uninstall agent-protocols-complete sparc-workflow testing-framework documentation-system security-scanner architecture-advisor
```

## Support

- **Documentation**: See `00-PROTOCOL-INDEX.md` for protocol navigation
- **Issues**: https://github.com/laird/agents/issues
- **Validation**: See `VALIDATION-REPORT.md` for file integrity
- **Examples**: Each agent YAML includes usage examples

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.0.0 | 2025-10-18 | Claude Code plugin marketplace release |
| 1.0.0 | 2025-10-10 | Initial protocol and agent definitions |

## License

MIT - See LICENSE file for details

## Contributing

See README.md for contribution guidelines and customization instructions.

---

**Production-Validated**: 100% success rate across 32/32 project migrations
**Test Coverage**: 96.4% pass rate (exceeds 95% threshold)
**Security**: CRITICAL CVEs eliminated (0 → 45/100 security score)
**Documentation**: 1,500+ lines auto-generated
