# Agent Protocols

A multi-platform repository of production-validated protocols, specialized agents, skills, and automation frameworks for systematic AI-assisted software development.

## Overview

This marketplace contains **2 plugins** with complementary capabilities:

1. **Modernize** - Complete modernization workflow (assess → plan → execute → improve) with 6 specialized agents
2. **Autocoder** - Autonomous issue resolution — GitHub, Jira, Azure DevOps, or file-backed trackers — with intelligent testing and quality automation

Both plugins feature **continuous improvement** through retrospective analysis and are **universally applicable** to any software project. The repo also ships platform-neutral skills, including **improve** (`skills/improve/`) — a validation & refinement loop for stabilizing platforms through repeated live end-to-end runs. Originally created for .NET framework migrations, these tools work with any language or platform.

## Start Here

Pick your platform:

| I'm using… | Go to |
|------------|-------|
| **Claude Code** | [Claude Code install](#claude-code) |
| **Gemini CLI / Antigravity** | [Antigravity Support](#antigravity-support) |
| **OpenAI Codex CLI** | [Codex Support](#codex-support) |
| **Droid (Factory)** | [Droid (Factory) Support](#droid-factory-support) |

Not sure? **Claude Code** is the primary platform — it has the most complete feature set and documentation.

---

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
| **Codex** | `.agents/plugins/`, `codex-plugins/`, `skills/`, and `scripts/` | [docs/CODEX.md](docs/CODEX.md) |
| **OpenCode** | `agents/` | [docs/OPENCODE.md](docs/OPENCODE.md) |
| **Droid (Factory)** | `.factory/` and `.factory-plugin/` | [docs/DROID.md](docs/DROID.md) |
| **Improve skill** (all platforms) | `skills/improve/` | [skills/improve/SKILL.md](skills/improve/SKILL.md) |

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

## Swarm Quickstart Guides

Platform-specific install and run guides for each supported agent:

| Platform | Quickstart |
|----------|-----------|
| Claude Code | [docs/swarm-quickstart-claude.md](docs/swarm-quickstart-claude.md) |
| Gemini CLI (Antigravity) | [docs/swarm-quickstart-gemini.md](docs/swarm-quickstart-gemini.md) |
| OpenAI Codex CLI | [docs/swarm-quickstart-codex.md](docs/swarm-quickstart-codex.md) |
| Droid (Factory) | [docs/swarm-quickstart-droid.md](docs/swarm-quickstart-droid.md) |

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
- **autocoder**: `/fix`, `/fix-loop`, `/stop-loop`, `/monitor-workers`, `/list-proposals`, `/approve-proposal`, `/list-needs-design`, `/list-needs-feedback`, `/brainstorm-issue`, `/full-regression-test`, `/improve-test-coverage`, `/review-blocked`, `/install`, `/autocoder-help`

**Get help anytime:**
```bash
/modernize-help    # Overview of modernization workflow
/autocoder-help    # Overview of autonomous coding workflow
```

### Optional Companion Plugins

Autocoder and modernize work fine without these. Install them when you hit the scenarios below.

| Plugin | Install when… |
|--------|--------------|
| **superpowers** | You encounter complex multi-file issues and want systematic debugging, planning, and verification skills |
| **quint** | You need structured human-in-the-loop decisions for ultra-complex or irreversible changes |

```bash
/plugin install superpowers   # optional: structured problem-solving
/plugin install quint         # optional: human-guided decisions
```

When installed, `/fix` invokes them automatically for the right issue types. When absent, the workflow uses direct problem-solving instead — no configuration needed either way.

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

Autonomous issue resolution (GitHub, Jira, Azure DevOps, or file-backed trackers) with intelligent testing, quality automation, multi-agent swarm support, and human-in-the-loop proposal system. See the [Autocoder README](plugins/autocoder/README.md) for full documentation.

**Get help:** `/autocoder-help`

**Commands:** `/fix`, `/fix-loop`, `/stop-loop`, `/monitor-workers`, `/monitor-loop`, `/review-blocked`, `/list-proposals`, `/approve-proposal`, `/list-needs-design`, `/list-needs-feedback`, `/brainstorm-issue`, `/full-regression-test`, `/improve-test-coverage`, `/install`, `/manager-handoff`, `/manager-resume`

**Quick Start:**
```bash
/fix              # Fix highest priority issue
/install          # One-time setup for continuous mode
/fix-loop         # Run continuously (single agent)
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

**SRE Monitor (idle fallback):**

When a worker has no issues in the queue, it can fall back to monitoring production systems — scanning logs for errors, checking service health, and filing or updating GitHub issues for any problems found. This keeps workers productive during queue droughts and surfaces production incidents automatically.

Copy `agents/autocoder/workflows/sre-monitor.md` into your project and adapt the log-collection commands for your environment. The log-collection step is necessarily project-specific: it depends on your logging provider, service names, and the error patterns that matter to you. Everything else (severity triage, issue filing, sleep/wake cycle) stays the same.

**Extending the log-collection step — examples by provider:**

*GCP Cloud Run / Cloud Logging:*
```bash
export SRE_PROJECT_ID="my-gcp-project"
export SRE_SERVICE_NAME="my-api"

gcloud logging read \
  "resource.type=cloud_run_revision AND resource.labels.service_name=$SRE_SERVICE_NAME" \
  --project="$SRE_PROJECT_ID" --limit=100 --freshness=30m 2>&1 \
  | grep -iE "(error|fatal|timeout|Max restart|lock expired)" | head -40
```

*AWS CloudWatch Logs:*
```bash
aws logs filter-log-events \
  --log-group-name "/aws/ecs/my-service" \
  --start-time $(date -d '30 minutes ago' +%s000) \
  --filter-pattern "?ERROR ?FATAL ?timeout" \
  --query 'events[*].message' --output text | head -40
```

*Datadog:*
```bash
datadog-cli logs search \
  "service:my-service status:(error OR warn) @env:production" \
  --from "30 minutes ago" --limit 100 \
  | jq -r '.[].message' | head -40
```

*Kubernetes (kubectl):*
```bash
kubectl logs -n production \
  -l app=my-service \
  --since=30m --prefix \
  | grep -iE "(error|fatal|panic|OOMKilled)" | tail -40
```

*Local / file-based logs:*
```bash
grep -iE "(error|fatal|panic)" /var/log/my-service/app.log \
  | awk -v cutoff="$(date -d '30 minutes ago' '+%Y-%m-%d %H:%M')" '$0 >= cutoff' \
  | tail -40
```

Extend the `grep -iE` pattern with the error signatures that matter for your service — worker crashes, lock timeouts, queue stalls, auth failures, etc. Add a severity table mapping those patterns to P0–P3 so the agent knows when to file immediately vs. comment on an existing issue.

For each finding the monitor either files a new GitHub issue with a priority label, or comments on an existing open issue with the latest timestamp, frequency, and context.

---

### Skill: Improve

A validation and refinement loop for **stabilizing** a platform — not security hardening. Run the real end-to-end cycle, grade it against an explicit contract, root-cause fix, log findings, repeat until N consecutive clean runs.

**When to use:** After an initial modernize or migration, when you want to drive defect count to zero through repeated live runs rather than code review alone. Also useful for any system with a runnable end-to-end exercise.

**How to invoke:**
- Claude Code: load the `improve` skill via the Skill tool (or use `skills/improve/SKILL.md` directly)
- Codex / Gemini: load the `improve` skill from `skills/improve/`

**Model tiers:** Coordinator on `$MANAGER_MODEL` (`opus` / `pro`) for grading and root-cause analysis; subagent workers on `$WORKER_MODEL` (`sonnet` / `flash`) for bounded fixes. Credentials are inherited from the running session.

See [`skills/improve/SKILL.md`](skills/improve/SKILL.md) for the full loop protocol including swarm-mode cadence and cost discipline.

---

## Repository Structure

Two plugins (`modernize`, `autocoder`) each with their own `commands/`, `agents/`, and `scripts/` — fully independent and separately installable. Both share the same 6 specialist agents (architect, coder, documentation, migration-coordinator, security, tester). Per-platform directories (`.agent/`, `.factory/`, `codex-plugins/`, `.agents/`) mirror the Claude Code `plugins/` content for their respective agent CLIs; `skills/improve/` is platform-neutral and ships once.

See [docs/STRUCTURE.md](docs/STRUCTURE.md) for the full annotated directory tree.

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
| 3.42.0 | 2026-08-31 | **Autocoder v4.21.0**: the manager no longer dies on the bypass-permissions dialog, and the status line names the repo. The manager is the only claude path that launches a REPL and then types its prompt into it, and that typed prompt went in after a fixed `sleep 5` with no readiness check — so under `--dangerously-skip-permissions`, whose consent dialog defaults to "No, exit", the trailing Enter answered the dialog instead of submitting the prompt, and the review window was left at a bare shell that reads as an unrelated login session rather than a failed manager. `MANAGER_COMMAND_MODE` (argv|agent-input|shell) puts claude on argv, appending the prompt to `MANAGER_LAUNCH_CMD` via `printf %q` and dropping the post-launch send-keys entirely, so no stray Enter exists to answer the dialog. Separately, `statusline.sh` gained a `repo` segment: a worker sits in `<repo>-wt-N`, so with several swarms running the worktree name alone is easy to misread across projects. It derives from the common git dir rather than `--show-toplevel`, which in a linked worktree is the worktree itself and would only repeat the `wt` segment. |
| 3.41.0 | 2026-08-26 | **Autocoder v4.20.0**: per-issue cost and time attribution. Workers already wrote a full stream-json transcript per session, but its `result` event — tokens, turns, wall-clock, `total_cost_usd` — was only ever read by a human doing a post-mortem, and `AUTOCODER_LOG_DIR` defaults to `/tmp`, so a reboot deleted the only record of what an issue cost. `issue-metrics.py` aggregates those transcripts per issue and renders a markdown comment; `post-issue-metrics.sh` posts it through the `issue-fns.sh` backend (so it works on GitHub/Jira/ADO/file alike), deduping on an HTML marker so re-runs update rather than pile up. `claude-worker-loop.sh` calls it after each fix session, fail-soft. Gate transcripts are deliberately excluded — gate work has no single owner and would inflate whichever issue happened to follow it — and an in-flight session (no `result` event yet) is reported separately rather than published as "$0.00, 0 turns". |
| 3.38.0 | 2026-08-16 | **Autocoder v4.17.0**: fixed manager idle detection — `monitor-workers` listed "bare prompt `❯` with no active tool calls" as an idle indicator, but the agent TUI renders an empty input box mid-turn too, so the rule was always true and managers dispatched over live work. New `worker-idle.sh` decides by double-sampling the pane (any change = busy) and excludes the manager's own pane, which was previously classified as a fourth worker. Same bug removed from `modernize`'s executable auto-dispatch (it grepped for `❯|╰|$`). **Version sync**: autocoder had drifted to 4.16.1 on Claude vs 4.15.0 on Droid/Codex, and the six `gemini-extension.json` files had never been bumped since their port — Gemini advertised autocoder 3.8.0 / modernize 3.2.0. All manifests now agree, and `test_manifest_versions.sh` covers `gemini-extension.json` so it cannot silently rot again. |
| 3.32.1 | 2026-08-07 | **Autocoder v4.10.1**: Jira backend migrated to `/rest/api/3/search/jql` (Atlassian removed the v2 search API — HTTP 410); nextPageToken pagination, explicit fields, ADF descriptions flattened to plain text. Validated LIVE against a real Jira Cloud site (full lifecycle + search); test fakes now 410 the removed endpoint so the migration can't regress. |
| 3.32.0 | 2026-08-07 | **Autocoder v4.10.0**: ship gate (`verify-shipped.sh` — issues close only when their work reaches the ship branch), claim lock held to a terminal outcome (#14), branch-claimed issues excluded from the candidate list (#48). Platform-packaging drift repaired across Claude/Codex/Gemini/Droid (drift checker now covers `retro`; Codex/Droid skill trees unified). New repo skill: **harden** — run/grade/fix/log validation loop for platform stabilization. Planning-pipeline spec/plan docs landed. |
| 3.31.0 | 2026-08-02 | **Swarm quickstart guides** — per-platform install+run docs for Claude, Gemini/Antigravity, Codex, and Droid (`docs/swarm-quickstart-*.md`). Removed all project-specific and EY-specific content: triage corpus rewritten with generic SaaS domain, install docs use generic paths, HISTORY.md anonymized, scripts parameterized. |
| 3.30.0 | 2026-08-02 | **Autocoder v4.9.0**: Manager context-reset commands — `/autocoder:manager-handoff` snapshots live GitHub state, worker topology, and session notes to `MANAGER-STATE.md` then guides a clean context reset; `/autocoder:manager-resume` reads the saved state, diffs against live GitHub, and emits a ready-to-act summary in the fresh session. |
| 3.29.0 | 2026-07-31 | **Autocoder v4.8.0**: Jira and Azure DevOps issue backends (parallel with file/GitHub). Fresh-context fix extended to Gemini/Antigravity workers — `gemini-fix-loop.sh` now runs as a shell subprocess per issue, matching the Claude worker pattern. cmux liveness probe in multiplexer auto-detection (prefers tmux if cmux is installed but not running). API push fallback; issues with an open PR suppressed from the claimable queue. CI shell test suite; multiple bug fixes: label reconciliation, `.autocoder.json` winning over stale env exports, portable test-stat parsing, start-issue-work.sh exit-128 fix. |
| 3.24.0 | 2026-07-24 | **Autocoder v4.5.0**: Robust issue claiming — atomic file-backend rename + GitHub race detection via `[autocoder-claim]` markers (3 s settlement, then marker-count check). Task scope gate before branch creation (CONTEXT FIT + WORKTREE INDEPENDENCE); over-large issues decomposed with "Files Affected" field for swarm-safe parallelism. `claude-worker-loop.sh` shell loop gives each issue a fresh Claude process (clean context window) in a visible tmux pane. Model tiers: manager runs `claude-opus-5`, workers run `claude-sonnet-5`; overridable via `WORKER_MODEL`/`MANAGER_MODEL`. tmux/cmux availability check with per-platform install links. |
| 3.23.0 | 2026-07-23 | **Swarm routing modes**: `--route manager` flag for `start-parallel-agents.sh` — workers idle at a ready prompt, manager dispatches `/autocoder:fix <N>` one at a time, eliminating all worker-vs-worker claim races. `--paused`/`--no-start` flag creates the swarm without launching loops (start them later with `start-workers.sh`). |
| 3.22.0 | 2026-06-20 | **Swarm resilience & hardened git workflow**: Manager agent monitors worker health and restarts unhealthy workers. `add-worker.sh` lets the manager (or user) scale the fleet mid-run without restarting. Hardened `/fix` git workflow: always creates `feature/issue-N` branch, auto-detects default branch, propagated to Codex, Droid, and OpenCode platforms. Shared integration branch (`merge-to-integration.sh`) for landing parallel worktree work. Codex and Antigravity/Gemini parity updates. |
| 3.11.1 | 2026-03-05 | **Autocoder v3.6.3**: SRE monitoring workflow as idle fallback (production log scanning, service health checks, worker heartbeats, automated issue filing). Issue decomposition for complex `/fix` issues. `/review-blocked` command for parallel review sessions (supports needs-design, too-complex, proposal, future labels). `/install` command replaces `/install-stop-hook` (now installs all plugin components). `future` blocking label for deferred issues. Stop hook path auto-detection and duplicate prevention. |
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

## Issue Backends

The issue system is pluggable. Four backends ship built-in — **file**, **GitHub**, **Jira**, and **Azure DevOps** — and any executable implementing the same contract can be added as a custom backend. Select one with `/set-issue-source`.

See **[`docs/issue-backends.md`](docs/issue-backends.md)** for the full overview, and [`docs/jira-setup.md`](docs/jira-setup.md) / [`docs/ado-setup.md`](docs/ado-setup.md) for the Jira and Azure DevOps setup guides.

### Backend Contract

Every backend accepts the same 9 verbs:

| Subcommand | Args | Output |
|-----------|------|--------|
| `list` | `[--label L] [--state open\|working\|blocked\|closed\|all] [--limit N]` | JSON array — `gh issue list` schema |
| `get` | `<number>` | JSON object — `gh issue view` schema |
| `update` | `<number> [--add-label L] [--remove-label L] [--status S] [--assignee A]` | exit code |
| `comment` | `<number> --body "..."` | exit code |
| `close` | `<number> [--comment "..."]` | exit code |
| `create` | `--title "..." --body "..." [--label L]` | `{"number": N}` |
| `claim` | `<number>` | exit code |
| `release` | `<number>` | exit code |
| `any-claimable` | — | exit `0` if claimable work exists, `1` if none |

`list` and `get` must output JSON matching `gh issue list --json number,title,body,labels,state` and `gh issue view --json number,title,body,labels,state,comments` respectively. Exit codes: `0` success/work exists, `1` clean negative, `2` usage error, `3` backend error.

Note: `--priority` is translated to `--label` by `issue-fns.sh` before reaching backends. Backends only receive `--label`.

### Restricting the Swarm to Approved Issues

Set `requiredLabel` in `.autocoder.json` and workers may only claim issues
carrying that label:

```json
{
  "issueSource": "github",
  "requiredLabel": "swarm"
}
```

Approval becomes a positive act — tag an issue `swarm` and the swarm may take
it — instead of the absence of a blocking label. The gate applies to the
claimable queue *and* to `claim` itself, so it holds for issues dispatched by
number as well (`/fix N`, a manager dispatch, a resumed loop). `working` and
`blocked` listings stay ungated so in-flight work remains visible.
`AUTOCODER_REQUIRED_LABEL` overrides it for one command; empty disables it.
Unset, nothing changes. See [docs/issue-backends.md](docs/issue-backends.md).

### Registering a Custom Backend

The built-in sources (`file`, `github`, `jira`, `ado`) need only `issueSource`. A custom backend additionally points `issueBackend` at an executable:

```json
{
  "issueSource": "linear",
  "issueBackend": "./scripts/backends/linear-backend.sh"
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
