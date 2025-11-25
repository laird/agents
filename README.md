# Agent Protocols - Claude Code Plugins

A **Claude Code plugin marketplace** providing production-validated protocols, specialized agents, and automation frameworks for systematic AI-assisted software development.

## Overview

This marketplace contains **2 plugins** with complementary capabilities:

1. **Modernize** - Complete modernization workflow (assess → plan → execute → improve) with 6 specialized agents
2. **Autofix** - Autonomous GitHub issue resolution with intelligent testing and quality automation

Both plugins feature **continuous improvement** through retrospective analysis and are **universally applicable** to any software project. Originally created for .NET framework migrations, these tools work with any language or platform.

---

## Installation

**Install as Claude Code plugin**:

1. Use the /plugin command in Claude Code
2. Add this repo as a marketplace
3. Install the plugin(s) you need:
   - **modernize** - For software modernization workflows
   - **autofix** - For autonomous GitHub issue resolution

Commands will be available as slash commands in Claude Code.

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

### What's Inside Each Protocol

Every command file includes:
- **Agent coordination instructions** - How 6 specialist agents work together (Migration Coordinator, Security, Architect, Coder, Tester, Documentation)
- **Phase-by-phase workflows** - Detailed steps with durations, deliverables, and success criteria
- **Quality gates** - Blocking criteria and validation checkpoints
- **Examples** - Real-world scenarios and usage patterns
- **Anti-patterns** - What NOT to do with explanations
- **Troubleshooting** - Common issues and solutions
- **Best practices** - Proven approaches and recommendations

---

## Quick Start

### Modernization Workflow

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

#### Using Agents

Agents are invoked by Claude Code's Task tool when needed. They work together following established protocols:

- **Architect** makes technology decisions and creates ADRs
- **Security** scans for vulnerabilities and blocks on CRITICAL/HIGH issues
- **Coder** implements migrations and fixes
- **Tester** validates with comprehensive test suites (100% pass rate required)
- **Documentation** generates user-facing guides and changelogs
- **Migration Coordinator** orchestrates multi-stage workflows

---

### Plugin 2: Autofix

Autonomous GitHub issue resolution with intelligent testing and quality automation.

#### 1 Command + Scripts

- **`/fix-github`** - Autonomous issue resolution workflow
  - Automatically prioritizes GitHub issues (P0-P3 labels)
  - Intelligent complexity detection (simple vs complex issues)
  - Uses superpowers skills for complex problems
  - Runs regression tests when no issues exist
  - Creates improvement proposals when all tests pass

#### Features

- **Self-Configuring**: Reads test/build commands from project's `CLAUDE.md`
- **Auto-Setup**: Creates configuration section if missing
- **Universal**: Works with any test framework (Jest, Playwright, pytest, etc.)
- **GitHub Integration**: Creates/updates issues from test failures
- **Priority-Based**: P0 (Critical) → P1 (High) → P2 (Medium) → P3 (Low)
- **Continuous Quality**: Never stops improving your codebase

#### Quick Start

1. **Run the command**:
   ```
   /fix-github
   ```

2. **First run**: If `CLAUDE.md` doesn't have autofix config, it's automatically added:
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

3. **Customize**: Update the commands in `CLAUDE.md` for your project

4. **Let it run**: The command will:
   - Create priority labels if needed
   - Find highest priority issue
   - Fix it (using superpowers for complex issues)
   - Run tests to verify
   - Commit and close issue
   - Move to next issue

5. **No issues?**: Runs full regression test suite and creates issues from failures

#### Configuration

Add this section to your project's `CLAUDE.md`:

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

### Test Framework Details
**Unit Tests**: Jest in `backend/src/**/*.test.ts`
**E2E Tests**: Playwright in `tests/e2e/**/*.spec.ts`
**Reports**: `docs/test/regression-reports/`
```

---

## Repository Structure

```
agents/
├── commands/                    # Slash commands (6 commands)
│   ├── assess.md               # Assessment protocol (modernize)
│   ├── plan.md                 # Planning protocol (modernize)
│   ├── modernize.md            # Full modernization protocol (modernize)
│   ├── retro.md                # Retrospective analysis (modernize)
│   ├── retro-apply.md          # Improvement application (modernize)
│   └── fix-github.md           # Autonomous issue resolution (autofix)
├── agents/                      # Agent definitions (6 agents)
│   ├── architect.md            # Technology decisions and ADRs
│   ├── coder.md                # Implementation and fixes
│   ├── documentation.md        # User-facing guides
│   ├── migration-coordinator.md # Multi-stage orchestration
│   ├── security.md             # Vulnerability scanning
│   └── tester.md               # Comprehensive testing
├── scripts/                     # Automation scripts
│   └── regression-test.sh      # Full test suite with GitHub integration
├── .claude-plugin/             # Plugin marketplace configuration
│   ├── plugin.json             # Main plugin definition
│   └── marketplace.json        # Marketplace metadata (2 plugins)
└── README.md
```

**Note**:
- Command files are comprehensive protocol documents with workflows, coordination, and best practices
- Scripts read configuration from project's `CLAUDE.md` for universal compatibility
- Both plugins share the same 6 specialized agents

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
