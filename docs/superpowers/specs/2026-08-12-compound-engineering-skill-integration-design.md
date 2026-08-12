# Compound Engineering Skill Integration — Design

**Date:** 2026-08-12
**Status:** Approved
**Topic:** Make the opportunistic optional-skills integration prefer skills from the
[compound-engineering plugin](https://github.com/EveryInc/compound-engineering-plugin)
when they are installed.

## Problem

The autocoder/modernize commands already degrade gracefully across two skill tiers:
fully-qualified plugin skills (`superpowers:*`, `autocoder:*`) and bare-name personal
toolkit skills (`thorough-brainstorming`, `critical-design-review`, `completion-review`,
…). The compound-engineering plugin (`compound-engineering:ce-*`) ships skills that cover
many of the same roles. When it is installed, its skills should be used; when it is not,
behavior must be exactly what it is today.

## Decisions

1. **Precedence is expressed once, in the shared prelude** — not spread across the seven
   per-command mapping tables. A single role → CE-skill table plus a precedence rule lets
   every existing mapping table stay as written.
2. **CE outranks both other tiers.** Order: `compound-engineering:*` > `superpowers:*` /
   personal toolkit > inline protocol.
3. **Two roles are deliberately not substituted:** worktree provisioning and branch
   finishing. The inline protocol owns worktree naming (`main-wt-N`), the
   working-label → branch → comment claim sequence, and the configured Merge Mode
   (`merge` vs `pr`). `compound-engineering:ce-worktree` and
   `compound-engineering:ce-commit-push-pr` would compete with that machinery.
4. **No install nagging for CE**, and a role covered by an installed CE substitute no
   longer counts as a missing `superpowers:*` skill for the entry-time recommendation.

## Design

### 1. Prelude boilerplate: v1 → v2

`plugins/shared/optional-skills-prelude.md` is the declared source of truth. The
boilerplate between the `optional-skills-prelude` sentinels gains a **Compound
Engineering precedence** section; the sentinels bump `v1` → `v2` in the canonical file,
both `.agent`/`plugins` shared copies, all 14 command files, and the `awk` patterns in
`scripts/check-optional-skills-drift.sh`.

Text added to the boilerplate:

> **Compound Engineering precedence.** If a skill from the `compound-engineering` plugin
> covers a role in the table below and appears in your available-skills list, invoke it
> *in place of* the skill named in the mapping tables for that role. CE outranks both
> `superpowers:*` and personal-toolkit skills. Roles with no CE entry are unaffected.
>
> | Role | Use when installed | In place of |
> |---|---|---|
> | design exploration / requirements | `compound-engineering:ce-brainstorm` | `thorough-brainstorming`, `superpowers:brainstorming` |
> | implementation planning | `compound-engineering:ce-plan` | `thorough-writing-plans`, `superpowers:writing-plans` |
> | executing a plan | `compound-engineering:ce-work` | `superpowers:executing-plans` |
> | debugging a defect | `compound-engineering:ce-debug` | `superpowers:systematic-debugging` |
> | reviewing a spec or plan document | `compound-engineering:ce-doc-review` | `critical-design-review`, `critical-implementation-review`, `update-design-doc`, `update-implementation-plan` |
> | reviewing written code | `compound-engineering:ce-code-review` | `completion-review`, `superpowers:requesting-code-review` |
> | acting on review feedback | `compound-engineering:ce-resolve-pr-feedback` | `superpowers:receiving-code-review` |
> | session handoff | `compound-engineering:ce-handoff` | `create-handoff`, `resume-handoff` |
>
> Worktree provisioning and branch finishing are **not** substituted:
> `superpowers:using-git-worktrees` and `superpowers:finishing-a-development-branch`
> remain in force, because the inline protocol owns worktree naming, the issue-claim
> sequence, and the configured Merge Mode.

The **Skill-name matching** paragraph also notes the third tier.

The **Failure semantics** paragraph keeps its existing content verbatim; only its notice
sentence changes, to: a role covered by an installed `compound-engineering:*` substitute
does not count as missing, and notices are never emitted for compound-engineering or
personal toolkit skills.

The **Skills are advisory, not gating** and **Version trust** paragraphs are unchanged.
Version trust continues to apply: CE skills are matched by name, with no version pinning.

### 2. Worker manifest: manifest v1 → v2

Workers dispatched by `/fix-loop` and `/modernize` receive only the
`optional-skills-manifest` block, not the prelude, so CE would otherwise be invisible to
them. The manifest gains one sentence:

> Where a `compound-engineering:*` skill is listed, prefer it over any `superpowers:*` or
> bare-name skill covering the same role.

### 3. Per-command mapping edits

Only three mapping blocks change; all bump their own sentinel `v1` → `v2` and must stay
byte-identical between the `plugins/` and `.agent/workflows/` mirrors.

| Command | Change |
|---|---|
| `fix-loop` | Append to the per-worker candidate set: `compound-engineering:ce-brainstorm`, `ce-plan`, `ce-work`, `ce-debug`, `ce-code-review`, `ce-doc-review`, `ce-resolve-pr-feedback` |
| `modernize` | Append the same CE names to the code-producing-worker candidate set |
| `retro` | New row: capture durable learnings → `compound-engineering:ce-compound` (additive; no prior counterpart) |

`fix`, `plan`, `brainstorm-issue`, and `approve-proposal` are **unchanged** — the
precedence table covers their existing entries.

## Non-goals

- No CE skill is made required or gating. Everything stays advisory, per the existing
  "Skills are advisory, not gating" rule.
- No wiring of `ce-simplify-code`, `ce-babysit-pr`, `ce-test-browser`, `ce-optimize`,
  `ce-strategy`, `ce-ideate`, or `ce-pov`. They have no current role in these commands;
  adding them is a separate decision.
- No version pinning or capability detection beyond exact-name matching.

## Verification

- `bash scripts/check-optional-skills-drift.sh` passes both passes (boilerplate hash
  identical across all 16 files; per-command mappings identical across mirrors).
- `bash plugins/autocoder/scripts/regression-test.sh` passes.
- Behavior with CE absent is byte-for-byte the same protocol as today.

## Versioning

Per `CLAUDE.md`, bump the `autocoder` and `modernize` plugin versions **and** the root
marketplace version in `.claude-plugin/marketplace.json`.
