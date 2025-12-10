# Agent Protocols - Claude Code Plugins

A **Claude Code plugin marketplace** providing production-validated protocols, specialized agents, and automation frameworks for systematic AI-assisted software development.

## Overview

This marketplace contains **2 plugins** with complementary capabilities:

1. **Modernize** - Complete modernization workflow (assess → plan → execute → improve) with 6 specialized agents
2. **Autofix** - Autonomous GitHub issue resolution with intelligent testing and quality automation

Both plugins feature **continuous improvement** through retrospective analysis and are **universally applicable** to any software project. Originally created for .NET framework migrations, these tools work with any language or platform.

---

## Installation

### Add Marketplace

```bash
/plugin add marketplace https://github.com/laird/agents
```

### Install Plugins

**Install modernize plugin** (software modernization workflows):

```bash
/plugin install modernize
```

**Install autofix plugin** (autonomous GitHub issue resolution):

```bash
/plugin install autofix
```

**Install both plugins**:

```bash
/plugin install modernize autofix
```

After installation, commands will be available as slash commands in Claude Code:

- **modernize**: `/assess`, `/plan`, `/modernize`, `/retro`, `/retro-apply`
- **autofix**: `/fix-github`

---

## Antigravity Support

This repository is **Antigravity-native**. It includes the `.agent/` directory containing all agent rules and workflows, making it compatible with the Antigravity engine out of the box.

### Usage in this Repository

No installation is required. You can run workflows immediately using Antigravity commands (e.g., `assess`, `plan`, `modernize`, `retro`, `fix-github`).

### Installation in Other Projects

To "install" these agents into another project:

1. Copy the `.agent/` directory from this repository to the root of your target project.
2. (Windows Only) Ensure you have a Bash environment (Git Bash or WSL) available for workflows that use shell commands.
3. Start using the workflows immediately.

---

## Plugins

### Plugin 1: Modernize

Complete modernization workflow with multi-agent orchestration.

#### 5 Protocol-Based Commands

Each command is a comprehensive protocol document (`.md` file) containing agent coordination, workflows, quality gates, and best practices:

- **`/assess`** - Assessment protocol with viability evaluation (outputs `ASSESSMENT.md`)
  - 8 assessment dimensions, scoring methodology, recommendation matrix
  - Do this first to assess software for potential modernization

- **`/plan`** - Planning protocol with detailed execution strategy (outputs `PLAN.md`)
  - Phase breakdown, timeline estimation, risk management, resource allocation
  - Do this to propose a modernization plan

- **`/modernize`** - Full modernization protocol with 7-phase workflow
  - Coordinates 6 specialist agents through Discovery → Security → Architecture → Framework → API → Performance → Documentation
  - Do this to execute the plan. If there is no plan it will generate a plan and then execute it.

- **`/retro`** - Retrospective protocol analyzing project history (outputs `IMPROVEMENTS.md`)
  - Reviews git history, user corrections, agent mistakes, protocol inefficiencies
  - Do this after execution to assess how the project went and make improvement recommendations for future projects. This is optional.

- **`/retro-apply`** - Improvement application protocol
  - Systematically updates commands, protocols, and automation based on retrospective findings
  - Do this after `/retro` if you agree with the recommendations.

#### Quick Start

1. **Assess Viability**

   ```
   /assess
   ```

   Evaluates technical debt, risks, and ROI. Outputs `ASSESSMENT.md`.

2. **Create Plan**

   ```
   /plan
   ```

   Develops detailed execution strategy with phases, timeline, and resources. Outputs `PLAN.md`.

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

#### Specialist Agents

The modernize plugin includes 6 specialized agents invoked by Claude Code's Task tool:

- **Architect** makes technology decisions and creates ADRs
- **Security** scans for vulnerabilities and blocks on CRITICAL/HIGH issues
- **Coder** implements migrations and fixes
- **Tester** validates with comprehensive test suites (100% pass rate required)
- **Documentation** generates user-facing guides and changelogs
- **Migration Coordinator** orchestrates multi-stage workflows

---

### Plugin 2: Autofix

Autonomous GitHub issue resolution with intelligent testing and quality automation.

#### The Command

**`/fix-github`** - Autonomous issue resolution workflow that:

- Automatically prioritizes GitHub issues using P0-P3 labels
- Detects issue complexity (simple vs complex)
- Uses superpowers skills for complex problems
- Runs regression tests when no issues exist
- Creates improvement proposals when all tests pass
- Self-configures from project's `CLAUDE.md`

**Key Features:**

- Works with any test framework (Jest, Playwright, pytest, etc.)
- Auto-creates configuration if missing
- GitHub integration for test failure tracking
- Priority-based workflow (P0 → P1 → P2 → P3)
- Continuous quality improvement

#### Quick Start

**Usage:**

```
/fix-github
```

**First Run:** Automatically adds this configuration to your `CLAUDE.md`:

```markdown
## Automated Testing & Issue Management

### Regression Test Suite
```bash
npm run test:regression
```

### Build Verification

```bash
npm run build
```

```

**Workflow:**
1. Creates priority labels (P0-P3) if needed
2. Finds highest priority issue
3. Fixes it (uses superpowers for complex issues)
4. Runs tests to verify
5. Commits and closes issue
6. Moves to next issue
7. If no issues: runs full regression test suite
8. Creates GitHub issues from test failures

#### Configuration (Optional)

Customize the auto-generated configuration in your `CLAUDE.md`:
- Update test commands for your project
- Specify test framework details
- Configure report locations
- Define priority patterns

---
## Repository Structure
---

agents/
├── .claude-plugin/                      # Plugin marketplace configuration
│   ├── marketplace.json                 # Marketplace metadata (2 plugins)
│   └── plugins/
│       ├── modernize/
│       │   └── plugin.json              # Modernize plugin definition
│       └── autofix/
│           └── plugin.json              # Autofix plugin definition
├── plugins/                             # Plugin implementations
│   ├── modernize/                       # Modernize plugin (5 commands, 6 agents, protocols)
│   │   ├── commands/
│   │   │   ├── assess.md               # Assessment protocol
│   │   │   ├── plan.md                 # Planning protocol
│   │   │   ├── modernize.md            # Full modernization workflow
│   │   │   ├── retro.md                # Retrospective analysis
│   │   │   └── retro-apply.md          # Improvement application
│   │   ├── agents/
│   │   │   ├── architect.md            # Technology decisions and ADRs
│   │   │   ├── coder.md                # Implementation and fixes
│   │   │   ├── documentation.md        # User-facing guides
│   │   │   ├── migration-coordinator.md # Multi-stage orchestration
│   │   │   ├── security.md             # Vulnerability scanning
│   │   │   └── tester.md               # Comprehensive testing
│   │   └── protocols/                   # Protocol documentation (10 protocols)
│   │       ├── 00-PROTOCOL-INDEX.md    # Protocol index
│   │       ├── adr-lifecycle.md        # ADR lifecycle protocol
│   │       ├── agent-logging.md        # Agent logging protocol
│   │       ├── agents-overview.md      # Agents overview
│   │       ├── documentation-plan.md   # Documentation planning
│   │       ├── documentation-protocol.md # Documentation protocol
│   │       ├── incremental-documentation.md # Incremental docs
│   │       ├── protocols-overview.md   # Protocols overview
│   │       ├── security-scanning-protocol.md # Security scanning
│   │       └── testing-protocol.md     # Testing protocol
│   └── autofix/                         # Autofix plugin (1 command, 6 agents, 1 script)
│       ├── commands/
│       │   └── fix-github.md           # Autonomous issue resolution
│       ├── agents/
│       │   ├── architect.md            # Technology decisions and ADRs
│       │   ├── coder.md                # Implementation and fixes
│       │   ├── documentation.md        # User-facing guides
│       │   ├── migration-coordinator.md # Multi-stage orchestration
│       │   ├── security.md             # Vulnerability scanning
│       │   └── tester.md               # Comprehensive testing
│       └── scripts/
│           └── regression-test.sh      # Full test suite with GitHub integration
└── README.md
```

**Structure Notes**:

- **Parallel plugin architecture**: Each plugin has its own commands/, agents/, and scripts/
- **Complete separation**: Plugins are independent and can be installed individually
- **Shared agent definitions**: Both plugins include the same 6 specialized agents (architecture, coder, documentation, migration-coordinator, security, tester)
- **Self-contained**: Each plugin can evolve independently without affecting the other

---

## Key Features

### Production-Validated Protocols

- ✅ **Proven results** - Successfully guided 32/32 project migrations
- ✅ **Universal applicability** - Works with any software project, not just .NET
- ✅ **Complete audit trail** - HISTORY.md logging for all agent activities
- ✅ **Quality gates** - Automated validation at each stage
- ✅ **Evidence-based evolution** - Protocols continuously improved through retrospective analysis

### Multi-Agent Coordination

- 🤖 **6 specialized agents** - Each with defined capabilities and responsibilities
- 🔄 **Parallel execution** - Multiple agents work independently on separate tasks
- 📊 **Enforced quality** - 100% test pass rate, security score ≥45/100
- 📝 **Systematic workflows** - 7-phase migration, 6-phase testing, 8-stage ADR lifecycle

### Continuous Improvement

- 🔍 **Retrospective analysis** - Analyzes git history, user corrections, agent mistakes
- 📈 **Evidence-based recommendations** - 3-5 specific improvements with quantified impact
- 🔧 **Automated application** - Updates commands, protocols, and automation
- 🎯 **Learning from mistakes** - Identifies wrong tool usage, wasted effort, requirement misunderstandings
- ♻️ **Self-improving system** - Each project makes the next one better
- ⏱️ **Measurable impact** - Recent improvements saved 27 hours per project

### Real-World Results

- **32/32 projects** migrated successfully (100% success rate)
- **100% test pass rate** (meets requirement)
- **Security improvement** from 0/100 → 45/100 (CRITICAL CVEs eliminated)
- **Zero P0/P1** blocking issues in production
- **1,500+ lines** of documentation auto-generated

### Recent Protocol Improvements (Nov 2025)

Based on retrospective analysis of RawRabbit modernization, 5 evidence-based improvements were implemented:

1. **Front-Load Test Environment Setup** ⚡
   - Phase 0 test setup now mandatory before any work begins
   - Verified baseline metrics (build, tests, vulnerability scan) replace estimates
   - Prevents "works on my machine" issues discovered too late

2. **Spike-Driven ADR Process** 🧪
   - New Stage 2.5 for high-risk architectural decisions
   - Requires empirical validation via spike branches before commitment
   - 24-48hr stakeholder review period enforced
   - Better decisions through evidence vs. desk research

3. **Shift Security Validation Left** 🔒
   - New automated security scanning protocol
   - Phase 0 baseline scan, continuous monitoring throughout project
   - Security scores calculated from actual scans, never estimated
   - Critical/High CVEs blocked earlier in workflow

4. **Continuous Testing Strategy** ✅
   - Testing after EVERY stage, not delayed until Stage 4
   - Tiered testing: Unit → Component → Integration → Performance
   - Estimated 7 hours saved per project from early issue detection
   - Issues found in Stage 1 vs Stage 4 dramatically cheaper to fix

5. **Incremental Documentation** 📝
   - Status marker system: ⚠️ In Progress → ✅ Fixed (validated) → 📝 Documented
   - "Fixed" claims only after test validation passes
   - Prevents aspirational documentation requiring corrective commits
   - Accurate HISTORY.md audit trail

**Combined Impact**: 27 hours saved per project, earlier issue detection, verified (not estimated) security posture, empirical architectural decisions, and accurate documentation.

---

## Best Practices

**Modernization Workflow:**

1. `/assess` → `/plan` → `/modernize` → `/retro` → `/retro-apply`
2. Monitor HISTORY.md for complete audit trail
3. Review `IMPROVEMENTS.md` and apply approved changes
4. Next project benefits from lessons learned

**Quality Gates:**

- Security score ≥45 before migration starts
- Build success 100% before next stage
- Test pass rate 100% before proceeding
- All P0/P1 issues resolved before release

**Autofix Workflow:**

1. Run `/fix-github` to start autonomous issue resolution
2. Customize configuration in `CLAUDE.md` as needed
3. Let it run continuously for ongoing quality improvement

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
| 3.0.0 | 2025-11-24 | **Added autofix plugin**: Autonomous GitHub issue resolution with `/fix-github` command. Self-configuring via `CLAUDE.md`, works with any test framework. Includes regression-test.sh script with GitHub integration. Marketplace now contains 2 plugins (modernize + autofix) |
| 2.6.0 | 2025-11-09 | Applied 5 evidence-based improvements from RawRabbit retrospective: front-load test setup, spike-driven ADRs, shift security left, continuous testing, incremental documentation. Impact: 27 hours saved per project |
| 2.5.0 | 2025-11-01 | Added continuous improvement workflow: `/retro` and `/retro-apply` commands for retrospective analysis and automated application of lessons learned |
| 2.4.2 | 2025-10-28 | Renamed `/modernize:project` to `/modernize`, removed agents/protocols/scripts in favor of streamlined commands |
| 2.4.1 | 2025-10-25 | Removed cost estimates, added time estimate disclaimers |
| 2.4.0 | 2025-10-25 | Added complete modernization workflow (assess → plan → execute) |
| 2.3.0 | 2025-10-25 | Added /modernize-project multi-agent orchestrator |
| 2.2.0 | 2025-10-25 | Restructured as Claude Code plugin |
| 1.0 | 2025-10-10 | Initial release with protocols and agent definitions |

---

## References

- **Repository**: <https://github.com/laird/agents>
- **MADR 3.0.0**: <https://adr.github.io/madr/> - ADR format specification
- **Keep a Changelog**: <https://keepachangelog.com/> - CHANGELOG format
- **Claude Code Docs**: <https://docs.claude.com/en/docs/claude-code/>

---

## License

MIT License - See repository for details

---

**Status**: Production-validated
**Applicability**: Universal (all software projects)
**Original Context**: .NET Framework Migration
**Maintained By**: AI-assisted development community
