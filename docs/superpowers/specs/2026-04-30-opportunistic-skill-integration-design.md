# Opportunistic Skill Integration for Autocoder/Modernize Commands

**Version:** v3
**Date:** 2026-04-30
**Status:** Design — revised after critical-design-review-2; ready for implementation planning

## Problem

The autocoder and modernize plugins encode protocols inline in each command file. When the user has Peter Steinberger's `superpowers` toolkit (or related personal toolkit skills like `critical-design-review`, `critical-implementation-review`, `update-design-doc`, `update-implementation-plan`, `arch-review`, `security-review`, `completion-review`, `create-handoff`, `autocoder:improve-test-coverage`) installed, those skills encode discipline that overlaps and would sharpen specific phases of the existing protocols. Today the commands ignore them.

Goal: have commands **opportunistically** use these skills when present, without taking a hard dependency. If a skill isn't installed, the existing inline protocol runs unchanged.

Non-goal: redesign the commands or replace any existing protocol content.

## Detection mechanism

Claude already receives the full list of available skills in the session-start system-reminder. A command therefore does not need a filesystem probe, try/catch, or shell call — it can simply instruct the agent:

> If the named skill appears in your available skills list, invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below.

In Gemini CLI / Antigravity, the same instruction applies but skills activate via `activate_skill` rather than the `Skill` tool.

### Skill-name matching (CDR1-C3)

Mapping tables use **fully-qualified skill names** (`<plugin>:<skill>`) wherever a plugin namespace exists, and bare names only for personal toolkit skills that appear bare in the available-skills list.

| Form | When to use | Examples |
|---|---|---|
| `<plugin>:<skill>` | Public plugin-installed skills | `superpowers:brainstorming`, `superpowers:writing-plans`, `autocoder:improve-test-coverage` |
| Bare name | User-installed personal toolkit skills | `critical-design-review`, `completion-review`, `create-handoff`, `arch-review`, `security-review` |

**Match exactly.** Each table entry is matched as an exact string against the available-skills list. No prefix, suffix, or fuzzy comparison. If an entry is not present verbatim, treat it as not installed and use the inline fallback.

**Rename-resilience policy.** If a future skill release renames a tracked skill, the table will silently fall through to the fallback. This is intentional — silent fall-through is preferable to invoking a wrong-skill-named-similarly. Mapping tables must be updated when a tracked skill is renamed.

### Skill visibility in dispatched contexts (CDR1-C1, CDR2-C1)

Detection happens at the level where the `Skill` tool will actually be invoked. Two cases:

1. **Top-level commands** (`/brainstorm-issue`, `/approve-proposal`, `/plan`, `/fix` invoked directly). The prelude rule applies to the calling agent. No special plumbing needed.

2. **Dispatcher commands** (`/fix-loop`, `/modernize`). These dispatch worker subagents via the `Task` tool. Workers run in a fresh session and may not see the parent's available-skills list. To preserve skill access at the worker level, the dispatcher prepends a **worker skills manifest** (defined below) to each worker's prompt.

3. **Agent-level files** (`coder.md`, `tester.md`, etc.) are out of scope this round; agent-level integration is deferred.

#### Worker skills manifest (CDR2-C1)

The manifest is a sentinel-versioned canonical text held in the shared prelude file (see "Shared source-of-truth" below). The dispatcher generates the bullet list at command entry by intersecting its own available-skills list with the command's per-worker mapping, and prepends the resulting block as the **first paragraph of the worker prompt**, before the work assignment.

Canonical manifest text (held in `plugins/shared/optional-skills-prelude.md` and Antigravity mirror, sentinel-bracketed `<!-- BEGIN optional-skills-manifest v1 -->` … `<!-- END optional-skills-manifest v1 -->`):

```
The following optional skills are available in your environment. Match each name as an exact string against your available-skills list. If a skill is present, invoke it via the Skill tool at the indicated step; otherwise follow the inline protocol unchanged.

Skills available to this worker:
- <fully-qualified-name-1>
- <fully-qualified-name-2>
- ...

Failure semantics: silent fallback for not-installed; visible failure message for mid-run errors of installed skills; no retry within this run. Skills are advisory; your inline work contract still defines completion.
```

**Per-role policy.** The dispatcher passes the **full intersection** to all workers — the same manifest content goes to every worker the dispatcher spawns in this run. Workers filter by relevance to their own work (a coder worker doesn't need `finishing-a-development-branch` if its assignment doesn't include the merge step; the worker simply doesn't invoke it). Rationale: dispatcher logic stays simple (one intersection per command run); workers already classify their own scope.

**Conflict resolution with `superpowers:subagent-driven-development`.** When the dispatcher invokes that skill (it appears in the dispatcher mappings for `/fix-loop` and `/modernize`), the manifest is **wrapper text** prepended to whatever prompt that skill produces. The skill's prompt-construction discipline owns the body of the worker prompt; the manifest owns the first paragraph. Both apply.

### Failure semantics (CDR1-C4)

| Case | User-facing output |
|---|---|
| `superpowers:*` skill listed in this command's mapping table is not installed | One-time recommendation at command entry pointing to the public superpowers plugin install instructions (consolidated; one line per command run, not per missing skill) |
| Personal toolkit skill not installed | Silent |
| Skill installed, invoked, succeeds | Skill's normal output |
| Skill installed, invoked, fails or interrupts mid-run | Failure message visible (diagnostic); fall back to inline protocol for the remainder of that step; do not retry within the same command run |
| Skill installed, invoked, self-skips (e.g., a `<SUBAGENT-STOP>` directive) | Silent fallback; not treated as failure |

**Recommendation text** (CDR2-M1) — single line, informational tone, ~120 chars max, links to the public superpowers plugin and names the install path:

> *Tip: this command works best with the `superpowers` plugin (https://github.com/obra/superpowers) — install via the Claude Code plugin marketplace.*

This text is held verbatim in the canonical prelude file. URL and install path are verified against the current public superpowers distribution at implementation time and the spec is updated if either has changed.

### Skills are advisory, not gating (CDR1-H3)

A command's completion criteria are defined by its inline protocol. Optional skills, when invoked, sharpen specific steps and surface diagnostic information, but their outcomes do not override the inline protocol's success criteria.

If an invoked skill reports a problem (e.g., `superpowers:verification-before-completion` reports a failed verification), surface the report and treat it as input the agent must consider — but the command itself completes or fails according to its inline criteria. If the skill and the inline protocol disagree, the agent treats the skill's stricter signal as a reason to investigate; the inline protocol remains the contract.

**Clarification on "always applied"** (CDR2-M2). Where a mapping table marks a skill as "always" applied (e.g., `/fix`'s Step 2 branch row lists `superpowers:verification-before-completion` as always), this means the skill is *invoked* at the right step whenever installed. The skill's *outcome* is still advisory per the rule above — invocation is required, gating is not.

### Version trust (CDR1-H1)

This integration matches skills by name and trusts the skill to encode current best discipline. Skills evolve; the integration does not pin versions or verify behavior. If a tracked skill's contract changes in a way that breaks the chain (e.g., output format, handoff convention), the integration is stale and must be updated. Match-by-name is intentional — versioned matching would create maintenance load disproportionate to the value.

**Versions baseline** (CDR2-M3). Recorded in a separate machine-readable file: `docs/superpowers/specs/2026-04-30-skills-baseline.txt` — one fully-qualified-name + version per line. The validation plan's skill-contract-drift check (step 6) diffs the user's current installed versions against this file when investigating "is this still working?"

## Integration shape

Each target command gets one new section, **inserted as the first H2 (`##`) section in the command file body** — immediately after any frontmatter, command-name tag, top-level title, and one-paragraph description, and before all other H2 sections (CDR1-H2). The section is titled **"Optional skill enhancements"**. The existing protocol body is **not modified**. The prelude only adds opportunistic skill invocation.

### Canonical structure per command file

```markdown
<frontmatter / command-name tag, if present>

# <Command Title>

<one-paragraph description of the command's purpose>

## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v1 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->
<canonical boilerplate text — identical across all 12 files>
<!-- END optional-skills-prelude v1 -->

<!-- BEGIN optional-skills-mapping <command-name> v1 — keep in sync between Claude/Antigravity mirrors of this command -->
<per-command mapping tables>
<!-- END optional-skills-mapping <command-name> v1 -->

## <existing first H2 section, e.g., "When to use">
... existing content unchanged ...
```

### Shared source-of-truth (CDR1-C2, extended by CDR2-C2)

Two sentinel scopes, with two canonical files holding the boilerplate text:

- `plugins/shared/optional-skills-prelude.md` (Claude Code)
- `.agent/shared/optional-skills-prelude.md` (Antigravity mirror)

These canonical files contain the boilerplate paragraph (legend, failure semantics, advisory rule, version trust, recommendation text) **and** the worker skills manifest template (CDR2-C1). Each command file embeds:

1. **Boilerplate sentinels** (`optional-skills-prelude v1`) — byte-identical across all 12 command files, cross-platform.
2. **Mapping sentinels** (`optional-skills-mapping <command-name> v1`) — byte-identical between Claude Code and Antigravity mirrors of the same command. Differs from one command to the next.

Drift detection is a two-pass shell pipeline, packaged as `scripts/check-optional-skills-drift.sh` (CDR2-M4):

```bash
#!/usr/bin/env bash
# Pass 1: boilerplate identical across all 12 command files (and the 2 canonical sources).
for f in plugins/shared/optional-skills-prelude.md \
         .agent/shared/optional-skills-prelude.md \
         plugins/*/commands/{brainstorm-issue,approve-proposal,plan,modernize,fix,fix-loop}.md \
         .agent/workflows/{brainstorm-issue,approve-proposal,plan,modernize,fix,fix-loop}.md; do
  awk '/BEGIN optional-skills-prelude v1/,/END optional-skills-prelude v1/' "$f" | sha256sum
done | sort -u  # one unique hash expected

# Pass 2: per-command mapping identical between Claude Code and Antigravity mirror.
for cmd in brainstorm-issue approve-proposal plan modernize fix fix-loop; do
  cc_file=$(find plugins/*/commands -name "${cmd}.md" -print -quit)
  ag_file=".agent/workflows/${cmd}.md"
  cc_hash=$(awk "/BEGIN optional-skills-mapping ${cmd} v1/,/END optional-skills-mapping ${cmd} v1/" "$cc_file" | sha256sum)
  ag_hash=$(awk "/BEGIN optional-skills-mapping ${cmd} v1/,/END optional-skills-mapping ${cmd} v1/" "$ag_file" | sha256sum)
  [ "$cc_hash" = "$ag_hash" ] && echo "${cmd}: OK" || echo "${cmd}: DRIFT"
done
```

The script is runnable manually and wireable as a pre-commit hook or GitHub Actions check. Automating the smoke tests is out of scope this round.

### Notation in mapping tables (CDR1-C5, applied uniformly per CDR2-C3)

Mapping tables use three notations, applied uniformly to every cell that contains a relationship between skills. Free-form prose in mapping cells is not permitted.

| Notation | Meaning | Example |
|---|---|---|
| `A → B → C` | Sequence: invoke in order | `superpowers:brainstorming → superpowers:writing-plans → superpowers:test-driven-development` |
| `A + B + C` | Independent facets: all apply, order irrelevant | `superpowers:subagent-driven-development + superpowers:dispatching-parallel-agents` |
| `A (primary)` | Overlapping orchestration: A is the spine; consult others as named | `superpowers:executing-plans (primary)` |
| Leading `→` on a row | "Then, if applicable" — sequence spanning rows; each row may carry its own trigger | (see `/approve-proposal`) |

Trigger conditions are inline parentheticals attached to the skill name (e.g., `arch-review (only if the proposal introduces architectural patterns)`), not separate sentences below the table.

The notation legend is part of the canonical prelude.

## Scope (this round)

Six commands, each mirrored across both platforms (12 command files + 2 canonical prelude files + 1 baseline file + 1 drift-check script = 16 files total):

| Claude Code | Antigravity mirror |
|---|---|
| `plugins/autocoder/commands/brainstorm-issue.md` | `.agent/workflows/brainstorm-issue.md` |
| `plugins/autocoder/commands/approve-proposal.md` | `.agent/workflows/approve-proposal.md` |
| `plugins/modernize/commands/plan.md` | `.agent/workflows/plan.md` |
| `plugins/modernize/commands/modernize.md` | `.agent/workflows/modernize.md` |
| `plugins/autocoder/commands/fix.md` | `.agent/workflows/fix.md` |
| `plugins/autocoder/commands/fix-loop.md` | `.agent/workflows/fix-loop.md` |

Plus:
- `plugins/shared/optional-skills-prelude.md` and `.agent/shared/optional-skills-prelude.md`
- `docs/superpowers/specs/2026-04-30-skills-baseline.txt`
- `scripts/check-optional-skills-drift.sh`

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
| Architectural soundness check | `→ arch-review` (only if the proposal introduces or changes architectural patterns, module boundaries, or technology choices) |
| Security implications | `→ security-review` (only if the proposal touches authentication, authorization, data handling, external interfaces, secret storage, or dependencies) |

### `/plan`

| Step | Skill mapping |
|---|---|
| Turn spec into implementation plan → review the produced plan → apply review findings | `superpowers:writing-plans` → `critical-implementation-review` → `update-implementation-plan` |

### `/modernize`

| Step | Skill mapping |
|---|---|
| Execute PLAN.md phase-by-phase with checkpoints | `superpowers:executing-plans` (primary) |
| Dispatch coder/tester/etc. agents | `superpowers:subagent-driven-development` + `superpowers:dispatching-parallel-agents` (when 2+ independent worker tasks) |
| Isolate per-stage work | `superpowers:using-git-worktrees` (independent facet) |
| Verify before declaring a phase complete | `superpowers:verification-before-completion` (independent facet) |
| Per-phase wrap-up | `completion-review` |
| Hand off project state | `create-handoff` (invoke at one of: end of each completed phase as part of phase wrap-up; ~30 tool calls without a phase boundary — heuristic, adjust based on observed context pressure in early runs; or explicit user signal) |

See "Worker skills manifest" subsection for dispatcher-to-worker plumbing.

### `/fix`

`/fix` accepts heterogeneous work — bug fixes, feature implementation, refactoring, increasing test coverage, docs/config/chore, or proposing new tasks. The agent classifies the work after reading the issue and applies the matching skills along two axes: deliverable type and kind of work.

**Composition rule** (CDR2-C4). Step 2 and Step 3 compose by **union**: apply every skill named in either step. Where both steps name the same skill, apply it once. Where the two steps disagree on whether a skill is required vs. optional, the **stronger requirement wins** (a skill marked required in one step is required overall, regardless of "optional" framing in the other). Step 1 (deliverable classification) is purely a routing input to Step 2 and produces no skills of its own.

**Step 1: classify the deliverable.**

| Deliverable type | Examples |
|---|---|
| **Branch** (code merged to main) | bug fix, new feature, refactor, increasing test coverage, docs/config/chore committed to the repo |
| **Document** (proposal, report, analysis) | proposing new tasks, investigation findings |
| **Throwaway** (spike, experiment) | rare; ad-hoc evaluation work that won't be merged |

**Step 2: apply the matching skills based on deliverable type.** "Always" below means the skill is invoked when installed; outcomes remain advisory per the advisory-not-gating rule.

| Applies when deliverable is... | Skill mapping |
|---|---|
| **Branch** | `superpowers:using-git-worktrees` + `superpowers:verification-before-completion` + `completion-review` (always); `superpowers:requesting-code-review` → `superpowers:receiving-code-review` (when seeking merge) |
| **Document** | `completion-review` only |
| **Throwaway** | none of the above are required |

**Step 3: apply the matching skills based on kind of work.**

| If the work is... | Use these skills |
|---|---|
| Bug / unexpected behavior | `superpowers:systematic-debugging` → `superpowers:test-driven-development` |
| New feature / unclear requirement | `superpowers:brainstorming` → `superpowers:writing-plans` → `superpowers:test-driven-development` (optional `critical-design-review` after brainstorming, `critical-implementation-review` after writing-plans) |
| Refactor / restructuring | `superpowers:test-driven-development` (characterization tests) → refactor under green |
| Increasing test coverage | `autocoder:improve-test-coverage` → `superpowers:test-driven-development` for new tests |
| Proposing new tasks | `superpowers:brainstorming` → `critical-design-review` |
| Docs / config / chore | TDD optional |

### `/fix-loop`

`/fix-loop` is a dispatcher coordinating parallel workers. The dispatcher and workers have distinct skill mappings.

**Dispatcher level (runs in the host workspace, not a worktree).**

| Step | Skill mapping |
|---|---|
| Plan and dispatch parallel workers | `superpowers:subagent-driven-development` + `superpowers:dispatching-parallel-agents` |
| Provision isolated worktrees for workers | `superpowers:using-git-worktrees` (for workers only; dispatcher runs in host workspace) |

See "Worker skills manifest" subsection for the per-worker plumbing.

**Per-worker level** (each worker in its own worktree; workers receive the dispatcher's manifest and apply the full `/fix` mapping above to their assigned issue, including the same composition rule), plus:

| Step | Skill mapping |
|---|---|
| Each worker finishes its branch (PR / merge) | `superpowers:finishing-a-development-branch` |

## Worked example: prelude block

The canonical prelude inserted near the top of each command file. Per-command mapping tables follow, also sentinel-bracketed.

```markdown
## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v1 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

In Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; the mapping is otherwise identical.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills.

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine. A leading `→` on a row indicates "next in sequence if applicable."

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list, emit one consolidated recommendation line at command entry: *Tip: this command works best with the `superpowers` plugin (https://github.com/obra/superpowers) — install via the Claude Code plugin marketplace.* Never emit such notices for personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria. "Always applied" in a mapping table means the skill is invoked when installed; outcomes remain advisory.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v1 -->

<!-- BEGIN optional-skills-mapping <command-name> v1 — keep in sync between Claude/Antigravity mirrors of this command -->
<per-command mapping tables>
<!-- END optional-skills-mapping <command-name> v1 -->
```

The dispatcher canonical prelude file additionally contains a `<!-- BEGIN optional-skills-manifest v1 -->` … `<!-- END optional-skills-manifest v1 -->` block holding the worker manifest template.

## Validation plan

1. **Parity check.** Read each Claude/Antigravity pair side-by-side; confirm parity. Sub-checks: the prelude is the first H2 in every file; no free-form prose in mapping cells; notation legend applied consistently.
2. **Drift check.** Run `scripts/check-optional-skills-drift.sh`; both passes should report no drift. Also runnable as pre-commit/CI.
3. **Degraded-mode smoke test.** For each of the six commands, run with **zero optional skills installed**. Confirm:
   (a) command completes via inline protocol, (b) for commands referencing `superpowers:*` skills, exactly one up-front recommendation line appears, (c) no error or failure messages from missing skills, (d) no behavior differs from the pre-integration version.
4. **Enhanced-mode smoke test.** Repeat with all optional skills installed; confirm at least one optional skill fires per command (where applicable) and that mid-run failures (manually triggered by denying a Skill tool call) surface visibly.
5. **Drift sanity check.** Modify the canonical prelude file and a per-command mapping; confirm the drift script detects both.
6. **Skill contract drift check (post-shipping).** When a tracked skill's plugin is upgraded, diff installed versions against `2026-04-30-skills-baseline.txt`; manually exercise one command per changed skill and confirm chain behavior.

## Success criteria (CDR2-M5)

After one month of post-rollout use with skills installed, at least one optional skill should fire in **≥60% of `/fix` and `/plan` runs**. Measurement: each of the six commands appends a one-line entry to `HISTORY.md` per run, naming which optional skills were invoked (or "none"). Threshold revisited after the first measurement window; this is a starting signal, not a permanent metric.

## Out of scope, future rounds

- **Agent-level files** (`coder.md`, `tester.md`, `architect.md`, `migration-coordinator.md`, `security.md`, `documentation.md`).
- **Other commands** with weaker but real skill mappings: `/assess`, `/retro`, `/retro-apply`, `/full-regression-test`, `/review-blocked`, `/improve-test-coverage`.
- **Marketplace + plugin version bumps** (handled when this change ships).
- **Skill-routing layer** (CDR1-AAC) — A future migration to a single canonical routing layer was considered and deferred. Trigger conditions: (a) prelude-block count grows beyond ~10 commands, (b) drift is detected despite the sync check, or (c) skill-naming/version policy needs to evolve faster than per-file edits can keep up.
- **Declarative skill-application descriptors** (CDR2-AAC) — Replacing prose mapping tables with machine-readable YAML/JSON descriptors plus a parser was considered and deferred. Trigger conditions: (a) prose tables become demonstrably more fragile than schema-validated descriptors in this codebase or a sibling project, or (b) the routing-layer trigger above also fires (the descriptor approach pairs naturally with a routing layer).
- **Opt-in "skills as gates" mode** — H3 establishes that skills are advisory in this round; an opt-in gating mode is deferred until demonstrated demand.
- **Automated smoke tests.** The drift check is automated; the smoke tests remain manual. Automating them is out of scope.

## Open questions

None at design time. Implementation may surface details (e.g., a mirror file that has drifted from its Claude Code counterpart in unrelated ways, or a command file whose existing structure makes the H2 placement rule ambiguous); those will be flagged rather than silently reconciled.

## Changelog

### v3 (2026-04-30) — addresses critical-design-review-2

**Critical issues:**
- **CDR2-C1** Skills manifest under-specified: Added "Worker skills manifest" subsection with a sentinel-versioned canonical text (held in `plugins/shared/optional-skills-prelude.md`), insertion rule (first paragraph of worker prompt), per-role policy (full intersection passed to all workers; workers filter), and conflict resolution with `superpowers:subagent-driven-development` (manifest is wrapper text around that skill's prompt body).
- **CDR2-C2** Drift check covered only boilerplate, not mapping tables: Added a second sentinel scope (`<!-- BEGIN optional-skills-mapping <command> v1 -->`) and extended the drift-check pipeline to a Pass 2 verifying Claude/Antigravity mirrors of the same command are byte-identical inside mapping sentinels. Pipeline packaged as `scripts/check-optional-skills-drift.sh`.
- **CDR2-C3** Notation rules inconsistently applied: Audited every mapping cell. Rewrote `/modernize`'s dispatch row with `+`; pulled `/approve-proposal`'s sequence into row cells with leading `→`; removed `/fix-loop`'s empty manifest-pass row in favor of the dedicated subsection; condensed `/modernize`'s closing prose to a one-line cross-reference; simplified `/fix`'s "Proposing new tasks" cell. Added the leading-`→` row-spanning convention to the notation legend. Stated explicitly: free-form prose in mapping cells is not permitted.
- **CDR2-C4** `/fix` step composition unspecified: Added "Composition rule" subsection above the three tables — Step 2 ∪ Step 3 with stronger-wins reconciliation; Step 1 is a routing input only. `/fix-loop`'s per-worker section inherits the rule by reference.

**Alternative architectural challenge:**
- **CDR2-AAC** Declarative descriptors: Considered and deferred to "Out of scope, future rounds" with explicit trigger conditions.

**Minor issues:**
- **CDR2-M1** Recommendation text was a placeholder: Pinned in the canonical prelude as a single ~120-char informational line linking to the public superpowers repo and naming the install path.
- **CDR2-M2** "Always applied" / "advisory" tension: Added clarifying sentence in the H3 subsection and at `/fix`'s Step 2 — "always" means invoked at the right step; outcomes remain advisory.
- **CDR2-M3** Version baseline not machine-readable: Extracted to `docs/superpowers/specs/2026-04-30-skills-baseline.txt` (one fully-qualified-name + version per line); validation step 6 diffs against it.
- **CDR2-M4** Validation plan fully manual: Drift check packaged as `scripts/check-optional-skills-drift.sh`, runnable manually and as pre-commit/CI. Smoke tests remain manual; smoke-test automation explicitly out of scope.
- **CDR2-M5** No success criteria: Added "Success criteria" subsection — ≥60% of `/fix` and `/plan` runs invoke at least one optional skill within one month of rollout, measured via per-run `HISTORY.md` entries; threshold revisited after first window.
- **~30 threshold tunability:** Reworded `/modernize`'s `create-handoff` row to label ~30 as a heuristic adjustable based on observed pressure.

### v2 (2026-04-30) — addressed critical-design-review-1
(See review-1 changelog at the bottom of this document for details.)

### v1 (2026-04-30)
Initial design.
