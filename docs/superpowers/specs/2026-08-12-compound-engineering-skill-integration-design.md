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
5. **All four supported agent platforms are covered.** The CE plugin ships to Claude
   Code, Codex (App & CLI), Factory Droid, and Antigravity CLI — the same four platforms
   this repo targets. CE skill names are bare `ce-*` on every platform; Claude Code
   additionally exposes them fully qualified as `compound-engineering:ce-*`. Matching
   therefore accepts **either form**, and the `ce-` prefix keeps that unambiguous.

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
> CE skills are named `ce-*` on every platform. Match **either** the fully-qualified
> `compound-engineering:ce-<name>` (how Claude Code lists them) **or** the bare
> `ce-<name>` (how Codex, Factory Droid, and Antigravity list them).
>
> | Role | Use when installed | In place of |
> |---|---|---|
> | design exploration / requirements | `ce-brainstorm` | `thorough-brainstorming`, `superpowers:brainstorming` |
> | implementation planning | `ce-plan` | `thorough-writing-plans`, `superpowers:writing-plans` |
> | executing a plan | `ce-work` | `superpowers:executing-plans` |
> | debugging a defect | `ce-debug` | `superpowers:systematic-debugging` |
> | reviewing a spec or plan document | `ce-doc-review` | `critical-design-review`, `critical-implementation-review`, `update-design-doc`, `update-implementation-plan` |
> | reviewing written code | `ce-code-review` | `completion-review`, `superpowers:requesting-code-review` |
> | acting on review feedback | `ce-resolve-pr-feedback` | `superpowers:receiving-code-review` |
> | session handoff | `ce-handoff` | `create-handoff`, `resume-handoff` |
>
> Worktree provisioning and branch finishing are **not** substituted:
> `superpowers:using-git-worktrees` and `superpowers:finishing-a-development-branch`
> remain in force, because the inline protocol owns worktree naming, the issue-claim
> sequence, and the configured Merge Mode.

The **Skill-name matching** paragraph also notes the third tier and the dual (qualified /
bare) form of CE names.

The platform line — today *"In Gemini CLI / Antigravity, skills activate via
`activate_skill` instead of the `Skill` tool"* — extends to name Codex (`$<skill>`) and
Factory Droid alongside it, so all four supported platforms are covered explicitly.

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
| `fix-loop` | Append to the per-worker candidate set: `ce-brainstorm`, `ce-plan`, `ce-work`, `ce-debug`, `ce-code-review`, `ce-doc-review`, `ce-resolve-pr-feedback` |
| `modernize` | Append the same CE names to the code-producing-worker candidate set |
| `retro` | New row: capture durable learnings → `ce-compound` (additive; no prior counterpart) |

CE names are written bare in these lists; the precedence rule already states that both the
bare and fully-qualified forms match.

`fix`, `plan`, `brainstorm-issue`, and `approve-proposal` are **unchanged** — the
precedence table covers their existing entries.

### 4. Codex, Droid, and Antigravity reach

- **Antigravity** already has full parity: `.agent/workflows/*.md` and
  `.agent/shared/optional-skills-prelude.md` are mirrors covered by sections 1–3 and
  guarded by the drift script.
- **Codex and Factory Droid** consume the same protocol indirectly: their skill trees
  (`codex-plugins/*/skills/`, `.factory/skills/`) are routers whose
  `references/workflow-map.md` names `plugins/autocoder/commands/fix.md` as the primary
  protocol. They therefore inherit the precedence rule with no new prelude copies.
- To make it hard to miss for agents that read `SKILL.md` first, both
  `skills/autocoder/SKILL.md` and `skills/modernize/SKILL.md` gain one Operating Rule:
  *If compound-engineering `ce-*` skills are available in your environment, prefer them
  over `superpowers:*` and bare-name toolkit skills per the precedence table in the
  command protocol.*
- Per the packaging rule in `CLAUDE.md`, `skills/` is the source of truth and each edited
  `SKILL.md` is copied byte-identically into `plugins/autocoder/skills/autocoder/`,
  `plugins/modernize/skills/modernize/`, `codex-plugins/autocoder/skills/autocoder/`,
  `codex-plugins/modernize/skills/modernize/`, `.factory/skills/autocoder/`, and
  `.factory/skills/modernize/`.

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
- `bash tests/test_skill_packaging.sh` passes (SKILL.md mirrors byte-identical).
- `bash plugins/autocoder/scripts/regression-test.sh` passes.
- Behavior with CE absent is byte-for-byte the same protocol as today.

## Versioning

Per `CLAUDE.md`, bump the `autocoder` and `modernize` plugin versions **and** the root
marketplace version in `.claude-plugin/marketplace.json`.
