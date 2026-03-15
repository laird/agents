# Agent Protocols - Claude Code Plugins

A **Claude Code plugin marketplace** providing production-validated protocols, specialized agents, and automation frameworks for systematic AI-assisted software development.

## Overview

This marketplace contains **2 plugins** with complementary capabilities:

1. **Modernize** - Complete modernization workflow (assess → plan → execute → improve) with 6 specialized agents
2. **Autocoder** - Autonomous GitHub issue resolution with intelligent testing and quality automation

Both plugins feature **continuous improvement** through retrospective analysis and are **universally applicable** to any software project. Originally created for .NET framework migrations, these tools work with any language or platform.


## ⚠️ Compatibility Notice

**These plugins are primarily developed for personal use.** While they should work on Linux, macOS, and WSL (Windows Subsystem for Linux), there are no guarantees they will work in all environments. Use at your own risk.

**Tested Platforms:**
- ✅ Linux
- ✅ macOS
- ✅ WSL (Windows Subsystem for Linux)
- ❌ Windows (native) - Not supported

---

## Directory Guide

This repository supports multiple agentic platforms. Please refer to the corresponding directory and documentation for your platform:

| Platform | Directory | Documentation |
|----------|-----------|---------------|
| **Claude Code** | `.claude-plugin/` | [docs/CLAUDE-CODE.md](docs/CLAUDE-CODE.md) |
| **Antigravity** | `.agent/` | [docs/ANTIGRAVITY.md](docs/ANTIGRAVITY.md) |
| **OpenCode** | `agents/` | [docs/OPENCODE.md](docs/OPENCODE.md) |

Each platform has its own directory structure and installation method. See the platform-specific documentation for details.

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

**Install autocoder plugin** (autonomous GitHub issue resolution):

```bash
/plugin install autocoder
```

**Install both plugins**:

```bash
/plugin install modernize autocoder
```

After installation, commands will be available as slash commands in Claude Code:

- **modernize**: `/assess`, `/plan`, `/modernize`, `/retro`, `/retro-apply`, `/modernize-help`
- **autocoder**: `/fix`, `/fix-loop`, `/stop-loop`, `/monitor-workers`, `/list-proposals`, `/approve-proposal`, `/list-needs-design`, `/list-needs-feedback`, `/brainstorm-issue`, `/full-regression-test`, `/improve-test-coverage`, `/review-blocked`, `/install`, `/autocoder-help`

**Get help anytime:**
```bash
/modernize-help    # Overview of modernization workflow
/autocoder-help    # Overview of autonomous coding workflow
```

### Recommended Companion Plugins

These plugins enhance the capabilities of modernize and autocoder:

| Plugin | Purpose | When to Install |
|--------|---------|-----------------|
| **superpowers** | Structured problem-solving skills (debugging, planning, verification) | Recommended for complex issues requiring systematic approaches |
| **quint** | Structured reasoning for human-guided decision making | Recommended for ultra-complex decisions requiring human judgment |

**Install recommended plugins:**

```bash
# superpowers - for complex problem-solving
/plugin install superpowers

# quint - for ultra-complex decisions (https://quint.codes/)
/plugin install quint
```

**How they're used:**

- **superpowers**: Automatically invoked by `/fix` for complex issues (>10 test failures, multi-file changes, feature implementations). Provides systematic debugging, brainstorming, planning, and verification skills.

- **quint**: Automatically invoked for ultra-complex issues that exceed autonomous resolution capabilities (>100 test failures, major architecture decisions, irreversible consequences). Guides structured reasoning with human collaboration.

If these plugins are not installed, the workflows use direct problem-solving approaches instead.

---

## Antigravity Support

This repository is **Antigravity-native**. It includes the `.agent/` directory containing all agent rules and workflows, making it compatible with the Antigravity engine out of the box.

### Quick Install (One-Liner)

Run this command from your project's root directory:

```bash
curl -sSL https://raw.githubusercontent.com/laird/agents/main/scripts/install.sh | bash
```

This fetches only the `.agent/` directory and installs it into your project.

> [!NOTE]
> **Cross-Platform Compatibility**
>
> - **Linux/macOS**: Works natively
> - **Windows**: Requires [Git Bash](https://gitforwindows.org/) or WSL

### Manual Installation

Alternatively, copy or symlink the `.agent/` directory:

```bash
# Option 1: Copy
cp -r /path/to/agents/.agent /your/project/

# Option 2: Symlink (for development)
ln -s /path/to/agents/.agent /your/project/.agent
```

### Available Workflows

After installation, these workflows are available:

**Modernize Workflows:**

| Workflow | Description |
|----------|-------------|
| `/assess` | Evaluate modernization viability |
| `/plan` | Create execution strategy |
| `/modernize` | Execute multi-phase modernization |
| `/retro` | Analyze project for improvements |
| `/retro-apply` | Apply retrospective findings |
| `/modernize-help` | Show modernize workflow help |

**Autocoder Workflows:**

| Workflow | Description |
|----------|-------------|
| `/fix` | Autonomous issue resolution |
| `/fix-loop` | Continuous autonomous resolution |
| `/stop-loop` | Stop the continuous loop |
| `/list-proposals` | View pending AI-generated proposals |
| `/approve-proposal` | Approve a proposal for implementation |
| `/list-needs-design` | List issues needing design work |
| `/list-needs-feedback` | List issues needing feedback |
| `/brainstorm-issue` | Brainstorm design for an issue |
| `/full-regression-test` | Run comprehensive test suite |
| `/improve-test-coverage` | Analyze and improve test coverage |
| `/review-blocked` | Review and unblock issues labeled by fix-loop |
| `/monitor-workers` | Monitor workers, dispatch idle agents, deploy when done |
| `/install` | Install all autocoder plugin components |
| `/autocoder-help` | Show autocoder workflow help |

> [!WARNING]
> The watchdog scripts in `.agent/scripts/` are experimental. See [docs/ANTIGRAVITY.md](docs/ANTIGRAVITY.md) for details.

---

## Plugins

### Plugin 1: Modernize

Complete modernization workflow with multi-agent orchestration. See the [Modernize README](plugins/modernize/README.md) for full documentation.

**Get help:** `/modernize-help`

**Commands:** `/assess`, `/plan`, `/modernize`, `/retro`, `/retro-apply`

**Quick Start:** `/assess` → `/plan` → `/modernize` → `/retro` → `/retro-apply`

---

### Plugin 2: Autocoder

Autonomous GitHub issue resolution with intelligent testing, quality automation, multi-agent swarm support, and human-in-the-loop proposal system. See the [Autocoder README](plugins/autocoder/README.md) for full documentation.

**Get help:** `/autocoder-help`

**Commands:** `/fix`, `/fix-loop`, `/stop-loop`, `/monitor-workers`, `/review-blocked`, `/list-proposals`, `/approve-proposal`, `/list-needs-design`, `/list-needs-feedback`, `/brainstorm-issue`, `/full-regression-test`, `/improve-test-coverage`, `/install`

**Quick Start:**
```bash
/fix              # Fix highest priority issue
/install          # One-time setup for continuous mode
/fix-loop         # Run continuously
```

---
## Repository Structure
---

agents/
├── .agent/                              # Antigravity agent configuration (rules, workflows)
├── .claude-plugin/                      # Claude Code plugin configuration
│   ├── marketplace.json                 # Marketplace metadata (2 plugins)
│   └── plugins/
│       ├── modernize/
│       │   └── plugin.json              # Modernize plugin definition
│       └── autocoder/
│           └── plugin.json              # Autocoder plugin definition
├── plugins/                             # Plugin implementations
│   ├── modernize/                       # Modernize plugin (6 commands, 6 agents, protocols)
│   │   ├── commands/
│   │   │   ├── help.md                 # Plugin help and workflow overview
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
│   └── autocoder/                         # Autocoder plugin (12 commands)
│       ├── commands/
│       │   ├── help.md                 # Plugin help and workflow overview
│       │   ├── fix.md           # Autonomous issue resolution
│       │   ├── fix-loop.md      # Continuous autonomous resolution
│       │   ├── stop-loop.md            # Stop the continuous loop
│       │   ├── list-proposals.md       # View pending proposals
│       │   ├── approve-proposal.md     # Approve a proposal
│       │   ├── list-needs-design.md    # List issues needing design
│       │   ├── list-needs-feedback.md  # List issues needing feedback
│       │   ├── brainstorm-issue.md     # Brainstorm design for an issue
│       │   ├── full-regression-test.md # Run comprehensive test suite
│       │   ├── improve-test-coverage.md # Analyze and improve coverage
│       │   ├── review-blocked.md       # Review and unblock labeled issues
│       │   ├── monitor-workers.md     # Monitor workers, dispatch idle agents, deploy
│       │   └── install.md              # Install all plugin components
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

**Autocoder Workflow:**

1. Run `/autocoder-help` to see all available commands
2. Run `/fix` to start autonomous issue resolution
3. Use `/list-needs-design` and `/brainstorm-issue` for complex issues
4. Review proposals with `/list-proposals` and approve with `/approve-proposal`
5. For continuous operation: `/install` then `/fix-loop`

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
| 3.11.1 | 2026-03-05 | **Autocoder v3.6.3**: SRE monitoring workflow as idle fallback (production log scanning, engagement health checks, worker heartbeats, automated issue filing). Issue decomposition for complex `/fix` issues. `/review-blocked` command for parallel review sessions (supports needs-design, too-complex, proposal, future labels). `/install` command replaces `/install-stop-hook` (now installs all plugin components). `future` blocking label for deferred issues. Stop hook path auto-detection and duplicate prevention. |
| 3.4.0 | 2026-01-24 | **Autocoder v3.0.0**: Renamed `/fix-github` → `/fix`, `/fix-github-loop` → `/fix-loop`. Added design workflow commands (`/list-needs-design`, `/list-needs-feedback`, `/brainstorm-issue`). Added help commands (`/autocoder-help`, `/modernize-help`). Updated README with workflow patterns. |
| 3.3.0 | 2025-12-29 | **Proposal system & triage**: AI-generated enhancements now require human approval via `proposal` label. Added `/list-proposals` command, unprioritized issue triage, platform documentation (CLAUDE-CODE.md, ANTIGRAVITY.md, OPENCODE.md). All platforms updated to consistent v1.5.0 |
| 3.0.0 | 2025-11-24 | **Added autocoder plugin**: Autonomous GitHub issue resolution with `/fix` command. Self-configuring via `CLAUDE.md`, works with any test framework. Includes regression-test.sh script with GitHub integration. Marketplace now contains 2 plugins (modernize + autocoder) |
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
