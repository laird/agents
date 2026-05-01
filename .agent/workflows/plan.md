---
description: Create a detailed modernization plan
---

# Project Modernization Planning Protocol

**Version**: 1.0
**Purpose**: Create a comprehensive, actionable modernization plan
**Input**: Optional `docs/modernization-assessment.md` from `/assess`
**Output**: `docs/modernization-plan.md` with detailed execution strategy
**Duration**: 3-6 hours

---

## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v1 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

In Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; the mapping is otherwise identical.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills.

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine. A leading `→` on a row indicates "next in sequence if applicable."

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list, emit one consolidated recommendation line at command entry: *Tip: this command works best with the `superpowers` plugin (https://github.com/obra/superpowers) — install via `/plugin install superpowers@claude-plugins-official`.* Never emit such notices for personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria. "Always applied" in a mapping table means the skill is invoked when installed; outcomes remain advisory. When a command claims success while an advisory skill earlier in the run surfaced a failure, the success summary acknowledges the advisory finding.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v1 -->

<!-- BEGIN optional-skills-mapping plan v1 — keep in sync between Claude/Antigravity mirrors of this command -->

| Step | Skill mapping |
|---|---|
| Turn spec into implementation plan → review the produced plan → apply review findings | `superpowers:writing-plans` → `critical-implementation-review` → `update-implementation-plan` |

<!-- END optional-skills-mapping plan v1 -->

## Overview

This protocol creates a **detailed modernization execution plan** that serves as the blueprint for the `/modernize` workflow. The plan includes:

- ✅ Detailed phase breakdown with tasks
- ✅ Timeline and milestone schedule
- ✅ Resource allocation and team assignments
- ✅ Risk mitigation strategies
- ✅ Quality gates and success criteria
- ✅ Contingency plans

**Core Principle**: **Proper planning prevents poor performance - plan before you execute.**

---

## Planning Process

### Step 1: Load Assessment (if available)

**Active Agent**: Migration Coordinator

- Check for `docs/modernization-assessment.md`.
- If exists: Extract scores, risks, estimates, and recommendations.
- If missing: Run abbreviated assessment (see `/assess`) to gather basic info.

### Step 2: Define Modernization Scope (30 minutes)

**Active Agent**: Migration Coordinator

**Define Objectives**:

- **Primary** (MUST): Upgrade target, eliminate CRITICAL/HIGH CVEs, 100% test pass.
- **Secondary** (SHOULD): Coverage ≥85%, performance ≥10%.
- **Out of Scope**: UI redesign, feature additions (unless specified).

**Success Criteria**:

- Technical: Framework version, Security score ≥45, Zero CRITICAL/HIGH.
- Business: Delivery timeline, budget.

### Step 3: Phase Planning (60-90 minutes)

**Active Agent**: Architect Agent + Migration Coordinator

For each of the 7 phases, define tasks, duration, team, deliverables, exit criteria, and risks:

1. **Phase 0: Discovery & Assessment**
   - Inventory, Security Baseline, Test Baseline, Technology Assessment.

2. **Phase 1: Security Remediation**
   - Fix CRITICAL/HIGH CVEs, Update Security Dependencies, Validation.

3. **Phase 2: Architecture & Design**
   - Create Migration ADRs, Dependency Matrix, Breaking Changes Analysis, Module Order.

4. **Phase 3: Framework & Dependency Modernization**
   - Upgrade Framework, Update Dependencies, Continuous Testing (Parallel execution).

5. **Phase 4: API Modernization & Code Quality**
   - Replace Obsolete APIs, Apply Modern Patterns, Enhance Coverage.

6. **Phase 5: Performance Optimization**
   - Benchmarks, Bottleneck ID, Optimization, Validation.

7. **Phase 6: Comprehensive Documentation**
   - CHANGELOG, Migration Guide, Update Docs, ADR Summaries. MUST document all architecture recommendations in ADRs.

8. **Phase 7: Final Validation & Release**
   - Complete Test Execution, Final Security Scan, Release Prep, GO/NO-GO.

### Step 4: Timeline & Milestones (30 minutes)

**Active Agent**: Migration Coordinator

- Create **Gantt Chart** estimation.
- Define **Milestones** (M1-M8) with dates and deliverables.

### Step 5: Resource Allocation (30 minutes)

**Active Agent**: Migration Coordinator

- Assign **Team Members** to phases (Lead, Devs, Tester).
- Estimate **Capacity** and **Utilization**.

### Step 6: Risk Management (45 minutes)

**Active Agent**: Migration Coordinator + Architect Agent

- Create **Risk Register**: ID, Risk, Probability, Impact, Severity, Mitigation.
- Develop **Mitigation Strategies** for High-Priority risks (Dependency conflicts, Timeline, Production bugs).

### Step 7: Quality Gates & Decision Points (20 minutes)

**Active Agent**: Migration Coordinator

Define criteria for Gates 1-8 (Post-Phase checks and Final GO/NO-GO).

### Step 8: Contingency Planning (30 minutes)

**Active Agent**: Architect Agent

Define scenarios:

- Critical Dependency missing compat version.
- Test pass rate drops.
- Performance regression.
- Key team member leaves.

---

## `docs/modernization-plan.md` Output Generation

**Active Agent**: Documentation Agent

Create `docs/modernization-plan.md` using the collected data. The document MUST follow this structure:

1. **Executive Summary**: Objectives, Timeline, Team, Success Criteria.
2. **Assessment Summary**: Score, Risks, Mitigation.
3. **Scope**: In/Out scope, criteria.
4. **Phase Breakdown**: Detailed tasks/deliverables for Phases 0-7.
5. **Timeline & Milestones**: Gantt, table.
6. **Resource Allocation**: Team plan.
7. **Risk Management**: Register & Mitigation.
8. **Quality Gates**: Criteria.
9. **Contingency Plans**: Scenarios.
10. **Communication Plan**: Reporting cadence.
