# Opportunistic Skill Integration for Autocoder/Modernize Commands

**Date:** 2026-04-30
**Status:** Design — approved for implementation planning

## Problem

The autocoder and modernize plugins encode protocols inline in each command file. When the user has Peter Steinberger's `superpowers` toolkit (or related skills like `critical-design-review`, `critical-implementation-review`, `update-design-doc`, `update-implementation-plan`, `arch-review`, `security-review`, `completion-review`, `create-handoff`, `autocoder:improve-test-coverage`) installed, those skills encode discipline that overlaps and would sharpen specific phases of the existing protocols. Today the commands ignore them.

Goal: have commands **opportunistically** use these skills when present, without taking a hard dependency. If a skill isn't installed, the existing inline protocol runs unchanged.

Non-goal: redesign the commands or replace any existing protocol content.

## Detection mechanism

Claude already receives the full list of available skills in the session-start system-reminder. A command therefore does not need a filesystem probe, try/catch, or shell call — it can simply instruct the agent:

> If the named skill appears in your available skills, invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below.

In Gemini CLI / Antigravity, the same instruction applies but skills activate via `activate_skill` rather than the `Skill` tool.

## Integration shape

Each target command gets one new section, inserted near the top — after the command description, before the existing protocol body — titled **"Optional skill enhancements"**. The section contains:

1. The one-line rule above.
2. A mapping table that pairs steps in the command's existing protocol to the preferred skill(s).
3. A note on the Gemini CLI / Antigravity tool name difference.

The existing protocol body is **not modified**. The prelude only adds opportunistic skill invocation.

## Scope (this round)

Six commands, each mirrored across both platforms (12 files total):

| Claude Code | Antigravity mirror |
|---|---|
| `plugins/autocoder/commands/brainstorm-issue.md` | `.agent/workflows/brainstorm-issue.md` |
| `plugins/autocoder/commands/approve-proposal.md` | `.agent/workflows/approve-proposal.md` |
| `plugins/modernize/commands/plan.md` | `.agent/workflows/plan.md` |
| `plugins/modernize/commands/modernize.md` | `.agent/workflows/modernize.md` |
| `plugins/autocoder/commands/fix.md` | `.agent/workflows/fix.md` |
| `plugins/autocoder/commands/fix-loop.md` | `.agent/workflows/fix-loop.md` |

These cover the user's example end-to-end workflow:
`/brainstorm-issue` → `/approve-proposal` → `/plan` → `/modernize` (or `/fix` / `/fix-loop`).

Out of scope this round: agent-level files (`coder.md`, `tester.md`, etc.); other commands (`/assess`, `/retro`, `/retro-apply`, `/full-regression-test`, `/review-blocked`, `/improve-test-coverage`); installation/listing/monitoring commands.

## Per-command mappings

Skills marked **(sp)** are from Peter's `superpowers` plugin. Unmarked are user-installed toolkit skills.

### `/brainstorm-issue`

| Step | Skill (if installed) |
|---|---|
| Design exploration / requirements dialogue | **brainstorming** (sp) |
| Self-review of written spec | **critical-design-review** |
| Apply review findings to spec | **update-design-doc** |

### `/approve-proposal`

| Step | Skill (if installed) |
|---|---|
| Review the proposed design | **critical-design-review** |
| Architectural soundness check | **arch-review** |
| Security implications | **security-review** |

### `/plan`

| Step | Skill (if installed) |
|---|---|
| Turn spec into implementation plan | **writing-plans** (sp) |
| Review the produced plan | **critical-implementation-review** |
| Apply review findings to the plan | **update-implementation-plan** |

### `/modernize`

| Step | Skill (if installed) |
|---|---|
| Execute PLAN.md phase-by-phase with checkpoints | **executing-plans** (sp) |
| Dispatch coder/tester/etc. agents in parallel | **subagent-driven-development** (sp), **dispatching-parallel-agents** (sp) |
| Isolate per-stage work | **using-git-worktrees** (sp) |
| Verify before declaring a phase complete | **verification-before-completion** (sp) |
| Per-phase wrap-up | **completion-review** |
| Hand off when context fills mid-project | **create-handoff** |

### `/fix`

`/fix` is not bug-fixing only — it can be feature work, refactoring, test-coverage work, docs/chore, or proposing new tasks. The agent must classify the work after reading the issue and invoke the matching set. Classifications are not exclusive; pick all that apply.

**Always-applicable** (when the deliverable is code on a branch):

| Step | Skill (if installed) |
|---|---|
| Isolate the work | **using-git-worktrees** (sp) |
| Verify before claiming done | **verification-before-completion** (sp) |
| Wrap-up review | **completion-review** |
| Before requesting merge | **requesting-code-review** (sp) |
| When responding to review feedback | **receiving-code-review** (sp) |

**By kind of work:**

| If the work is... | Use these skills (if installed) |
|---|---|
| **Bug / unexpected behavior** | **systematic-debugging** (sp) → **test-driven-development** (sp) |
| **New feature / unclear requirement** | **brainstorming** (sp) → **writing-plans** (sp) → **test-driven-development** (sp); optional **critical-design-review** / **critical-implementation-review** before coding |
| **Refactor / restructuring** | **test-driven-development** (sp) for characterization tests, then refactor under green |
| **Increasing test coverage** | **autocoder:improve-test-coverage** → **test-driven-development** (sp) for new tests |
| **Proposing new tasks to work on** | **brainstorming** (sp) to explore the space → **critical-design-review** on the proposal. Deliverable is a proposal document, not a branch — the always-applicable worktree/PR rows do not apply. |
| **Docs / config / chore** | TDD optional; verification-before-completion still applies |

### `/fix-loop`

The dispatcher coordinates parallel workers; each worker performs a `/fix`-style slice.

**Dispatcher level:**

| Step | Skill (if installed) |
|---|---|
| Plan and dispatch parallel workers | **subagent-driven-development** (sp), **dispatching-parallel-agents** (sp) |
| Provision isolated worktrees per worker | **using-git-worktrees** (sp) |

**Per-worker level:** apply the full `/fix` mapping above (classification + always-applicable rows), plus:

| Step | Skill (if installed) |
|---|---|
| Each worker finishes its branch (PR / merge) | **finishing-a-development-branch** (sp) |

## Worked example: prelude block

Below is the canonical block that will be inserted near the top of each command file. Tables differ per command; surrounding text is identical.

```markdown
## Optional skill enhancements

If the named skill appears in your available skills (system-reminder at session start), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

In Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; the mapping is otherwise identical.

| Step in this command | Preferred skill (if installed) |
|---|---|
| <step> | <skill> |
| ... | ... |

Skills marked (sp) are from the `superpowers` plugin; unmarked are user-installed toolkit skills.
```

## Validation plan

After implementation:

1. Read each Claude/Antigravity pair side-by-side to confirm parity.
2. Diff-check the six prelude blocks for consistent wording (rule sentence, Gemini note).
3. No automated test for command behavior — manual smoke test by the user.

## Out of scope, future rounds

- Agent-level files (`coder.md`, `tester.md`, `architect.md`, `migration-coordinator.md`, `security.md`, `documentation.md`)
- Other commands with weaker but real skill mappings: `/assess`, `/retro`, `/retro-apply`, `/full-regression-test`, `/review-blocked`, `/improve-test-coverage`
- Marketplace + plugin version bumps (will be handled when the change ships)

## Open questions

None at design time. Implementation may surface details (e.g., a mirror file that has drifted from its Claude Code counterpart in unrelated ways); those will be flagged rather than silently reconciled.
