# Modernize - Claude Code Plugin

A **Claude Code plugin** providing production-validated protocols, specialized agents, and automation frameworks for systematic AI-assisted software modernization and development.

## Overview

This plugin provides a complete modernization workflow (assess → plan → execute → improve) with 6 specialized agents and comprehensive protocol documentation. Features **continuous improvement** through retrospective analysis that learns from agent mistakes and user corrections. Originally created for .NET framework migrations, these tools are **universally applicable** to any software project requiring structured agent collaboration.

---

## Installation

**Install as Claude Code plugin**:

1. Clone this repository or copy the `commands/` directory to your project
2. Commands will be available as slash commands in Claude Code
3. Start with `/assess` to evaluate your project

---

## What's Included

### 5 Slash Commands
- **`/assess`** - Assess project viability for modernization (outputs `assessment.md`)
- **`/plan`** - Create detailed execution plan (outputs `plan.md`)
- **`/modernize`** - Orchestrate multi-agent modernization workflow
- **`/retro`** - Retrospective analysis to identify process improvements (outputs `IMPROVEMENTS.md`)
- **`/retro-apply`** - Apply approved process improvements from retrospective

### Comprehensive Documentation
Each command includes detailed protocols with:
- **Multi-agent coordination** - 6 specialist agents work together (Coordinator, Security, Architect, Coder, Tester, Documentation)
- **Phase-by-phase workflows** - Step-by-step execution with clear deliverables
- **Quality gates** - Automated validation and blocking criteria
- **Best practices** - Anti-patterns, troubleshooting, examples
- **Continuous improvement** - Retrospective analysis and automated application of lessons learned

---

## Quick Start

### Modernization Workflow

1. **Assess Viability**
   ```
   /assess
   ```
   Evaluates technical debt, risks, and ROI. Outputs `assessment.md`.

2. **Create Plan**
   ```
   /plan
   ```
   Develops detailed execution strategy with phases, timeline, and resources. Outputs `plan.md`.

3. **Execute Modernization**
   ```
   /modernize
   ```
   Orchestrates specialized agents through 7 phases:
   - Discovery & Planning
   - Security Assessment
   - Architecture Decisions
   - Framework Upgrade
   - API Modernization
   - Performance Optimization
   - Documentation

4. **Continuous Improvement (Optional)**
   ```
   /retro
   ```
   After project completion, analyzes history to identify process improvements. Reviews:
   - User interruptions and corrections
   - Agent behavioral issues (wrong tools, wasted effort)
   - Protocol inefficiencies
   - Automation opportunities

   Outputs `IMPROVEMENTS.md` with 3-5 evidence-based recommendations.

5. **Apply Improvements**
   ```
   /retro-apply
   ```
   Systematically applies approved recommendations from `IMPROVEMENTS.md`:
   - Updates command files with better agent behavior guidance
   - Modifies protocols to prevent recurring issues
   - Adds automation (scripts, hooks, CI/CD)
   - Embeds lessons learned into workflow

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
agents/
├── commands/                    # Slash commands (5 commands)
│   ├── assess.md               # Project assessment
│   ├── plan.md                 # Execution planning
│   ├── modernize.md            # Multi-agent orchestration
│   ├── retro.md                # Retrospective analysis
│   └── retro-apply.md          # Apply improvements
└── README.md
```

**Note**: This repository contains only command definitions. Agent definitions, protocols, and scripts have been removed in favor of the streamlined Claude Code plugin structure.

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

### Continuous Improvement
- 🔍 **Retrospective analysis** - Analyzes git history, user corrections, agent mistakes
- 📈 **Evidence-based recommendations** - 3-5 specific improvements with quantified impact
- 🔧 **Automated application** - Updates commands, protocols, and automation
- 🎯 **Learning from mistakes** - Identifies wrong tool usage, wasted effort, requirement misunderstandings
- ♻️ **Self-improving system** - Each project makes the next one better

### Real-World Results
- **32/32 projects** migrated successfully (100% success rate)
- **100% test pass rate** (meets requirement)
- **Security improvement** from 0/100 → 45/100 (CRITICAL CVEs eliminated)
- **Zero P0/P1** blocking issues in production
- **1,500+ lines** of documentation auto-generated

---

## Best Practices

### For New Projects
1. Install the plugin by copying `commands/` to your project
2. Run `/assess` to evaluate modernization readiness
3. Run `/plan` to create execution strategy
4. Run `/modernize` to orchestrate the work
5. Monitor HISTORY.md for complete audit trail
6. Run `/retro` after completion to identify improvements
7. Run `/retro-apply` to embed lessons learned

### Continuous Improvement Workflow
1. Complete a modernization project with `/modernize`
2. Run `/retro` to analyze what happened:
   - Reviews git history for user corrections
   - Identifies agent behavioral issues
   - Finds protocol inefficiencies
   - Quantifies impact of improvements
3. Review `IMPROVEMENTS.md` with team
4. Run `/retro-apply` to implement approved changes
5. Next project automatically benefits from improvements

### For Existing Projects
1. Install the plugin
2. Start with `/assess` to understand scope
3. Use `/plan` to create detailed execution strategy
4. Leverage multi-agent coordination with `/modernize`
5. Apply continuous improvement with `/retro` and `/retro-apply`

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
| 2.5.0 | 2025-11-01 | Added continuous improvement workflow: `/retro` and `/retro-apply` commands for retrospective analysis and automated application of lessons learned |
| 2.4.2 | 2025-10-28 | Renamed `/modernize:project` to `/modernize`, removed agents/protocols/scripts in favor of streamlined commands |
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
