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
