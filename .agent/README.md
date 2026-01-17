# Antigravity Configuration

This directory contains configuration, rules, and workflows for the **Antigravity** agent engine.

**Project Guidance File**: `GEMINI.md` (in repository root)

## Parallel Maintenance Requirement

**CRITICAL**: This repository maintains two parallel implementations that MUST stay in sync:

| Platform | Directory | Guidance File |
|----------|-----------|---------------|
| **Antigravity** | `.agent/` | `GEMINI.md` |
| **Claude Code** | `plugins/` | `CLAUDE.md` |

**When modifying any workflow, rule, or protocol:**

1. **Always update BOTH versions** - Changes here must be mirrored to `plugins/`
2. **Check the mapping**:
   - `.agent/workflows/*.md` ↔ `plugins/autocoder/commands/*.md`
   - `.agent/rules/*.md` ↔ `plugins/modernize/agents/*.md`
3. **Verify parity** after changes: Both should have identical functionality
4. **Test both platforms** if possible before committing

**Key parallel files:**
- `/improve-test-coverage`: `.agent/workflows/improve-test-coverage.md` ↔ `plugins/autocoder/commands/improve-test-coverage.md`
- `/fix-github`: `.agent/workflows/fix-github.md` ↔ `plugins/autocoder/commands/fix-github.md`
- `/full-regression-test`: `.agent/workflows/full-regression-test.md` ↔ `plugins/autocoder/commands/full-regression-test.md`

## Structure

- **`protocols/`**: Definitions of agent protocols (how agents should behave).
- **`rules/`**: Custom rules injected into the agent's context.
- **`scripts/`**: Helper scripts used by the agent configuration (e.g., watchdogs).
- **`workflows/`**: Workflow definitions (e.g., `/fix-github`) that chain agent actions.
