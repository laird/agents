# Agent Protocols

A multi-platform repository of production-validated protocols, specialized agents, skills, and automation frameworks for systematic AI-assisted software development.

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
| **Claude Code** | `.claude-plugin/` and `plugins/` | [docs/CLAUDE-CODE.md](docs/CLAUDE-CODE.md) |
| **Antigravity** | `.agent/` | [docs/ANTIGRAVITY.md](docs/ANTIGRAVITY.md) |
| **Gemini CLI skill extensions** | `skills/` with per-skill `gemini-extension.json` and `GEMINI.md` | [skills/autocoder/README.md](skills/autocoder/README.md), [skills/modernize/README.md](skills/modernize/README.md) |
| **Codex** | `.codex-plugin/`, `codex-plugins/`, `skills/`, and `scripts/` | [docs/CODEX.md](docs/CODEX.md) |
| **OpenCode** | `agents/` | [docs/OPENCODE.md](docs/OPENCODE.md) |
| **Droid (Factory)** | `.factory/` and `.factory-plugin/` | [docs/DROID.md](docs/DROID.md) |

Each platform has its own directory structure and installation method. See the platform-specific documentation for details.

---

## Codex Support

Codex support is additive and does not replace the Claude Code or Antigravity / Gemini implementations.

#### Add Marketplace

```bash
/plugin add marketplace https://github.com/laird/agents
```

### Codex Skills

- `skills/autocoder/` - Codex-native entrypoint for autonomous GitHub issue workflows
- `skills/modernize/` - Codex-native entrypoint for modernization workflows

### Gemini CLI Skill Packaging

- `skills/autocoder/` - shared skill content plus `gemini-extension.json` and `GEMINI.md`
- `skills/modernize/` - shared skill content plus `gemini-extension.json` and `GEMINI.md`

### Codex Runtime Scripts

```bash
# Install Codex skills, aliases, and parallel-agent commands
bash scripts/install-codex.sh /path/to/target-repo

# Run one autocoder pass
bash scripts/codex-autocoder.sh fix

# Run the continuous fix loop
bash scripts/codex-fix-loop.sh

# Run the manager monitor loop
bash scripts/codex-monitor-loop.sh 15

# Stop running loops
bash scripts/codex-stop-loop.sh all

# Start a Codex swarm (defaults to tmux; pass `cmux` to override)
bash scripts/start-parallel-codex.sh 3
```

If you want shell aliases for Codex swarm startup, source [codex-shell-aliases.sh](scripts/codex-shell-aliases.sh) from your shell config. That gives you `startct`, `startcc`, `joinct`, and `joincc`.

See [docs/CODEX.md](docs/CODEX.md) for details.

---

## Droid (Factory) Support

Droid support is additive and does not replace the Claude Code, Antigravity / Gemini, or Codex implementations.

### Droid Skills

- `.factory/skills/autocoder/` - Droid-native entrypoint for autonomous GitHub issue workflows
- `.factory/skills/modernize/` - Droid-native entrypoint for modernization workflows

### Droid Custom Droids (Subagents)

Six specialist subagents in `.factory/droids/`: `architect`, `coder`, `documentation`, `migration-coordinator`, `security`, `tester`.

### Droid Runtime Scripts

```bash
# Install Droid skills, droids, aliases, and parallel-agent commands
bash scripts/install-droid.sh /path/to/target-repo

# Run one autocoder pass
bash scripts/droid-autocoder.sh fix

# Run the continuous fix loop
bash scripts/droid-fix-loop.sh

# Run the manager monitor loop
bash scripts/droid-monitor-loop.sh 15

# Stop running loops
bash scripts/droid-stop-loop.sh all

# Start a tmux-based Droid swarm
bash scripts/droid-start-parallel.sh tmux 3
```

If you want shell aliases for Droid swarm startup, source [droid-shell-aliases.sh](scripts/droid-shell-aliases.sh) from your shell config. That gives you `startdt`, `startdc`, `joindt`, and `joindc`.

See [docs/DROID.md](docs/DROID.md) for details.

---

## Shell Aliases — All Combinations

Source the alias files for the platforms you use. Each provides `start` and `join` aliases for both tmux and cmux.

| Agent | tmux | cmux | Alias file |
|-------|------|------|------------|
| Claude Code | `startclt` | `startclc` | [claude-shell-aliases.sh](scripts/claude-shell-aliases.sh) |
| Codex | `startct` | `startcc` | [codex-shell-aliases.sh](scripts/codex-shell-aliases.sh) |
| Gemini (Antigravity) | `startgt` | `startgc` | [gemini-shell-aliases.sh](scripts/gemini-shell-aliases.sh) |
| Droid (Factory) | `startdt` | `startdc` | [droid-shell-aliases.sh](scripts/droid-shell-aliases.sh) |

Install all aliases in one step (auto-detects which agent CLIs are installed):

```bash
bash /path/to/agents/scripts/install-shell-aliases.sh        # auto-detect
bash /path/to/agents/scripts/install-shell-aliases.sh --all  # all agents
source ~/.zshrc  # or ~/.bashrc
```

Or install via `/autocoder:install` in Claude Code.

All aliases call `start-parallel` with the appropriate `--agent` and `--mux` flags. Example — start 3 Claude workers in tmux:

```bash
# Add to ~/.zshrc or ~/.bashrc:
source /path/to/agents/scripts/claude-shell-aliases.sh

# Then:
startclt 3   # 1 manager + 3 Claude workers in tmux
startclc 3   # 1 manager + 3 Claude workers in cmux
startct 3    # 1 manager + 3 Codex workers in tmux
startgt 3    # 1 manager + 3 Gemini workers in tmux
startdt 3    # 1 manager + 3 Droid workers in tmux
```

---

## Installation

### Claude Code

#### Add Marketplace

```bash
/plugin add marketplace https://github.com/laird/agents
```

#### Install Plugins

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
- **autocoder**: `/dev`, `/dev-loop`, `/stop-loop`, `/monitor-workers`, `/list-proposals`, `/approve-proposal`, `/list-needs-design`, `/list-needs-feedback`, `/brainstorm-issue`, `/full-regression-test`, `/improve-test-coverage`, `/review-blocked`, `/install`, `/autocoder-help`

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

- **superpowers**: Automatically invoked by `/dev` for complex issues (>10 test failures, multi-file changes, feature implementations). Provides systematic debugging, brainstorming, planning, and verification skills.

- **quint**: Automatically invoked for ultra-complex issues that exceed autonomous resolution capabilities (>100 test failures, major architecture decisions, irreversible consequences). Guides structured reasoning with human collaboration.

If these plugins are not installed, the workflows use direct problem-solving approaches instead.

### Droid (Factory)

#### Add Marketplace

```bash
droid plugin marketplace add https://github.com/laird/agents
```

#### Install Plugins

```bash
droid plugin install modernize@plugin-marketplace
droid plugin install autocoder@plugin-marketplace
```

#### Standalone Installer

```bash
bash scripts/install-droid.sh /path/to/target-repo
```

After installation, the same slash commands are available in Droid. See [docs/DROID.md](docs/DROID.md) and [docs/DROID-INSTALL.md](docs/DROID-INSTALL.md) for details.

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
| `/dev` | Autonomous issue resolution |
| `/dev-loop` | Continuous autonomous resolution |
| `/stop-loop` | Stop the continuous loop |
| `/list-proposals` | View pending AI-generated proposals |
| `/approve-proposal` | Approve a proposal for implementation |
| `/list-needs-design` | List issues needing design work |
| `/list-needs-feedback` | List issues needing feedback |
| `/brainstorm-issue` | Brainstorm design for an issue |
| `/full-regression-test` | Run comprehensive test suite |
| `/improve-test-coverage` | Analyze and improve test coverage |
| `/review-blocked` | Review and unblock issues labeled by dev-loop |
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

**Commands:** `/dev`, `/dev-loop`, `/stop-loop`, `/monitor-workers`, `/monitor-loop`, `/review-blocked`, `/list-proposals`, `/approve-proposal`, `/list-needs-design`, `/list-needs-feedback`, `/brainstorm-issue`, `/full-regression-test`, `/improve-test-coverage`, `/install`

**Quick Start:**
```bash
/dev              # Fix highest priority issue
/install          # One-time setup for continuous mode
/dev-loop         # Run continuously (single agent)
```

**Swarm (parallel workers):**
```bash
# 1 manager (opus) + 3 workers (sonnet), each in its own tmux pane
startclt 3

# Override models
WORKER_MODEL=claude-sonnet-5 MANAGER_MODEL=claude-opus-5 startclt 3

# Manager-routing mode (zero worker-vs-worker claim races)
start-parallel-agents.sh 3 --mux tmux --agent claude --route manager
```

---
## Repository Structure
---

agents/
├── .agent/                              # Antigravity agent configuration (rules, workflows)
├── .claude-plugin/                      # Claude Code plugin configuration
├── .factory/                            # Droid (Factory) configuration
│   ├── settings.json                   # Hooks (stop hook for continuous operation)
│   ├── skills/
│   │   ├── autocoder/                  # Droid autocoder skill + references
│   │   └── modernize/                  # Droid modernize skill + references
│   └── droids/
│       ├── architect.md                # Specialist subagent: architecture
│       ├── coder.md                    # Specialist subagent: implementation
│       ├── documentation.md            # Specialist subagent: documentation
│       ├── migration-coordinator.md    # Specialist subagent: orchestration
│       ├── security.md                 # Specialist subagent: security
│       └── tester.md                   # Specialist subagent: testing
├── .factory-plugin/                     # Droid plugin marketplace configuration
│   ├── marketplace.json                # Marketplace metadata (2 plugins)
│   └── plugins/
│       ├── modernize/
│       │   └── plugin.json
│       └── autocoder/
│           └── plugin.json
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
│       │   ├── dev-loop.md      # Continuous autonomous resolution
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
│           ├── claude-worker-loop.sh   # Shell loop: fresh Claude process per issue (clean context)
│           ├── start-parallel-agents.sh # Launch manager + N worker panes (tmux/cmux)
│           ├── join-parallel-agents.sh  # Attach to an existing swarm session
│           ├── end-parallel-agents.sh   # Tear down the swarm
│           ├── add-worker.sh            # Add a worker to a running swarm
│           ├── remove-worker.sh         # Remove a worker from a running swarm
│           ├── restart-worker.sh        # Restart an unhealthy worker
│           ├── start-issue-work.sh      # Atomic issue claim + branch setup (used by Codex)
│           ├── worker-launch-lib.sh     # Per-agent launch/loop configuration
│           ├── worker-health.sh         # Worker liveness checks for manager
│           ├── swarm-manifest-lib.sh    # Swarm state tracking
│           ├── issue-fns.sh             # issue_claim / issue_release / issue_update wrappers
│           ├── issue-source-lib.sh      # Issue backend detection (file / github)
│           ├── issues-file.py           # File-backend issue store
│           ├── issues-gh.sh             # GitHub-backend issue store
│           ├── merge-to-integration.sh  # Land worktree work on shared integration branch
│           ├── regression-test.sh       # Full test suite with GitHub integration
│           ├── fetch-blocked-issues.sh  # List blocked/needs-review issues
│           ├── add-blocking-label.sh    # Label an issue as blocked
│           ├── approve-blocked-issue.sh # Approve a blocked issue
│           └── reject-blocked-issue.sh  # Reject a blocked issue
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
- 🧠 **Model-tiered swarms** - Manager on `claude-opus-5` (coordination), workers on `claude-sonnet-5` (implementation); overridable via `WORKER_MODEL`/`MANAGER_MODEL`
- 🆕 **Fresh context per issue** - `claude-worker-loop.sh` restarts Claude for each issue; each worker is a visible tmux pane the user can inspect and interact with
- 🔒 **Robust issue claiming** - Atomic file-backend rename + GitHub race-detection via `[autocoder-claim]` markers; task scope gate checks CONTEXT FIT and WORKTREE INDEPENDENCE before branching
- 📐 **Worktree-safe decomposition** - Over-large issues are split into sub-tasks with "Files Affected" fields so parallel workers never collide
- 🛡️ **Swarm resilience** - Manager monitors worker health, restarts unhealthy workers, and can scale the fleet mid-run with `add-worker.sh`

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
2. Run `/dev` to start autonomous issue resolution
3. Use `/list-needs-design` and `/brainstorm-issue` for complex issues
4. Review proposals with `/list-proposals` and approve with `/approve-proposal`
5. For continuous operation: `/install` then `/dev-loop`

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
| 3.24.0 | 2026-07-24 | **Autocoder v4.5.0**: Robust issue claiming — atomic file-backend rename + GitHub race detection via `[autocoder-claim]` markers (3 s settlement, then marker-count check). Task scope gate before branch creation (CONTEXT FIT + WORKTREE INDEPENDENCE); over-large issues decomposed with "Files Affected" field for swarm-safe parallelism. `claude-worker-loop.sh` shell loop gives each issue a fresh Claude process (clean context window) in a visible tmux pane. Model tiers: manager runs `claude-opus-5`, workers run `claude-sonnet-5`; overridable via `WORKER_MODEL`/`MANAGER_MODEL`. tmux/cmux availability check with per-platform install links. |
| 3.23.0 | 2026-07-23 | **Swarm routing modes**: `--route manager` flag for `start-parallel-agents.sh` — workers idle at a ready prompt, manager dispatches `/autocoder:dev <N>` one at a time, eliminating all worker-vs-worker claim races. `--paused`/`--no-start` flag creates the swarm without launching loops (start them later with `start-workers.sh`). |
| 3.22.0 | 2026-06-20 | **Swarm resilience & hardened git workflow**: Manager agent monitors worker health and restarts unhealthy workers. `add-worker.sh` lets the manager (or user) scale the fleet mid-run without restarting. Hardened `/dev` git workflow: always creates `feature/issue-N` branch, auto-detects default branch, propagated to Codex, Droid, and OpenCode platforms. Shared integration branch (`merge-to-integration.sh`) for landing parallel worktree work. Codex and Antigravity/Gemini parity updates. |
| 3.11.1 | 2026-03-05 | **Autocoder v3.6.3**: SRE monitoring workflow as idle fallback (production log scanning, engagement health checks, worker heartbeats, automated issue filing). Issue decomposition for complex `/dev` issues. `/review-blocked` command for parallel review sessions (supports needs-design, too-complex, proposal, future labels). `/install` command replaces `/install-stop-hook` (now installs all plugin components). `future` blocking label for deferred issues. Stop hook path auto-detection and duplicate prevention. |
| 3.4.0 | 2026-01-24 | **Autocoder v3.0.0**: Renamed `/fix-github` → `/dev`, `/fix-github-loop` → `/dev-loop`. Added design workflow commands (`/list-needs-design`, `/list-needs-feedback`, `/brainstorm-issue`). Added help commands (`/autocoder-help`, `/modernize-help`). Updated README with workflow patterns. |
| 3.3.0 | 2025-12-29 | **Proposal system & triage**: AI-generated enhancements now require human approval via `proposal` label. Added `/list-proposals` command, unprioritized issue triage, platform documentation (CLAUDE-CODE.md, ANTIGRAVITY.md, OPENCODE.md). All platforms updated to consistent v1.5.0 |
| 3.0.0 | 2025-11-24 | **Added autocoder plugin**: Autonomous GitHub issue resolution with `/dev` command. Self-configuring via `CLAUDE.md`, works with any test framework. Includes regression-test.sh script with GitHub integration. Marketplace now contains 2 plugins (modernize + autocoder) |
| 2.6.0 | 2025-11-09 | Applied 5 evidence-based improvements from RawRabbit retrospective: front-load test setup, spike-driven ADRs, shift security left, continuous testing, incremental documentation. Impact: 27 hours saved per project |
| 2.5.0 | 2025-11-01 | Added continuous improvement workflow: `/retro` and `/retro-apply` commands for retrospective analysis and automated application of lessons learned |
| 2.4.2 | 2025-10-28 | Renamed `/modernize:project` to `/modernize`, removed agents/protocols/scripts in favor of streamlined commands |
| 2.4.1 | 2025-10-25 | Removed cost estimates, added time estimate disclaimers |
| 2.4.0 | 2025-10-25 | Added complete modernization workflow (assess → plan → execute) |
| 2.3.0 | 2025-10-25 | Added /modernize-project multi-agent orchestrator |
| 2.2.0 | 2025-10-25 | Restructured as Claude Code plugin |
| 1.0 | 2025-10-10 | Initial release with protocols and agent definitions |

---

## Adding a Custom Issue Backend

The issue system is pluggable. Any executable that implements the backend contract can be used as an issue source.

### Backend Contract

Your backend must accept these subcommands:

| Subcommand | Args | Output |
|-----------|------|--------|
| `list` | `[--label L] [--state open\|closed\|all] [--limit N]` | JSON array — `gh issue list` schema |
| `get` | `<number>` | JSON object — `gh issue view` schema |
| `update` | `<number> [--add-label L] [--remove-label L] [--status S]` | exit code |
| `comment` | `<number> --body "..."` | exit code |
| `close` | `<number> [--comment "..."]` | exit code |
| `create` | `--title "..." --body "..." [--label L]` | `{"number": N}` |

`list` and `get` must output JSON matching `gh issue list --json number,title,body,labels,state` and `gh issue view --json number,title,body,labels,state,comments` respectively.

Note: `--priority` is translated to `--label` by `issue-fns.sh` before reaching backends. Backends only receive `--label`.

### Registering Your Backend

In `.autocoder.json`:

```json
{
  "issueSource": "jira",
  "issueBackend": "./scripts/backends/jira-backend.sh"
}
```

### Minimal Template

```bash
#!/bin/bash
SUBCOMMAND="$1"; shift
case "$SUBCOMMAND" in
  list)    echo "[]" ;;
  get)     echo "{}" ;;
  update)  exit 0 ;;
  comment) exit 0 ;;
  close)   exit 0 ;;
  create)  echo '{"number": 1}' ;;
  *) echo "Unknown: $SUBCOMMAND" >&2; exit 1 ;;
esac
```

### Distributed Lock Pattern

For backends that need distributed locking (multiple parallel agents claiming issues), implement `status: open|working|closed` semantics in your `update` subcommand.

The built-in `issue_claim N` wrapper in `issue-fns.sh` is the canonical way to claim an issue:
- **File backend**: performs an atomic `os.rename(open/N.md, working/N.md)` — only one worker wins
- **GitHub backend**: calls `update N --add-label working`, then posts an `[autocoder-claim]` marker comment, waits 3 seconds for concurrent workers to surface, and checks marker count — backs off if more than one marker found

Agents call `issue_release N` to unclaim (not `update N --remove-label working`); release moves the file back from `working/` to `open/` and removes the label. The `list --state open` call must exclude claimed issues.

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
