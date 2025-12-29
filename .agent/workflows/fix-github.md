---
description: Autonomous GitHub issue resolution
---

# Autonomous Issue Fix Workflow

**Version**: 1.5.0
**Purpose**: Analyze, prioritize, and fix GitHub issues autonomously
**Input**: GitHub Issues (Bug/Enhancement)
**Output**: Merged PRs, Closed Issues, Proposals

---

## Overview

This workflow autonomously manages and fixes GitHub issues by:

1. **Triaging** unprioritized issues (assigning P0-P3 labels).
2. **Prioritizing** bugs and approved enhancements (P0-P3).
3. **Detecting Complexity** to select the right approach and model.
4. **Fixing** issues using specialized agents and "superpowers".
5. **Verifying** fixes with regression testing.
6. **Proposing** new enhancements (awaiting human approval).

---

## Prioritization Logic

**Priority Order**:

1. **Triage Unprioritized Issues** (assign P0-P3 labels first)
2. **Bugs (P0 > P1 > P2 > P3)**
3. **Approved Enhancements** (enhancements WITHOUT `proposal` label)
4. **Create New Proposals** (enhancements WITH `proposal` label - NOT auto-implemented)

**⚠️ NEVER automatically implement proposals.** Proposals require human approval.

---

## Proposal System

### What is a Proposal?

A **proposal** is an AI-generated enhancement suggestion tagged with the `proposal` label. Proposals are NOT automatically implemented - they require human review and approval.

### How to Manage Proposals

- **List proposals**: `/list-proposals`
- **Approve**: `gh issue edit <number> --remove-label "proposal"`
- **Feedback**: Comment on issue, then `/refine-proposal <number>`
- **Reject**: `gh issue close <number> --comment "Rejected: reason"`

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

### Step 0: Triage Unprioritized Issues

**Active Agent**: Migration Coordinator

1. Fetch all open issues without P0-P3 labels.
2. Review each issue and assign appropriate priority.
3. Comment with triage rationale.

### Step 1: Issue Selection

**Active Agent**: Migration Coordinator

1. List open issues with priority labels (excluding proposals).
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
2. **Check Approved Enhancements**: Implement enhancements WITHOUT `proposal` label.
3. **Create Proposals**: Generate new enhancement proposals (tagged with `proposal` label).

**Note**: Do NOT implement proposals. Wait for human approval.

## Continuous Loop

This workflow is designed to run forever.

1. **Restart**: When all steps are completed, or if no issues are found, immediately restart from **Step 0: Triage**.
2. **Persistent**: Do not exit. Keep checking for new issues or running regression tests.
3. **Proposals**: When only proposals exist, inform user via `/list-proposals` and create additional proposals if needed.
