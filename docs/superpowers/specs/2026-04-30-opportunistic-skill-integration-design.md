# Opportunistic Skill Integration for Autocoder/Modernize Commands

**Version:** v2
**Date:** 2026-04-30
**Status:** Design — revised after critical-design-review-1; ready for implementation planning

## Problem

The autocoder and modernize plugins encode protocols inline in each command file. When the user has Peter Steinberger's `superpowers` toolkit (or related personal toolkit skills like `critical-design-review`, `critical-implementation-review`, `update-design-doc`, `update-implementation-plan`, `arch-review`, `security-review`, `completion-review`, `create-handoff`, `autocoder:improve-test-coverage`) installed, those skills encode discipline that overlaps and would sharpen specific phases of the existing protocols. Today the commands ignore them.

Goal: have commands **opportunistically** use these skills when present, without taking a hard dependency. If a skill isn't installed, the existing inline protocol runs unchanged.

Non-goal: redesign the commands or replace any existing protocol content.

## Detection mechanism

Claude already receives the full list of available skills in the session-start system-reminder. A command therefore does not need a filesystem probe, try/catch, or shell call — it can simply instruct the agent:

> If the named skill appears in your available skills list, invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below.

In Gemini CLI / Antigravity, the same instruction applies but skills activate via `activate_skill` rather than the `Skill` tool.

### Skill-name matching (C3)

Mapping tables use **fully-qualified skill names** (`<plugin>:<skill>`) wherever a plugin namespace exists, and bare names only for personal toolkit skills that appear bare in the available-skills list.

| Form | When to use | Examples |
|---|---|---|
| `<plugin>:<skill>` | Public plugin-installed skills | `superpowers:brainstorming`, `superpowers:writing-plans`, `autocoder:improve-test-coverage` |
| Bare name | User-installed personal toolkit skills | `critical-design-review`, `completion-review`, `create-handoff`, `arch-review`, `security-review` |

**Match exactly.** Each table entry is matched as an exact string against the available-skills list. No prefix, suffix, or fuzzy comparison. If an entry is not present verbatim, treat it as not installed and use the inline fallback.

**Rename-resilience policy.** If a future skill release renames a tracked skill, the table will silently fall through to the fallback. This is intentional — silent fall-through is preferable to invoking a wrong-skill-named-similarly. Mapping tables must be updated when a tracked skill is renamed.

### Skill visibility in dispatched contexts (C1)

Detection happens at the level where the `Skill` tool will actually be invoked. Two cases:

1. **Top-level commands** (`/brainstorm-issue`, `/approve-proposal`, `/plan`, `/fix` invoked directly). The prelude rule applies to the calling agent. No special plumbing needed.

2. **Dispatcher commands** (`/fix-loop`, `/modernize`). These dispatch worker subagents via the `Task` tool. Workers run in a fresh session and may not see the parent's available-skills list. To preserve skill access at the worker level, the **dispatcher MUST include a "skills manifest" in each worker's prompt**, naming the optional skills the worker should invoke if they appear in the worker's own available-skills list.

   Manifest contract: the dispatcher reads its own available-skills list at command entry, identifies which skills from this command's per-worker mapping are present, and includes them by fully-qualified name in the worker prompt with the same fallback rule. Conservative assumption: if a skill is unavailable to the dispatcher, it is also unavailable to workers.

3. **Agent-level files** (`coder.md`, `tester.md`, etc.) are out of scope this round; agent-level integration is deferred.

### Failure semantics (C4)

| Case | User-facing output |
|---|---|
| `superpowers:*` skill listed in this command's mapping table is not installed | One-time recommendation at command entry pointing to the public superpowers plugin install instructions (consolidated; one line per command run, not per missing skill) |
| Personal toolkit skill not installed | Silent |
| Skill installed, invoked, succeeds | Skill's normal output |
| Skill installed, invoked, fails or interrupts mid-run | Failure message visible (diagnostic); fall back to inline protocol for the remainder of that step; do not retry within the same command run |
| Skill installed, invoked, self-skips (e.g., a `<SUBAGENT-STOP>` directive) | Silent fallback; not treated as failure |

The recommendation text for missing superpowers should name the public superpowers plugin and link to its install instructions; exact wording is set at implementation time against the current public superpowers distribution and committed in the canonical prelude file.

### Skills are advisory, not gating (H3)

A command's completion criteria are defined by its inline protocol. Optional skills, when invoked, sharpen specific steps and surface diagnostic information, but their outcomes do not override the inline protocol's success criteria.

If an invoked skill reports a problem (e.g., `superpowers:verification-before-completion` reports a failed verification), surface the report and treat it as input the agent must consider — but the command itself completes or fails according to its inline criteria. If the skill and the inline protocol disagree, the agent treats the skill's stricter signal as a reason to investigate; the inline protocol remains the contract.

### Version trust (H1)

This integration matches skills by name and trusts the skill to encode current best discipline. Skills evolve; the integration does not pin versions or verify behavior. If a tracked skill's contract changes in a way that breaks the chain (e.g., output format, handoff convention), the integration is stale and must be updated. Match-by-name is intentional — versioned matching would create maintenance load disproportionate to the value.

**Versions referenced at design time.** `superpowers` plugin v5.0.7. Personal toolkit skills (`critical-design-review` v1.4.0, `update-design-doc`, `completion-review`, `arch-review`, `security-review`, `critical-implementation-review`, `update-implementation-plan`, `create-handoff`) and `autocoder:improve-test-coverage` were referenced at the versions installed on the design author's workstation on 2026-04-30. These are the baseline for any future "is this still working?" investigation.

## Integration shape

Each target command gets one new section, **inserted as the first H2 (`##`) section in the command file body** — immediately after any frontmatter, command-name tag, top-level title, and one-paragraph description, and before all other H2 sections (H2 placement rule from H2). The section is titled **"Optional skill enhancements"**. The existing protocol body is **not modified**. The prelude only adds opportunistic skill invocation.

### Canonical structure per command file

```markdown
<frontmatter / command-name tag, if present>

# <Command Title>

<one-paragraph description of the command's purpose>

## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v1 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->
<canonical boilerplate text — identical across all 12 files>
<!-- END optional-skills-prelude v1 -->

<per-command mapping tables>

## <existing first H2 section, e.g., "When to use">
... existing content unchanged ...
```

### Shared source-of-truth (C2)

A single canonical file holds the boilerplate text:

- `plugins/shared/optional-skills-prelude.md` (Claude Code)
- `.agent/shared/optional-skills-prelude.md` (Antigravity mirror)

Each command's prelude embeds a byte-identical copy of the boilerplate within sentinel comments (`<!-- BEGIN optional-skills-prelude vN -->` … `<!-- END optional-skills-prelude vN -->`). The version tag (`vN`) is bumped any time the boilerplate text changes. A simple shell pipeline can verify drift:

```bash
# Drift check: every command's sentinel-bracketed region must match the canonical source
for f in plugins/*/commands/{brainstorm-issue,approve-proposal,plan,modernize,fix,fix-loop}.md \
         .agent/workflows/{brainstorm-issue,approve-proposal,plan,modernize,fix,fix-loop}.md; do
  awk '/BEGIN optional-skills-prelude/,/END optional-skills-prelude/' "$f" | sha256sum
done | sort -u  # all hashes should be identical
```

### Notation in mapping tables (C5)

Mapping tables use three notations to disambiguate the relationship between skills at a single step:

| Notation | Meaning | Example |
|---|---|---|
| `A → B → C` | Sequence: invoke in order | `superpowers:brainstorming → superpowers:writing-plans → superpowers:test-driven-development` |
| `A + B + C` | Independent facets: all apply, order irrelevant | `superpowers:subagent-driven-development + superpowers:dispatching-parallel-agents` |
| `A (primary) / B / C (consult as needed)` | Overlapping orchestration: A is the spine; B/C address sub-concerns | `superpowers:executing-plans (primary)` |

The notation legend is part of the canonical prelude.

## Scope (this round)

Six commands, each mirrored across both platforms (12 command files plus 2 shared boilerplate files = 14 files total):

| Claude Code | Antigravity mirror |
|---|---|
| `plugins/autocoder/commands/brainstorm-issue.md` | `.agent/workflows/brainstorm-issue.md` |
| `plugins/autocoder/commands/approve-proposal.md` | `.agent/workflows/approve-proposal.md` |
| `plugins/modernize/commands/plan.md` | `.agent/workflows/plan.md` |
| `plugins/modernize/commands/modernize.md` | `.agent/workflows/modernize.md` |
| `plugins/autocoder/commands/fix.md` | `.agent/workflows/fix.md` |
| `plugins/autocoder/commands/fix-loop.md` | `.agent/workflows/fix-loop.md` |

Plus the two new shared files: `plugins/shared/optional-skills-prelude.md` and `.agent/shared/optional-skills-prelude.md`.

These cover the user's example end-to-end workflow:
`/brainstorm-issue` → `/approve-proposal` → `/plan` → `/modernize` (or `/fix` / `/fix-loop`).

## Per-command mappings

### `/brainstorm-issue`

| Step | Skill mapping |
|---|---|
| Design exploration / requirements dialogue | `superpowers:brainstorming` |
| Self-review of written spec → apply review findings | `critical-design-review` → `update-design-doc` |

### `/approve-proposal`

| Step | Skill mapping |
|---|---|
| Critical design review of the proposal | `critical-design-review` (always for non-trivial proposals) |
| Architectural soundness check | `arch-review` (only if the proposal introduces or changes architectural patterns, module boundaries, or technology choices) |
| Security implications | `security-review` (only if the proposal touches authentication, authorization, data handling, external interfaces, secret storage, or dependencies) |

Sequence when multiple reviews fire: `critical-design-review` → `arch-review` (if applicable) → `security-review` (if applicable).

### `/plan`

| Step | Skill mapping |
|---|---|
| Turn spec into implementation plan → review the produced plan → apply review findings | `superpowers:writing-plans` → `critical-implementation-review` → `update-implementation-plan` |

### `/modernize`

| Step | Skill mapping |
|---|---|
| Execute PLAN.md phase-by-phase with checkpoints | `superpowers:executing-plans` (primary) |
| Dispatch coder/tester/etc. agents | `superpowers:subagent-driven-development` (when dispatching workers); `superpowers:dispatching-parallel-agents` (when 2+ independent worker tasks) |
| Isolate per-stage work | `superpowers:using-git-worktrees` (independent facet) |
| Verify before declaring a phase complete | `superpowers:verification-before-completion` (independent facet) |
| Per-phase wrap-up | `completion-review` |
| Hand off project state | `create-handoff` — invoke at one of: (a) end of each completed phase as part of phase wrap-up, (b) when the conversation has accumulated more than ~30 tool calls without a phase boundary, or (c) when the user signals continuation is needed |

Worker dispatch follows the C1 manifest contract: the dispatcher passes a skills manifest into each worker's prompt naming the present skills from the per-worker mapping (the orchestration spine for individual coder/tester runs).

### `/fix`

`/fix` accepts heterogeneous work — bug fixes, feature implementation, refactoring, increasing test coverage, docs/config/chore, or proposing new tasks. The agent must classify the work after reading the issue and apply the matching skills. The classification has two axes: **deliverable type** and **kind of work**.

**Step 1: classify the deliverable.**

| Deliverable type | Examples |
|---|---|
| **Branch** (code merged to main) | bug fix, new feature, refactor, increasing test coverage, docs/config/chore committed to the repo |
| **Document** (proposal, report, analysis) | proposing new tasks, investigation findings |
| **Throwaway** (spike, experiment) | rare; ad-hoc evaluation work that won't be merged |

**Step 2: apply the matching skills based on deliverable type.**

| Applies when deliverable is... | Skill mapping |
|---|---|
| **Branch** | `superpowers:using-git-worktrees` + `superpowers:verification-before-completion` + `completion-review` (always); `superpowers:requesting-code-review` → `superpowers:receiving-code-review` (when seeking merge) |
| **Document** | `completion-review` only |
| **Throwaway** | none of the above are required |

**Step 3: apply the matching skills based on kind of work.**

| If the work is... | Use these skills |
|---|---|
| Bug / unexpected behavior | `superpowers:systematic-debugging` → `superpowers:test-driven-development` |
| New feature / unclear requirement | `superpowers:brainstorming` → `superpowers:writing-plans` → `superpowers:test-driven-development`; optional `critical-design-review` after brainstorming, `critical-implementation-review` after writing-plans |
| Refactor / restructuring | `superpowers:test-driven-development` (characterization tests) → refactor under green |
| Increasing test coverage | `autocoder:improve-test-coverage` → `superpowers:test-driven-development` for new tests |
| Proposing new tasks | `superpowers:brainstorming` → `critical-design-review` (deliverable is a document; Step 2 confirms worktree/PR don't apply) |
| Docs / config / chore | TDD optional |

### `/fix-loop`

`/fix-loop` is a dispatcher coordinating parallel workers. The dispatcher and workers have distinct skill mappings.

**Dispatcher level (runs in the host workspace, not a worktree).**

| Step | Skill mapping |
|---|---|
| Plan and dispatch parallel workers | `superpowers:subagent-driven-development` + `superpowers:dispatching-parallel-agents` |
| Provision isolated worktrees for workers | `superpowers:using-git-worktrees` (invoked **for workers only**, not to relocate the dispatcher itself) |
| Pass skills manifest to each worker prompt | (C1 contract; see Skill visibility in dispatched contexts) |

**Per-worker level** (each worker in its own worktree; workers receive the dispatcher's skills manifest and apply the full `/fix` mapping above to their assigned issue), plus:

| Step | Skill mapping |
|---|---|
| Each worker finishes its branch (PR / merge) | `superpowers:finishing-a-development-branch` |

## Worked example: prelude block

Below is the canonical block (sentinel-bracketed boilerplate) inserted near the top of each command file. Per-command mapping tables follow the closing sentinel.

```markdown
## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v1 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

In Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; the mapping is otherwise identical.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills.

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine.

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list, emit one consolidated recommendation line at command entry pointing the user to the public superpowers plugin install instructions; never emit such notices for personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v1 -->

<per-command mapping table(s) follow>
```

## Validation plan

1. **Parity check.** Read each Claude/Antigravity pair side-by-side; confirm parity. Sub-check: confirm the prelude is the first H2 in every file.
2. **Prelude consistency check.** Run the C2 byte-comparison sync check across all 12 command files plus the 2 canonical sources; confirm sentinel-bracketed boilerplate is byte-identical.
3. **Degraded-mode smoke test.** For each of the six commands, run it in an environment with **zero optional skills installed** (neither superpowers nor personal toolkit). Confirm that:
   (a) the command completes using only its inline protocol,
   (b) for commands referencing `superpowers:*` skills, exactly one up-front recommendation line appears,
   (c) no error or failure messages appear from the missing skills,
   (d) no behavior differs from the pre-integration version of the command.
4. **Enhanced-mode smoke test.** Repeat with all optional skills installed; confirm at least one optional skill fires per command (where applicable) and that mid-run failures (manually triggered by denying a Skill tool call) surface visibly.
5. **Drift sanity check.** Modify the canonical prelude file; confirm the sync check from step 2 detects the divergence.
6. **Skill contract drift check (post-shipping).** When a tracked skill's plugin is upgraded in the future, manually run one command exercising that skill and confirm chain behavior is intact.

## Out of scope, future rounds

- **Agent-level files** (`coder.md`, `tester.md`, `architect.md`, `migration-coordinator.md`, `security.md`, `documentation.md`).
- **Other commands** with weaker but real skill mappings: `/assess`, `/retro`, `/retro-apply`, `/full-regression-test`, `/review-blocked`, `/improve-test-coverage`.
- **Marketplace + plugin version bumps** (handled when this change ships).
- **Skill-routing layer** — A future migration to a single canonical routing layer (replacing the 12 prelude blocks with one document plus per-command hook tables) was considered and deferred. The C2 fix (sentinel-versioned boilerplate, canonical source file) reduces immediate drift risk and pre-positions the codebase for that migration if it later becomes warranted. Triggers for revisiting: (a) the prelude-block count grows beyond ~10 commands, (b) drift is detected despite the sync check, or (c) skill-naming/version policy needs to evolve faster than per-file edits can keep up.
- **Opt-in "skills as gates" mode** — H3 establishes that skills are advisory in this round. If a future user wants skill outcomes to gate command completion, an explicit opt-in mode could be added; deferred until demonstrated demand.

## Open questions

None at design time. Implementation may surface details (e.g., a mirror file that has drifted from its Claude Code counterpart in unrelated ways, or a command file whose existing structure makes the H2 placement rule ambiguous); those will be flagged rather than silently reconciled.

## Changelog

### v2 (2026-04-30) — addresses critical-design-review-1

**Critical issues:**
- **CDR1-C1** Subagent / worker execution context: Added "Skill visibility in dispatched contexts" subsection requiring dispatcher commands (`/fix-loop`, `/modernize`) to pass a skills manifest into each worker's prompt at command entry; top-level commands' preludes apply to the calling agent directly. Per-worker mappings labeled accordingly.
- **CDR1-C2** No shared source-of-truth for boilerplate: Added two canonical files (`plugins/shared/optional-skills-prelude.md` and `.agent/shared/optional-skills-prelude.md`) plus sentinel-versioned (`<!-- BEGIN/END optional-skills-prelude v1 -->`) byte-identical embedding in every command file. Drift check shell pipeline added to validation plan.
- **CDR1-C3** Skill-name namespacing inconsistent: All mapping tables now use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills. "(sp)" annotation removed; exact-string matching rule and rename-resilience policy stated explicitly.
- **CDR1-C4** No defined behavior on skill failure or denial: Added "Failure semantics" matrix — silent fallback for not-installed and self-skip; visible diagnostic for mid-run failure of installed skills; one-time consolidated up-front recommendation for missing `superpowers:*` skills only (never for personal toolkit skills).
- **CDR1-C5** Multi-skill ordering and overlap: Introduced explicit notation (`→` for sequence, `+` for independent facets, `(primary)` for overlapping orchestration). Split `/modernize`'s execution row into multiple rows so independent facets are visible. Rewrote `/fix`'s feature-work row and review-update sequences in `/brainstorm-issue` and `/plan` to use `→`.

**Alternative architectural challenge:**
- **CDR1-AAC** Skill-routing layer: Considered and rejected for this round; deferred to "Out of scope, future rounds" with explicit trigger conditions for revisiting.

**Minor issues:**
- **CDR1-M1** `/approve-proposal` review-skill ambiguity: Replaced flat three-row mapping with explicit relevance triggers per row.
- **CDR1-M2** `/fix` always-applicable framing: Restructured prelude into three stacked tables — deliverable classification, applies-when-deliverable-is, and by-kind-of-work.
- **CDR1-M3** `/modernize` `create-handoff` trigger vagueness: Replaced with three concrete triggers (phase completion, ~30-tool-call threshold, user signal).
- **CDR1-M4** Missing degraded-mode test: Validation plan expanded from 3 to 5 checks; added degraded-mode smoke test, enhanced-mode smoke test, drift sanity check.
- **CDR1-M5** `/fix-loop` dispatcher worktree status: Stated explicitly that the dispatcher runs in the host workspace, not a worktree; `using-git-worktrees` at the dispatcher level is invoked to provision worker worktrees only.

**Holistic improvements:**
- **H1** Skill version sensitivity: Added "Version trust" subsection codifying match-by-name (no version pinning), recorded baseline skill versions seen at design time, added skill-contract-drift check to validation plan.
- **H2** Prelude placement unspecified: Stated that the prelude is the first H2 section in the command file body, immediately after frontmatter/title/description; canonical structure documented; implementation plan flags ambiguous existing files for case-by-case handling.
- **H3** Skill-invocation completeness semantics: Stated that skills are advisory, not gating — inline protocols define completion; skill outcomes are surfaced and considered but do not override inline success criteria.

### v1 (2026-04-30)
Initial design.
