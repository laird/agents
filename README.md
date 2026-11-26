# Agent Protocols

A multi-platform set of protocols, specialized agents, skills, and scripts for AI-assisted software work. It ships two complementary plugins:

1. **Modernize** — assess → plan → execute → improve, with six specialized agents
2. **Autocoder** — autonomous issue resolution against GitHub, Jira, Azure DevOps, or a file-backed tracker, with testing and quality automation

The same ideas started as .NET framework-migration tooling and are now aimed at any language. The repo is primarily maintained for personal use. It is tested on Linux, macOS, and WSL. Native Windows is not supported.

## Start here

Pick your platform and follow that install section.

| I'm using… | Go to |
|---|---|
| **Claude Code** (primary, most complete) | [Claude Code](#claude-code) |
| **OpenAI Codex CLI** | [Codex](#codex) |
| **Droid (Factory)** | [Droid (Factory)](#droid-factory) |
| **Gemini CLI** or **Antigravity** | [Antigravity and Gemini CLI](#antigravity-and-gemini-cli) |
| **Grok** | [Grok](docs/GROK.md) |
| **Pi** | [Directory guide](#directory-guide) and `scripts/pi-*.sh`; see [pi.dev](https://pi.dev) |
| **OpenCode** | [docs/OPENCODE.md](docs/OPENCODE.md) |

Swarm runbooks: [Claude](docs/swarm-quickstart-claude.md), [Gemini](docs/swarm-quickstart-gemini.md), [Codex](docs/swarm-quickstart-codex.md), [Droid](docs/swarm-quickstart-droid.md). Remote swarms: [docs/remote-swarm.md](docs/remote-swarm.md).

## Directory guide

| Platform | Directory | Documentation |
|---|---|---|
| Claude Code | `.claude-plugin/` and `plugins/` | [docs/CLAUDE-CODE.md](docs/CLAUDE-CODE.md) |
| Antigravity | `.agent/` | [docs/ANTIGRAVITY.md](docs/ANTIGRAVITY.md) |
| Gemini CLI skill extensions | `skills/` (each skill has `gemini-extension.json` and `GEMINI.md`) | [skills/autocoder/README.md](skills/autocoder/README.md), [skills/modernize/README.md](skills/modernize/README.md) |
| Codex | `.agents/plugins/`, `codex-plugins/`, `skills/`, `scripts/` | [docs/CODEX.md](docs/CODEX.md) |
| Droid (Factory) | `.factory/` and `.factory-plugin/` | [docs/DROID.md](docs/DROID.md) |
| **Grok** | the Claude marketplace, plus `plugins/*/.grok-plugin/plugin.json` | [docs/GROK.md](docs/GROK.md) |
| Pi | `.pi/` (`prompts/`, `skills/`) and `scripts/pi-*.sh` | [pi.dev](https://pi.dev) |
| OpenCode | `agents/` | [docs/OPENCODE.md](docs/OPENCODE.md) |
| Improve skill (all platforms) | `skills/improve/` | [skills/improve/SKILL.md](skills/improve/SKILL.md) |

## Installation

### Claude Code

The current Claude Code command is `/plugin marketplace add`, not `/plugin add marketplace`. Official docs: [Install plugins](https://code.claude.com/docs/en/plugins/install).

In a Claude Code session:

```text
/plugin marketplace add laird/agents
/plugin install modernize@plugin-marketplace
/plugin install autocoder@plugin-marketplace
```

`plugin-marketplace` is the `name` in `.claude-plugin/marketplace.json`. From a shell (Claude Code 2.1+):

```bash
claude plugin marketplace add laird/agents
claude plugin install modernize@plugin-marketplace
claude plugin install autocoder@plugin-marketplace
```

After install, slash commands include:

- **modernize:** `/assess`, `/plan`, `/modernize`, `/retro`, `/retro-apply`, `/modernize-help`
- **autocoder:** `/fix`, `/fix-loop`, `/stop-loop`, `/monitor-workers`, `/list-proposals`, `/approve-proposal`, `/list-needs-design`, `/list-needs-feedback`, `/brainstorm-issue`, `/full-regression-test`, `/improve-test-coverage`, `/review-blocked`, `/install`, `/autocoder-help`

Optional companions (not required):

```text
/plugin install superpowers
/plugin install quint
/plugin marketplace add michael-denyer/pstack-claude
/plugin install pstack@pstack-claude
```

When those are present, `/fix` can invoke them. When they are not, the workflow still runs. pstack install for other CLIs is in [docs/PSTACK.md](docs/PSTACK.md).

### Codex

```bash
bash scripts/install-codex.sh /path/to/target-repo

# One autocoder pass, then a continuous loop and a manager monitor
bash scripts/codex-autocoder.sh fix
bash scripts/codex-fix-loop.sh
bash scripts/codex-monitor-loop.sh 15

# Swarm (tmux by default; pass cmux to override)
bash scripts/start-parallel-codex.sh 3
```

There is no `scripts/codex-stop-loop.sh`. While a loop is running, stop it by creating the stop file it watches (each loop deletes that file on startup). Paths are relative to the git toplevel:

```bash
touch .codex/loops/fix-loop.stop       # ends scripts/codex-fix-loop.sh
touch .codex/loops/monitor-loop.stop   # ends scripts/codex-monitor-loop.sh
```

The fix loop checks during its sleep. The monitor loop checks at the start of the next interval, so a stop file created during `sleep` waits out the current interval. Ctrl-C stops a loop in the foreground.

Codex-oriented skills live in `skills/autocoder/` and `skills/modernize/`. Shell aliases: source [scripts/codex-shell-aliases.sh](scripts/codex-shell-aliases.sh) for `startct`, `startcc`, `joinct`, and `joincc`.

A `/plugin add marketplace …` command does not apply to the Codex CLI; that was Claude Code syntax (and the old form of it).

### Droid (Factory)

```bash
droid plugin marketplace add https://github.com/laird/agents
droid plugin install modernize@plugin-marketplace
droid plugin install autocoder@plugin-marketplace

# Or copy assets into a target repo
bash scripts/install-droid.sh /path/to/target-repo

bash scripts/droid-autocoder.sh fix
bash scripts/droid-fix-loop.sh
bash scripts/droid-monitor-loop.sh 15
bash scripts/droid-start-parallel.sh tmux 3
```

There is no `scripts/droid-stop-loop.sh`. `scripts/droid-fix-loop.sh` and `scripts/droid-monitor-loop.sh` repeat until the process exits, so stop them with Ctrl-C or by killing the process. Install and command reference: [docs/DROID.md](docs/DROID.md) and [docs/DROID-INSTALL.md](docs/DROID-INSTALL.md). Aliases: [scripts/droid-shell-aliases.sh](scripts/droid-shell-aliases.sh).

### Antigravity and Gemini CLI

The default git branch is `master`, not `main`. This one-liner failed with 404 when it pointed at `…/main/scripts/install.sh`:

```bash
# from your project's root; needs git
curl -sSL https://raw.githubusercontent.com/laird/agents/master/scripts/install.sh | bash
```

The script sparse-clones the repository and copies `.agent/` into the current directory. With no TTY, the idle-sentinel prompt is skipped. The overwrite prompt is not skipped: if `.agent/` already exists, `read` fails and the script exits. A safer equivalent, from a directory where a checkout named `agents` should land (`git clone` uses the repository name):

```bash
git clone https://github.com/laird/agents.git
cp -r agents/.agent /your/project/
# or: ln -s /path/to/agents/.agent /your/project/.agent
```

Gemini CLI skill packaging (not Codex-specific) is the `gemini-extension.json` and `GEMINI.md` files under `skills/autocoder/` and `skills/modernize/`.

### Shell aliases for swarms

```bash
bash /path/to/agents/scripts/install-shell-aliases.sh        # auto-detect installed CLIs
bash /path/to/agents/scripts/install-shell-aliases.sh --all
source ~/.zshrc   # or ~/.bashrc
```

| Agent | tmux | cmux | Alias file |
|---|---|---|---|
| Claude Code | `startclt` | `startclc` | [claude-shell-aliases.sh](scripts/claude-shell-aliases.sh) |
| Codex | `startct` | `startcc` | [codex-shell-aliases.sh](scripts/codex-shell-aliases.sh) |
| Gemini (Antigravity) | `startgt` | `startgc` | [gemini-shell-aliases.sh](scripts/gemini-shell-aliases.sh) |
| Droid (Factory) | `startdt` | `startdc` | [droid-shell-aliases.sh](scripts/droid-shell-aliases.sh) |

Example: `startclt 3` starts one manager and three Claude workers in tmux.

Those `start*` aliases run `start-parallel`, which is `plugins/autocoder/scripts/start-parallel-agents.sh`. `/install`, `scripts/install-codex.sh`, and `scripts/install-droid.sh` symlink it to `~/.local/bin/start-parallel`. `scripts/install-shell-aliases.sh` only appends `source` lines.

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

# Manager-routing mode (zero worker-vs-worker claim races).
# `start-parallel` is the same command after /install links it onto PATH.
bash plugins/autocoder/scripts/start-parallel-agents.sh 3 --mux tmux --agent claude --route manager
```

**Environments (gated releases):** the swarm lands on `main` fast and `main-sentinel.sh` repairs it when it goes red. Releases do not share that risk. Declare `environments` in `.autocoder.json` (`staging` → `uat` → `prod`, each a branch on origin that your deploy reads) and `promote.sh` moves each one only to a commit with proof of a full-regression pass: the sentinel's `main-green` tip, the previous environment's tip, or a tree the gate cache recorded as passing. Being on `main` is never enough. See [docs/environments.md](docs/environments.md).

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
| `create` | `--title "..." --body "..." [--label L] [--priority P0-P3]` (unknown flags exit 2) | `{"number": N}` |
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

### Steering Workers Off Each Other's Files

An issue can declare the areas it expects to edit on one line of its body:

```
Touches: src/web/village/, src/web/server.rs, tools/**/screensaver/*
```

Entries are exact paths, directories (trailing `/`) or globs. With no
`Touches:` line, the backticked paths under a `## Files Affected` heading
count. Set `claims.avoid_overlap` in `.autocoder.json` and the fix-loop gate
checks each candidate against the issues other workers hold (`working`):

```json
{ "claims": { "avoid_overlap": "prefer" } }
```

`prefer` tries overlapping candidates only after every other one, even a
lower-priority one; `strict` skips them; `off` (the default) changes nothing.
An issue with no declared areas (or `Touches: none`) never counts as
overlapping, and a catch-all such as `**` is ignored. Bodies are read as
markdown, so on Azure DevOps, whose descriptions are HTML, nothing is declared
yet. `strict` treats every `working` issue as in flight, so an abandoned claim
on the file backend keeps blocking until it is released.

Files that conflicted recently are **hot**: the `files` of merge attempts with
`outcome: conflict` in `merge-events.jsonl` among the last
`claims.hot_window` attempts for this repo (default `50`; write `"7d"` for a
number of days). Under `prefer` and `strict` alike, at most one in-flight claim
may touch a hot file: a candidate touching a hot file that a `working` issue
also touches is skipped. With no merge-events file there are no hot files. List
them with `plugins/autocoder/scripts/touches-fns.sh hot`.

```json
{ "claims": { "avoid_overlap": "prefer", "hot_window": "7d" } }
```

### Resolving Merge Conflicts in the Merge Job

When the merge job's rebase onto the integration branch stops on a conflict,
it normally aborts and bounces the issue back to its worker. Two settings in
`.autocoder.json` let the job try first, inside its own throwaway worktree:

```json
{
  "unionMerge": ["CHANGELOG.md", "tests/*.list"],
  "conflictResolver": "claude",
  "conflictResolverTimeout": 600
}
```

`unionMerge` lists append-only files (module lists, test lists, changelog
paragraphs). A conflict in one of them is rebuilt with
`git merge-file --union`, which keeps both sides' lines. Globs are bash
patterns on the repo-relative path, and `*` also matches `/`.

`conflictResolver` gets one try per job, bounded by `conflictResolverTimeout`
seconds. `claude` runs `merge-conflict-claude.sh`, a headless session that can
read the worktree but may only edit the conflicted files. Any other value is
a shell command run in the worktree, with `AUTOCODER_CONFLICT_FILES` and
`AUTOCODER_CONFLICT_CONTEXT` (both sides' commit messages) in its
environment. It must exit 0 only when it resolved every file. The job refuses
the result if it leaves conflict markers or unmerged paths, or if it moved
`HEAD`. The default is `off`.

A resolved tree is gated like any other before it is pushed. A re-sync after
a lost push race that needed resolving is always re-gated. The close comment
names the resolved files and says the resolution was not part of the reviewed
commit. When the attempt is refused, or the resolved tree fails the gate, the
issue is bounced or escalated as before, and the comment includes the
attempted diff. `AUTOCODER_UNION_MERGE`, `AUTOCODER_CONFLICT_RESOLVER` and
`AUTOCODER_CONFLICT_RESOLVER_TIMEOUT` override these settings for one run
(`AUTOCODER_CONFLICT_RESOLVER=off` disables the resolver).

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
