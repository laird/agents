# Codex Skill Migration Plan

## Goal

Convert the Claude Code plugin protocols in this repo into Codex-native skills without losing the existing workflow logic, scripts, or specialist role separation.

## Current State

The repository already contains three layers:

1. `plugins/` holds Claude Code command protocols and automation scripts.
2. `agents/` holds Antigravity / Gemini agent-oriented role and workflow definitions.
3. `scripts/` holds reusable shell automation that is already platform-agnostic.

That means the main migration problem is not workflow design. It is packaging and trigger design.

## Non-Goals

- Do not modify or regress the Claude Code plugin UX under `plugins/`.
- Do not repurpose `agents/` as Codex assets.
- Do not require Codex-specific rewrites of shared scripts unless a script depends on Claude-only runtime behavior.

## Conversion Strategy

### What ports cleanly to Codex skills

- Protocol-style markdown from `plugins/modernize/commands/` and `plugins/autocoder/commands/`
- Specialist role definitions from `plugins/modernize/agents/`
- Reusable shell automation in `plugins/autocoder/scripts/` and repo `scripts/`
- Existing workflow decomposition embedded in plugin command docs

### What does not port 1:1

- Claude slash-command UX
- Claude-specific hook and `/loop` behavior
- Claude-specific references to Task-model selection and plugin marketplace installation
- tmux/cmux orchestration text that assumes another runtime controls parallel agent sessions

These need Codex-specific instructions, not a literal copy.

## Recommended Skill Shape

Create two top-level skill families:

1. `skills/autocoder`
2. `skills/modernize`

Then split detailed behavior into references so `SKILL.md` stays short and triggerable.

If Codex later needs its own agent definitions, add them under a new Codex-only directory such as `codex/agents/` or `skills/<name>/agents/`. Keep them separate from `agents/`.

### Why two families first

- They match the repo's major product boundaries.
- They preserve the mental model users already have.
- They let Codex load only one family at a time.
- They avoid prematurely exploding the repo into a dozen tiny skills.

## Command-to-Skill Mapping

| Claude plugin command | Codex skill handling | Notes |
|---|---|---|
| `/fix` | `autocoder` core workflow | Direct fit |
| `/fix-loop` | `autocoder` continuous mode reference | Rewrite around Codex session + shell loops |
| `/stop-loop` | `autocoder` loop stop guidance | No dedicated skill needed initially |
| `/review-blocked` | `autocoder` blocked issue workflow | Good candidate for later extraction |
| `/full-regression-test` | `autocoder` testing sub-workflow | Direct fit |
| `/improve-test-coverage` | `autocoder` testing sub-workflow | Direct fit |
| `/list-proposals` | `autocoder` proposal review flow | Direct fit |
| `/approve-proposal` | `autocoder` proposal approval flow | Direct fit |
| `/list-needs-design` | `autocoder` blocked issue listing | Direct fit |
| `/list-needs-feedback` | `autocoder` blocked issue listing | Direct fit |
| `/brainstorm-issue` | `autocoder` design support flow | Could later become separate skill |
| `/install` | `autocoder` setup reference | Keep script-driven |
| `/assess` | `modernize` assessment flow | Direct fit |
| `/plan` | `modernize` planning flow | Direct fit |
| `/modernize` | `modernize` execution flow | Direct fit |
| `/retro` | `modernize` retrospective flow | Direct fit |
| `/retro-apply` | `modernize` improvement application flow | Direct fit |

## Packaging Rules

### Autocoder

- Keep `SKILL.md` focused on trigger conditions, workflow order, and blocking-label policy.
- Put issue-selection, proposal, testing, and loop details in `references/`.
- Reuse `plugins/autocoder/scripts/regression-test.sh` directly instead of re-describing test behavior.
- Treat GitHub CLI operations as first-class actions, not examples.
- Add new Codex-specific scripts only for gaps created by Claude-only hooks or loop semantics.

### Modernize

- Keep `SKILL.md` focused on the assess -> plan -> execute -> retro lifecycle.
- Move detailed phase rules into references that point to existing protocol docs.
- Reuse root `scripts/` for history logging, dependency analysis, stage testing, and validation.
- Preserve quality gates exactly; they are the strongest part of the existing design.
- Keep Codex assets additive in `skills/` and optional Codex-only helper script locations.

## Gaps To Resolve During Migration

### 1. Runtime assumptions

Claude plugins assume slash commands and sometimes a managed loop runtime. Codex skills need plain-language triggers and shell-driven execution.

### 2. Parallel orchestration

The current docs assume external session managers. In Codex, parallelism should be reframed as:

- subagents when supported by the environment
- multiple terminal sessions when not
- scriptable worktree coordination where scripts already exist

### 3. Config source

Several workflows assume `CLAUDE.md`. Codex equivalents should read `AGENTS.md` first, then `CLAUDE.md` only as legacy fallback.

### 4. Installation language

Plugin marketplace installation docs should be removed from skill bodies. Skills should assume they are already available in the Codex environment or shipped from this repo.

## Phased Rollout

### Phase 1: Structural conversion

- Add top-level `skills/autocoder` and `skills/modernize`
- Create concise `SKILL.md` entrypoints
- Add reference docs that point to existing protocols and scripts

### Phase 2: Behavioral cleanup

- Remove Claude-only language from references
- Replace slash-command phrasing with direct task phrasing
- Rebase config instructions around `AGENTS.md`

### Phase 3: Deeper decomposition

- Extract optional focused skills for `review-blocked`, `modernize-assess`, and `modernize-retro`
- Add UI metadata only if this repo adopts Codex skill catalog tooling

## Recommended First Deliverables

1. Repo-local skill scaffold for `autocoder`
2. Repo-local skill scaffold for `modernize`
3. Reference files that preserve command mappings without duplicating whole plugin docs
4. Follow-up pass to rewrite Claude-only assumptions
5. Only after skill validation, add Codex-only agents or scripts where reuse is not sufficient

## Success Criteria

- A Codex user can discover the two skill families from metadata alone.
- Skill bodies stay short and route the model to the right scripts and references.
- Existing shell automation remains the source of truth for execution-heavy steps.
- The repo no longer depends on Claude plugin semantics to explain its primary workflows.
