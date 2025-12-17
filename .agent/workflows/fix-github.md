---
description: Autonomous GitHub issue resolution
---

# Autonomous Issue Fix Workflow

**Version**: 1.0
**Purpose**: Analyze, prioritize, and fix GitHub issues autonomously
**Input**: GitHub Issues (Bug/Enhancement)
**Output**: Merged PRs, Closed Issues

---

## Overview

This workflow autonomously manages and fixes GitHub issues by:

1. **Prioritizing** bugs and enhancements (P0-P3).
2. **Detecting Complexity** to select the right approach and model.
3. **Fixing** issues using specialized agents and "superpowers".
4. **Verifying** fixes with regression testing.

---

## Prioritization Logic

**Priority Order**:

1. **Bugs (P0 > P1 > P2 > P3)**
2. **Existing Enhancements**
3. **Propose New Enhancements**

---

## Issue Complexity & Model Selection

**Simple Issues** (Direct Fix - **Sonnet**):

- Single file changes, config tweaks, small bugs.
- Approach: Read -> Fix -> Verify -> Commit.

**Complex Issues** (Superpowers - **Opus/Sonnet 3.5**):

- Multiple failing tests, feature implementation, architecture changes.
- Approach: Systematic Debugging -> Brainstorming -> Plan -> Execute.

---

## Workflow Steps

### Step 1: Issue Selection

**Active Agent**: Migration Coordinator

1. List open issues with priority labels.
2. Select highest priority issue.
3. Create feature branch: `fix/issue-{ID}-auto`.
4. Comment on issue to mark as "In Progress".

### Step 2: Complexity Analysis

**Active Agent**: Coder Agent

Analyze issue to determine complexity:

- **IF Simple**: Proceed to Step 3A.
- **IF Complex**: Proceed to Step 3B.

### Step 3A: Simple Fix (Direct)

**Active Agent**: Coder Agent

1. **Read** code to understand root cause.
2. **Reproduce** with a test case.
3. **Implement** fix.
4. **Verify** locally.

### Step 3B: Complex Fix (Superpowers)

**Active Agent**: Coder Agent + Architect Agent

1. **Systematic Debugging**: Investigate root cause, analyze patterns.
2. **Brainstorming**: Design fix approach, validate assumptions.
3. **Writing Plans**: Create detailed task list.
4. **Executing Plans**: Implement in batches.
5. **Verification**: Run rigorous tests before completion.

### Step 4: Verification & Regression

**Active Agent**: Tester Agent

1. Run **Full Regression Test** (`/full-regression-test`).
2. **IF Failures**:
   - Create/Update issues for regressions.
   - Revert or fix immediately.
3. **IF Pass**: Proceed to completion.

### Step 5: Completion

**Active Agent**: Documentation Agent

1. Commit changes with detailed message.
2. Merge to `main`.
3. Close GitHub issue with summary (Root Cause, Solution, Verification).

---

## No Issues Found?

If no priority issues exist:

1. **Run Full Regression Test**: Create issues for any hidden failures.
2. **Check Enhancements**: Switch to implementing enhancements.
3. **Propose Improvements**: Analyze codebase for coverage gaps or tech debt and propose new issues.

## Continuous Loop

This workflow is designed to run forever.

1.  **Restart**: When all steps are completed, or if no issues are found, immediately restart from **Step 1: Issue Selection**.
2.  **Persistent**: Do not exit. Keep checking for new issues or running regression tests.
