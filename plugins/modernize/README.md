# Modernize Plugin (Claude Code)

Complete modernization workflow with multi-agent orchestration.

## Compatibility Notice

**This plugin is primarily developed for personal use.** While it should work on Linux, macOS, and WSL, there are no guarantees. Use at your own risk.

**Tested Platforms:**
- Linux, macOS, WSL (Windows Subsystem for Linux)
- Windows (native) is **not** supported

## Installation

```bash
# Add the plugin marketplace (one-time setup)
/plugin add-registry https://github.com/laird/agents

# Install the modernize plugin
/plugin install modernize
```

## Commands

Each command is a comprehensive protocol document containing agent coordination, workflows, quality gates, and best practices.

| Command | Description | Output |
|---------|-------------|--------|
| `/assess` | Evaluate modernization viability (8 dimensions) | `ASSESSMENT.md` |
| `/plan` | Create detailed execution strategy (phases, timeline, resources) | `PLAN.md` |
| `/modernize` | Execute 7-phase modernization with 6 specialist agents | Modernized codebase |
| `/retro` | Analyze project history for process improvements | `IMPROVEMENTS.md` |
| `/retro-apply` | Apply approved retrospective recommendations | Updated protocols |
| `/modernize-help` | Show workflow overview and help | — |

## Quick Start

```bash
/assess          # 1. Evaluate viability → ASSESSMENT.md
/plan            # 2. Create execution strategy → PLAN.md
/modernize       # 3. Execute modernization (7 phases, 6 agents)
/retro           # 4. (Optional) Analyze for improvements → IMPROVEMENTS.md
/retro-apply     # 5. (Optional) Apply approved improvements
```

## Specialist Agents

The modernize plugin includes 6 specialized agents invoked by Claude Code's Task tool:

| Agent | Role | Active Phases |
|-------|------|---------------|
| **Migration Coordinator** | Strategic oversight, agent coordination, quality gate enforcement | All phases |
| **Security** | CVE scanning, security scoring, vulnerability remediation | Phase 1 (blocks on CRITICAL/HIGH) |
| **Architect** | Technology research, ADR creation (MADR 3.0.0 format) | Phases 1-2 |
| **Coder** | Framework updates, API replacement, build fixes | Phases 3-4 |
| **Tester** | 6-phase testing protocol, fix-and-retest cycles | After every code change |
| **Documentation** | HISTORY.md logging, ADRs, migration guides, changelogs | Continuous |

## Quality Gates

- **Security**: Score ≥45/100 before migration starts
- **Build**: 100% success before next stage
- **Tests**: 100% pass rate before proceeding
- **Issues**: All P0/P1 resolved before release

## Modernization Phases

1. Discovery & Planning
2. Security Assessment
3. Architecture Decisions
4. Framework Upgrade
5. API Modernization
6. Performance Optimization
7. Documentation

## Production Results

- **32/32 projects** migrated successfully (100% success rate)
- **100% test pass rate** achieved
- **Security improvement**: 0/100 → 45/100 (CRITICAL CVEs eliminated)
- **Zero P0/P1** blocking issues in production
- **1,500+ lines** of documentation auto-generated
