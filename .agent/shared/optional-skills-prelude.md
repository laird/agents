# Canonical Optional Skills Prelude

This file holds the canonical text embedded by sentinel into every command file that
participates in opportunistic skill integration. Drift between this file and the
embedded copies is detected by `scripts/check-optional-skills-drift.sh`.

When updating the boilerplate, bump `v2` → `v3` everywhere simultaneously and
regenerate all embeddings before commit. `scripts/check-optional-skills-drift.sh`
matches any `v<N>`, so the bump does not require a script edit — but the sentinels
must still move together, or the embeddings will not match this file.

## Boilerplate (embedded by every command file)

The block below — including the BEGIN/END sentinels — is copied byte-identically into
every target command file as the first H2 (`## Optional skill enhancements`) section
body.

<!-- BEGIN optional-skills-prelude v2 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

Platform note: in Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; in Codex they activate as `$<skill>`; in Factory Droid they load from the skills tree. The mapping is otherwise identical on all four platforms.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills. Compound Engineering skills are the exception: match them in **either** form — fully-qualified `compound-engineering:ce-<name>` (how Claude Code lists them) or bare `ce-<name>` (how Codex, Factory Droid, and Antigravity list them).

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine. A leading `→` on a row indicates "next in sequence if applicable."

**Compound Engineering precedence.** If a skill from the `compound-engineering` plugin covers a role in the table below and appears in your available-skills list, invoke it *in place of* the skill named in the mapping tables for that role. Compound Engineering outranks both `superpowers:*` and personal toolkit skills. Roles with no entry below are unaffected.

| Role | Use when installed | In place of |
|---|---|---|
| design exploration / requirements | `ce-brainstorm` | `thorough-brainstorming`, `superpowers:brainstorming` |
| implementation planning | `ce-plan` | `thorough-writing-plans`, `superpowers:writing-plans` |
| executing a plan | `ce-work` | `superpowers:executing-plans` |
| debugging a defect | `ce-debug` | `superpowers:systematic-debugging` |
| reviewing a spec or plan document | `ce-doc-review` | `critical-design-review`, `critical-implementation-review`, `update-design-doc`, `update-implementation-plan` |
| reviewing written code | `ce-code-review` | `completion-review`, `superpowers:requesting-code-review` |
| acting on review feedback | `ce-resolve-pr-feedback` | `superpowers:receiving-code-review` |
| session handoff | `ce-handoff` | `create-handoff`, `resume-handoff` |

Worktree provisioning and branch finishing are **not** substituted: `superpowers:using-git-worktrees` and `superpowers:finishing-a-development-branch` remain in force, because the inline protocol owns worktree naming, the issue-claim sequence, and the configured Merge Mode.

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list **and no installed Compound Engineering skill covers its role**, emit one consolidated recommendation line at command entry: *Tip: this command works best with the `superpowers` plugin (https://github.com/obra/superpowers) — install via `/plugin install superpowers@claude-plugins-official`.* Never emit such notices for Compound Engineering or personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria. "Always applied" in a mapping table means the skill is invoked when installed; outcomes remain advisory. When a command claims success while an advisory skill earlier in the run surfaced a failure, the success summary acknowledges the advisory finding.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v2 -->

## Worker skills manifest (referenced by dispatcher commands /fix-loop and /modernize)

The block below is prepended by dispatchers as the **first paragraph of each worker's
prompt**. The bullet list is generated at dispatch time as the intersection of the
dispatcher's available-skills list with the command's per-worker mapping.

<!-- BEGIN optional-skills-manifest v2 -->

The following optional skills are available in your environment. Match each name as an exact string against your available-skills list. If a skill is present, invoke it via the Skill tool at the indicated step; otherwise follow the inline protocol unchanged.

Where a Compound Engineering skill (`compound-engineering:ce-<name>`, or bare `ce-<name>` outside Claude Code) is listed, prefer it over any `superpowers:*` or bare-name toolkit skill covering the same role.

Skills available to this worker:
- <fully-qualified-name-1>
- <fully-qualified-name-2>
- ...

Failure semantics: silent fallback for not-installed; visible failure message for mid-run errors of installed skills; no retry within this run. Skills are advisory; your inline work contract still defines completion.

<!-- END optional-skills-manifest v2 -->
