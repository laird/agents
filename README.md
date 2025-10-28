# Modernize - Claude Code Plugin

A **Claude Code plugin** providing production-validated protocols, specialized agents, and automation frameworks for systematic AI-assisted software modernization and development.

## Overview

This plugin provides a complete modernization workflow (assess → plan → execute) with 6 specialized agents and comprehensive protocol documentation. Originally created for .NET framework migrations, these tools are **universally applicable** to any software project requiring structured agent collaboration.

---

## Installation

**Install from Claude Code marketplace**:

```bash
# Add this repository as a Claude Code marketplace
claude plugin marketplace add "https://raw.githubusercontent.com/laird/agents/main/.claude-plugin/marketplace.json"

# Install the modernize plugin
claude plugin install modernize@agent-protocols-marketplace
```

---

## What's Included

### 3 Slash Commands
- **`/modernize:assess`** - Assess project viability for modernization (outputs `assessment.md`)
- **`/modernize:plan`** - Create detailed execution plan (outputs `plan.md`)
- **`/modernize:project`** - Orchestrate multi-agent modernization workflow

### 6 Specialized Agents
- **`modernize:architect`** - Architecture and design decisions, ADR creation
- **`modernize:coder`** - Code implementation and migration
- **`modernize:documentation`** - Documentation management and generation
- **`modernize:migration-coordinator`** - Multi-stage orchestration
- **`modernize:security`** - Security scanning and vulnerability fixes
- **`modernize:tester`** - Testing and validation with quality gates

### 13 Protocol Documents
Reference documentation for agents (located in `protocols/`):
- Testing Protocol (6-phase testing with 100% pass rate)
- Agent Logging Protocol (HISTORY.md audit trail)
- ADR Lifecycle Protocol (MADR 3.0.0 format)
- Documentation Protocol (unified documentation guide)
- And 9 more...

### 5 Automation Scripts
Shell utilities for automation (located in `scripts/`):
- `append-to-history.sh` - HISTORY.md logging utility
- `capture-test-baseline.sh` - Test baseline creation
- `run-stage-tests.sh` - Test execution
- `validate-migration-stage.sh` - Quality gate validation
- `analyze-dependencies.sh` - Dependency analysis

---

## Quick Start

### Modernization Workflow

1. **Assess Viability**
   ```
   /modernize:assess
   ```
   Evaluates technical debt, risks, and ROI. Outputs `assessment.md`.

2. **Create Plan**
   ```
   /modernize:plan
   ```
   Develops detailed execution strategy with phases, timeline, and resources. Outputs `plan.md`.

3. **Execute Modernization**
   ```
   /modernize:project
   ```
   Orchestrates specialized agents through 7 phases:
   - Discovery & Planning
   - Security Assessment
   - Architecture Decisions
   - Framework Upgrade
   - API Modernization
   - Performance Optimization
   - Documentation

### Using Agents

Agents are invoked by Claude Code's Task tool when needed. They work together following established protocols:

- **Architect** makes technology decisions and creates ADRs
- **Security** scans for vulnerabilities and blocks on CRITICAL/HIGH issues
- **Coder** implements migrations and fixes
- **Tester** validates with comprehensive test suites (100% pass rate required)
- **Documentation** generates user-facing guides and changelogs
- **Migration Coordinator** orchestrates multi-stage workflows

---

## Repository Structure

```
modernize/
├── .claude-plugin/
│   ├── plugin.json              # Plugin manifest
│   └── marketplace.json         # Marketplace definition
├── commands/                    # Slash commands
│   ├── modernize-assess.md
│   ├── modernize-plan.md
│   └── modernize-project.md
├── agents/                      # Agent definitions
│   ├── architect.md
│   ├── coder.md
│   ├── documentation.md
│   ├── migration-coordinator.md
│   ├── security.md
│   └── tester.md
├── protocols/                   # Protocol documentation (13 files)
│   ├── GENERIC-TESTING-PROTOCOL.md
│   ├── GENERIC-AGENT-LOGGING-PROTOCOL.md
│   ├── GENERIC-ADR-LIFECYCLE-PROTOCOL.md
│   └── ... (10 more)
├── scripts/                     # Automation utilities (5 files)
│   ├── append-to-history.sh
│   ├── capture-test-baseline.sh
│   └── ... (3 more)
└── README.md
```

---

## Key Features

### Production-Validated Protocols
- ✅ **Proven results** - Successfully guided 32/32 project migrations
- ✅ **Universal applicability** - Works with any software project, not just .NET
- ✅ **Complete audit trail** - HISTORY.md logging for all agent activities
- ✅ **Quality gates** - Automated validation at each stage

### Multi-Agent Coordination
- 🤖 **6 specialized agents** - Each with defined capabilities and responsibilities
- 🔄 **Parallel execution** - Multiple agents work independently on separate tasks
- 📊 **Enforced quality** - 100% test pass rate, security score ≥45/100
- 📝 **Systematic workflows** - 5-phase migration, 6-phase testing, 7-stage ADR lifecycle

### Real-World Results
- **32/32 projects** migrated successfully (100% success rate)
- **100% test pass rate** (meets requirement)
- **Security improvement** from 0/100 → 45/100 (CRITICAL CVEs eliminated)
- **Zero P0/P1** blocking issues in production
- **1,500+ lines** of documentation auto-generated

---

## Best Practices

### For New Projects
1. Install the plugin via Claude Code marketplace
2. Run `/modernize:assess` to evaluate modernization readiness
3. Run `/modernize:plan` to create execution strategy
4. Run `/modernize:project` to orchestrate the work
5. Monitor HISTORY.md for complete audit trail

### For Existing Projects
1. Install the plugin
2. Start with `/modernize:assess` to understand scope
3. Adopt protocols incrementally (logging → testing → documentation)
4. Customize protocols to your technology stack
5. Scale with multi-agent coordination patterns

### Quality Gates to Enforce
- Security score ≥45 before migration starts
- Build success 100% before next stage
- Test pass rate 100% before proceeding
- All P0/P1 issues resolved before release

---

## Use Cases

- **Framework Upgrades** - .NET, Node.js, Python, Java, etc.
- **Cloud Migrations** - AWS, Azure, GCP platform changes
- **Language Migrations** - Java to Kotlin, JavaScript to TypeScript
- **Database Migrations** - SQL to NoSQL, version upgrades
- **Legacy Modernization** - Monolith to microservices, API updates
- **Security Remediation** - CVE scanning and vulnerability fixes
- **Quality Assurance** - Comprehensive testing and validation
- **Documentation** - Technical docs, migration guides, ADRs

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.4.2 | 2025-10-28 | Renamed plugin to 'modernize', added agents field, removed YAML files, streamlined for Claude Code |
| 2.4.1 | 2025-10-25 | Removed cost estimates, added time estimate disclaimers |
| 2.4.0 | 2025-10-25 | Added complete modernization workflow (assess → plan → execute) |
| 2.3.0 | 2025-10-25 | Added /modernize-project multi-agent orchestrator |
| 2.2.0 | 2025-10-25 | Restructured as Claude Code plugin |
| 1.0 | 2025-10-10 | Initial release with protocols and agent definitions |

---

## References

- **Repository**: https://github.com/laird/agents
- **MADR 3.0.0**: https://adr.github.io/madr/ - ADR format specification
- **Keep a Changelog**: https://keepachangelog.com/ - CHANGELOG format
- **Claude Code Docs**: https://docs.claude.com/en/docs/claude-code/

---

## License

MIT License - See repository for details

---

**Status**: Production-validated
**Applicability**: Universal (all software projects)
**Original Context**: .NET Framework Migration
**Maintained By**: AI-assisted development community
