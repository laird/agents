# Modernize Plugin (Claude Code)

Complete modernization workflow with multi-agent orchestration. Assess viability, plan the migration, execute with 6 specialist agents, and continuously improve through retrospective analysis.

## Compatibility Notice

**This plugin is primarily developed for personal use.** While it should work on Linux, macOS, and WSL, there are no guarantees. Use at your own risk.

## Installation

```bash
# Add the plugin marketplace (one-time setup)
/plugin add-registry https://github.com/laird/agents

# Install the modernize plugin
/plugin install modernize
```

## Commands

Each command is a comprehensive protocol document containing agent coordination instructions, phase-by-phase workflows, quality gates, and best practices.

| Command | Description | Output |
|---------|-------------|--------|
| `/assess` | Evaluate modernization viability across 8 dimensions | `ASSESSMENT.md` |
| `/plan` | Create detailed execution strategy with phases, timeline, and resources | `PLAN.md` |
| `/modernize` | Execute 7-phase modernization with 6 specialist agents | Modernized codebase |
| `/retro` | Analyze project history for process improvements | `IMPROVEMENTS.md` |
| `/retro-apply` | Apply approved retrospective recommendations | Updated protocols |
| `/modernize-help` | Show workflow overview and help | — |

## End-to-End Walkthrough

Here's the full narrative of a modernization project from start to finish.

### Step 1: Assess Viability

```bash
/assess
```

Before committing to a modernization, evaluate whether it makes sense. The assessment analyzes your project across **8 dimensions**:

1. **Technical Viability** (0-100) — Can we modernize? Framework status, dependency health, API compatibility
2. **Business Value** (0-100) — Should we modernize? ROI, maintenance cost reduction, feature enablement
3. **Risk Profile** (LOW/MEDIUM/HIGH/CRITICAL) — What could go wrong? Breaking changes, data migration, downtime
4. **Resource Requirements** — How much effort? Time, people, infrastructure
5. **Dependencies & Ecosystem Health** — Are dependencies maintained? EOL packages, transitive vulnerabilities
6. **Code Quality & Architecture** — How maintainable is it? Complexity, coupling, patterns
7. **Test Coverage & Stability** — Can we safely change it? Coverage percentage, test reliability
8. **Security Posture** — How secure is it? CVE count, vulnerability severity, compliance gaps

The output is `ASSESSMENT.md` with scores, risk analysis, and a **GO / CONDITIONAL GO / NO-GO** recommendation.

### Step 2: Create an Execution Plan

```bash
/plan
```

If the assessment says GO, create a detailed execution strategy. The plan defines:

- **Primary objectives** (must achieve) and **secondary objectives** (should achieve)
- **Explicit out-of-scope items** — what you're NOT doing
- **Phase breakdown** with timeline estimates and dependencies
- **Risk mitigation strategies** for each identified risk
- **Resource allocation** — which agents handle which phases
- **Quality gates** — what must pass before each phase can proceed

If you run `/plan` without an `ASSESSMENT.md`, it creates a quick inline assessment first.

### Step 3: Execute the Modernization

```bash
/modernize
```

This is the main event. The Migration Coordinator orchestrates 6 specialist agents through **7 phases**, enforcing quality gates at every transition. Each phase has specific agents, deliverables, and blocking criteria.

You can run `/modernize` without prior assessment or planning — it will create them inline. But the recommended workflow (`/assess` → `/plan` → `/modernize`) produces better results because decisions are more informed.

### Step 4: Retrospective (Optional)

```bash
/retro
```

After the modernization completes, analyze the project history to find process improvements. The retro reviews:

- **User interruptions and corrections** — the strongest signal that agents need behavioral improvement
- **Quality gate failures** and how long they took to resolve
- **ADR decisions** — which worked well, which caused rework
- **Testing cycles** — how many fix-and-retest iterations were needed
- **Documentation gaps** discovered late in the process

Outputs `IMPROVEMENTS.md` with 3-5 evidence-based recommendations, each with quantified impact.

### Step 5: Apply Improvements (Optional)

```bash
/retro-apply
```

Systematically applies approved recommendations from `IMPROVEMENTS.md`:

- Updates command files with better agent behavior guidance
- Modifies protocols to prevent recurring issues
- Adds automation (scripts, hooks) to enforce best practices
- Embeds lessons learned into the workflow

This is how the system improves itself — each project makes the next one better.

## The 7 Modernization Phases

| Phase | Name | Active Agents | Duration | Key Deliverables |
|-------|------|---------------|----------|-----------------|
| 0 | **Discovery & Assessment** | Coordinator, Security, Architect | 1-2 days | Baseline metrics, security scan, project inventory |
| 1 | **Security Remediation** | Security, Coder, Tester | 1-3 days | CRITICAL/HIGH CVEs eliminated, security score ≥45 |
| 2 | **Architecture Decisions** | Architect, Coordinator | 1-2 days | ADRs for key decisions (MADR 3.0.0 format) |
| 3 | **Framework Upgrade** | Coder, Tester | 2-5 days | Updated framework, dependencies, build passing |
| 4 | **API Modernization** | Coder, Tester | 2-4 days | Obsolete APIs replaced, patterns updated |
| 5 | **Performance Optimization** | Coder, Tester | 1-2 days | No regressions >10%, benchmarks established |
| 6 | **Documentation** | Documentation, Tester | 1-2 days | CHANGELOG, migration guide, ADR summaries |

**Phase 0 is critical** — test environment setup is the mandatory first task. Nothing else can proceed until the build succeeds, tests run, and a vulnerability scan completes. This establishes verified baseline metrics (not estimates) that all later phases measure against.

## Specialist Agents

The modernize plugin includes 6 specialized agents, each invoked via Claude Code's Task tool. They coordinate through the Migration Coordinator and enforce quality gates at every handoff.

### Migration Coordinator (Orchestrator)

The strategic orchestrator active throughout the entire project.

- Creates migration roadmaps and assigns agents to phases
- Enforces quality gates between phases (blocks progression on failure)
- Coordinates fix-and-retest cycles between Coder and Tester
- Generates progress reports and maintains the audit trail
- Makes GO / CONDITIONAL GO / NO-GO decisions at each gate

**Assessment process (7 stages):** Pre-assessment → Codebase analysis → Test coverage → Security assessment → Compatibility → Architecture opportunities → Risk consolidation → Final report

### Security Agent

Scans for vulnerabilities and blocks progression until critical issues are resolved.

- Scans dependencies for known CVEs and categorizes by severity
- Calculates security scores (0-100) from actual scan results, never estimates
- Prioritizes remediation: CRITICAL (P0, 1-3 days) → HIGH (P1, 1-2 weeks) → MEDIUM → LOW
- Validates fixes don't introduce regressions
- **Blocks** if score <45 or any CRITICAL CVEs remain

**Scoring:** Base 100, deductions per vulnerability (CRITICAL -25, HIGH -10, MEDIUM -5, LOW -1, insecure pattern -3, missing control -5).

**Vulnerability categories:** Dependency CVEs, insecure code patterns (SQL injection, XSS, hardcoded credentials, etc.), configuration issues, missing security controls.

### Architect Agent

Makes technology decisions and documents them as ADRs.

- Researches 3+ alternatives for each architectural decision
- Evaluates trade-offs across performance, scalability, security, maintainability, and integration
- Creates ADRs in **MADR 3.0.0** format with evaluation matrices
- Supports spike-driven decisions — high-risk choices require empirical validation via spike branches before commitment
- Manages the full ADR lifecycle (7 stages: Proposed → Accepted → Implemented → Validated → Superseded)

**ADR naming:** `ADR 0001 Target Framework NET9.md` (uppercase prefix, 4-digit number, spaces in title)

### Coder Agent

Implements migrations and fixes.

- Updates project files, dependencies, and framework targets
- Migrates obsolete APIs to modern alternatives
- Fixes build errors and resolves breaking changes
- Works incrementally — one component at a time, build/test after each change
- Strategies: incremental, bottom-up, top-down, or risk-based depending on the project

**Breaking change mitigation:** Compatibility shims, adapters, conditional compilation, gradual migration, feature flags, abstraction layers.

### Tester Agent

Validates everything with a 6-phase testing protocol and enforces 100% pass rate.

- Executes tiered testing: Unit → Component → Integration → E2E → Performance → Validation
- Runs after **every code change**, not delayed until the end
- Manages fix-and-retest cycles (max 3 iterations) with the Coder agent
- Categorizes failures by priority: P0 (blocking) → P1 (must fix) → P2 (should fix) → P3 (track)
- **Blocks** progression if any P0/P1 failures remain after 3 iterations

**Stage-specific testing:** Each phase has different test tier requirements and time budgets, from 5 minutes (unit tests after security fixes) to 90 minutes (full suite before release).

### Documentation Agent

Generates all project documentation continuously throughout the project.

- Maintains CHANGELOG.md (Keep a Changelog 1.0.0 format)
- Writes migration guides with step-by-step upgrade instructions and rollback procedures
- Creates release notes with executive summaries and breaking change details
- Summarizes ADRs into a navigable index
- Uses incremental documentation — documents as work happens, not at the end

**Status markers:** ⚠️ In Progress → ✅ Fixed (validated) → 📝 Documented. "Fixed" claims only after test validation passes.

## Protocols

The modernize plugin includes 10 protocol documents that guide agent behavior. These are the rules the agents follow.

### Core Protocols

| Protocol | Purpose |
|----------|---------|
| **Testing Protocol** | 6-phase tiered testing (Unit → Component → Integration → E2E → Performance → Validation). Tests after every stage, not delayed. Stage-specific requirements and time budgets. |
| **Security Scanning Protocol** | Verified security metrics from actual scans. Baseline scan in Phase 0. Score calculation formula. Blocks on CRITICAL CVEs. |
| **ADR Lifecycle** | 7-stage lifecycle for architectural decisions (MADR 3.0.0 format). Spike-driven validation for high-risk decisions. 24-48hr stakeholder review. |
| **Agent Logging** | 4-parameter logging structure (WHAT, WHY, IMPACT, OUTCOME). 7 templates for different event types. All agent work logged to HISTORY.md. |

### Documentation Protocols

| Protocol | Purpose |
|----------|---------|
| **Incremental Documentation** | Document as you go, not at the end. Status markers track progress. Prevents aspirational documentation. |
| **Documentation Plan** | Structure and organization for project documentation. |
| **Documentation Protocol** | Standards for technical writing: style, accuracy, formatting, organization. |

### Execution Protocols

| Protocol | Purpose |
|----------|---------|
| **Parallel Migration** | Dependency-level analysis for parallel agent execution. 50-67% time savings. |
| **Stage Validation** | 6 quality gates enforced between phases. Blocking criteria for each gate. |
| **Generic Migration Planning** | 5-phase planning framework with phasing strategies. |

## Quality Gates

These are enforced between every phase transition. Failing a gate **blocks** progression.

| Gate | Criteria | When Checked |
|------|----------|-------------|
| **Security** | Score ≥45/100, zero CRITICAL CVEs | After Phase 1, before migration starts |
| **Build** | 100% compilation success, zero new warnings | After every code change |
| **Tests** | 100% pass rate (all applicable tiers) | After every phase |
| **Issues** | All P0/P1 resolved | Before release |
| **Performance** | No regressions >10% from baseline | After Phase 5 |
| **Documentation** | All changes documented, examples tested | Before release |

## Automation Scripts

Located in the `scripts/` directory (referenced from the main repo):

| Script | Purpose |
|--------|---------|
| `append-to-history.sh` | Log agent activity to HISTORY.md (4-parameter structure) |
| `analyze-dependencies.sh` | Map project dependency graph for parallel execution |
| `capture-test-baseline.sh` | Record baseline test metrics in Phase 0 |
| `run-stage-tests.sh` | Execute stage-specific test tiers |
| `validate-migration-stage.sh` | Check quality gates for phase completion |

## Integration with Autocoder

When the **autocoder** plugin is also installed, modernize can leverage parallel worker agents to resolve test failures faster. This is optional — modernize works exactly the same without autocoder.

### What Changes

| Aspect | Without Autocoder | With Autocoder |
|--------|-------------------|----------------|
| **Test failure handling** | Direct fix-and-retest cycles (Coder + Tester, max 3 iterations) | Creates GitHub issues grouped by root cause, workers fix in parallel |
| **Parallelism** | Sequential within each phase | Multiple workers fix different failure groups simultaneously |
| **Coordination** | Internal agent handoffs | GitHub issues + labels as source of truth |
| **Human oversight** | Watch agent output | Use `/review-blocked` and `/monitor-workers` in manager session |

### Recommended Workflow (with autocoder)

```bash
# 1. Install both plugins
/plugin install modernize autocoder

# 2. One-time setup (installs scripts, aliases)
/install

# 3. Start a swarm from your terminal
cd ~/src/myproject
startt 3          # 3 workers + 1 manager (or: startc 3 for cmux)

# 4. In the manager session, run the modernization
/assess           # Evaluate viability
/plan             # Create execution strategy
/modernize        # Execute — files issues for failures, workers fix in parallel

# 5. While modernize runs, use manager commands as needed
/review-blocked   # Approve architectural decisions workers can't handle
/monitor-workers  # Check worker progress, dispatch idle workers

# 6. When done, tear down
endt              # or: endc for cmux
```

### How It Works

1. Modernize detects autocoder at startup and reports the swarm environment (tmux/cmux/plain terminal)
2. During each phase, when the quality gate fails due to test failures, modernize:
   - Analyzes failures and groups them by likely root cause (same module, same API change, same error pattern)
   - Creates one GitHub issue per group with P0/P1 priority and a `modernize` label
   - Enters a wait loop, polling GitHub every 3 minutes for issue closure
3. In the wait loop, modernize uses the best available coordination:
   - **tmux/cmux**: Reads worker screens, dispatches idle workers to unclaimed issues, detects stuck agents
   - **Plain terminal**: Polls GitHub issue status, prompts user if an issue is unclaimed for >30 minutes
4. When all issues are closed, modernize re-runs the quality gate and proceeds to the next phase

### Without Autocoder

Everything works exactly as before — direct fix-and-retest cycles between Coder and Tester agents, no GitHub issues, no swarm coordination. You don't need a GitHub repo or issues to use modernize standalone.

## Production Results

- **32/32 projects** migrated successfully (100% success rate)
- **100% test pass rate** achieved across all projects
- **Security improvement**: 0/100 → 45/100+ (all CRITICAL CVEs eliminated)
- **Zero P0/P1** blocking issues in production
- **1,500+ lines** of documentation auto-generated per project
- **27 hours saved** per project from continuous testing and incremental documentation improvements

## Use Cases

While originally created for .NET Framework migrations, the modernize plugin is universally applicable:

- **Framework upgrades** — .NET, Node.js, Python, Java, Ruby, etc.
- **Cloud migrations** — AWS, Azure, GCP platform changes
- **Language migrations** — Java to Kotlin, JavaScript to TypeScript
- **Database migrations** — SQL to NoSQL, version upgrades
- **Legacy modernization** — Monolith to microservices, API updates
- **Security remediation** — CVE scanning and systematic vulnerability fixes
- **Dependency upgrades** — Major version bumps with breaking changes
