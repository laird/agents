# Autocoder Agent (OpenCode)

**Version**: 1.5.0

This directory contains the definition for the **Autocoder** agent on the OpenCode platform.

## Overview

The Autocoder agent is responsible for autonomously resolving GitHub issues with:
- **Issue Triage**: Assigns P0-P3 priority labels to unprioritized issues
- **Bug Resolution**: Fixes prioritized bugs in order (P0 → P1 → P2 → P3)
- **Regression Testing**: Runs comprehensive test suites
- **Proposal System**: Creates enhancement proposals for human approval (NOT auto-implemented)
- **Enhancement Implementation**: Implements only approved enhancements

## Files

| File | Purpose |
|------|---------|
| `agent.md` | Main agent definition with capabilities and responsibilities |
| `workflows/triage.md` | Issue triage workflow (assign P0-P3 labels) |
| `workflows/bug-resolution.md` | Bug fixing workflow |
| `workflows/regression-testing.md` | Test suite execution |
| `workflows/proposals.md` | Proposal creation and management |
| `workflows/enhancement.md` | Approved enhancement implementation |

## Workflow Order

1. **Triage** - Assign priorities to unprioritized issues
2. **Bug Resolution** - Fix P0-P3 bugs in priority order
3. **Regression Testing** - Run tests when no bugs exist
4. **Enhancement** - Implement approved enhancements (NOT proposals)
5. **Proposals** - Create new proposals when no other work exists

## Proposal System (v1.5.0)

AI-generated enhancements are tagged with `proposal` label and require human approval:

- **Proposals are NOT auto-implemented**
- Use `gh issue list --label "proposal"` to view pending proposals
- **Approve**: `gh issue edit <number> --remove-label "proposal"`
- **Reject**: `gh issue close <number> --comment "Rejected: reason"`
- **Feedback**: Comment on issue with suggestions

## Priority Labels

| Label | Severity | Examples |
|-------|----------|----------|
| P0 | Critical | System down, security vulnerability |
| P1 | High | Major feature broken |
| P2 | Medium | Partial functionality |
| P3 | Low | Minor issues, cosmetic |
