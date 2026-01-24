# Modernize Plugin Help

The **Modernize** plugin provides a complete workflow for systematic software modernization with multi-agent orchestration.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    MODERNIZE WORKFLOW                           │
│                                                                 │
│   /assess  →  /plan  →  /modernize  →  /retro  →  /retro-apply │
│                                                                 │
│   Evaluate    Create     Execute       Analyze     Apply        │
│   viability   strategy   migration     results     learnings    │
└─────────────────────────────────────────────────────────────────┘
```

## Commands

### Primary Workflow (in order)

| Command | Purpose | Output |
|---------|---------|--------|
| `/assess` | Evaluate modernization viability | `ASSESSMENT.md` |
| `/plan` | Create detailed execution strategy | `PLAN.md` |
| `/modernize` | Execute multi-phase modernization | Migrated codebase |
| `/retro` | Analyze project for improvements | `IMPROVEMENTS.md` |
| `/retro-apply` | Apply retrospective findings | Updated protocols |

### Detailed Command Descriptions

**`/assess`** - Assessment Protocol
- Evaluates project across 8 dimensions (complexity, risk, effort, etc.)
- Generates viability score and recommendations
- Identifies blockers and dependencies
- **Do this first** to understand what you're working with

**`/plan`** - Planning Protocol
- Creates phased execution strategy
- Estimates timeline and resources
- Identifies risks and mitigations
- **Do this second** to have a roadmap

**`/modernize`** - Execution Protocol
- Orchestrates 6 specialist agents through 7 phases:
  1. Discovery & Planning
  2. Security Assessment
  3. Architecture Decisions
  4. Framework Upgrade
  5. API Modernization
  6. Performance Optimization
  7. Documentation
- **Do this third** to execute the migration

**`/retro`** - Retrospective Protocol
- Analyzes git history and agent behavior
- Identifies user corrections and mistakes
- Generates 3-5 improvement recommendations
- **Do this after completion** (optional but recommended)

**`/retro-apply`** - Improvement Protocol
- Applies approved recommendations
- Updates commands and protocols
- Adds automation where beneficial
- **Do this to improve future projects**

## Specialist Agents

The `/modernize` command coordinates these agents:

| Agent | Role | When Active |
|-------|------|-------------|
| **Migration Coordinator** | Orchestration, quality gates | Throughout |
| **Security** | CVE scanning, vulnerability fixes | Phase 2 (blocker) |
| **Architect** | Technology decisions, ADRs | Phases 1-3 |
| **Coder** | Implementation, migrations | Phases 4-5 |
| **Tester** | Validation, test coverage | After every change |
| **Documentation** | Guides, changelogs, ADRs | Continuous |

## Quality Gates

The workflow enforces these quality gates:

- **Security**: Score ≥45/100 before migration starts
- **Build**: 100% success before next phase
- **Tests**: 100% pass rate before proceeding
- **Issues**: All P0/P1 resolved before release

## Quick Start Examples

**Full modernization workflow:**
```
/assess
# Review ASSESSMENT.md, proceed if viable

/plan
# Review PLAN.md, adjust if needed

/modernize
# Agents execute the migration

/retro
# Review IMPROVEMENTS.md

/retro-apply
# Apply approved improvements
```

**Skip assessment (already know scope):**
```
/plan
/modernize
```

**Just execute (have existing plan):**
```
/modernize
```

## Use Cases

- Framework upgrades (.NET, Node.js, Python, Java)
- Cloud migrations (AWS, Azure, GCP)
- Language migrations (Java→Kotlin, JS→TypeScript)
- Database migrations (SQL→NoSQL, version upgrades)
- Monolith to microservices
- Security remediation
- Legacy modernization

## Tips

1. **Always start with `/assess`** for unfamiliar codebases
2. **Review generated documents** before proceeding to next step
3. **Monitor HISTORY.md** for audit trail of all changes
4. **Run `/retro` after completion** to capture learnings
5. **Quality gates are enforced** - don't skip them

## See Also

- `/autocoder-help` - Help for the Autocoder plugin
- `plugins/modernize/protocols/` - Detailed protocol documentation
- `plugins/modernize/agents/` - Agent definitions
