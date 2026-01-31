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

**CRITICAL: Context Management**
Before starting work on ANY new issue, run `/compact` to compress conversation history. This prevents context overflow when working through multiple issues.

1. **Compact context**: Run `/compact` to start with a clean context.
2. List open issues with priority labels.
3. Select highest priority issue.
4. **Create NEW feature branch** (MANDATORY):

   ```bash
   # CRITICAL: Each issue MUST have its own dedicated branch
   # DO NOT reuse branches from previous issues
   git checkout integration
   git pull origin integration
   git checkout -b fix/issue-{ID}-auto
   ```

   **Verification**: Run `git branch --show-current` to confirm you're on the new branch.
5. Comment on issue to mark as "In Progress".

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

### Step 4: Test Verification

**Active Agent**: Tester Agent

**MANDATORY**: Every development cycle MUST include test verification before committing.

1. **Run Relevant Tests**:
   - For targeted fixes: Run specific test suites affected by changes
   - For broader changes: Run full test suite (`npm test` or `/full-regression-test`)

2. **Verify Tests Pass**:

   ```bash
   cd thesis-validator
   npm test 2>&1 | grep -E "(Test Files|Tests|Duration|FAIL)"
   ```

3. **IF Tests Fail**:
   - Analyze failures
   - Fix issues immediately (return to Step 3A or 3B)
   - Re-run tests until passing
   - DO NOT proceed to Step 5 until tests pass

4. **IF Tests Pass**: Proceed to Step 5

### Step 5: Commit, Push, and Merge

**Active Agent**: Integration Agent

**MANDATORY**: Every successful fix cycle MUST end with commit, push, and merge to integration.

1. **Commit Changes**:

   ```bash
   git add .
   git commit -m "fix: [detailed commit message]
   
   [Root cause description]
   [Solution description]
   [Verification results]
   
   Fixes #[issue-number]"
   ```

2. **Push to Feature Branch**:

   ```bash
   git push origin fix/issue-{ID}-auto
   ```

3. **Merge to Integration Branch**:

   ```bash
   # Switch to integration branch
   git checkout integration
   
   # Pull latest changes
   git pull origin integration
   
   # Merge feature branch (fast-forward if possible)
   git merge --no-ff fix/issue-{ID}-auto -m "Merge fix/issue-{ID}-auto: [issue title]"
   
   # Push to integration
   git push origin integration
   ```

4. **Close GitHub Issue**:
   - Comment with summary:
     - **Root Cause**: What was the problem?
     - **Solution**: What was changed?
     - **Verification**: What tests passed?
   - Close issue with `/close` comment or `gh issue close`

5. **Clean Up Feature Branch** (optional):

   ```bash
   git branch -d fix/issue-{ID}-auto
   git push origin --delete fix/issue-{ID}-auto
   ```

**CRITICAL**: Do NOT skip commit/push/merge steps. Every verified fix must be integrated immediately.

---

## No Issues Found?

If no priority issues exist:

1. **Run Full Regression Test**: Create issues for any hidden failures.
2. **Check Enhancements**: Switch to implementing enhancements.
3. **Propose Improvements**: Analyze codebase for coverage gaps or tech debt and propose new issues.

## Continuous Loop

This workflow is designed to run forever.

1. **Compact Context**: Run `/compact` BEFORE starting each new issue to prevent context overflow.
2. **Restart**: When all steps are completed, or if no issues are found, immediately restart from **Step 1: Issue Selection**.
3. **Persistent**: Do not exit. Keep checking for new issues or running regression tests.

**IMPORTANT**: Each issue should start with a fresh, compacted context. Never carry over detailed investigation notes from a previous issue - the compact summary is sufficient.
