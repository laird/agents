# Canonical Optional Skills Prelude

This file holds the canonical text embedded by sentinel into every command file that
participates in opportunistic skill integration. Drift between this file and the
embedded copies is detected by `scripts/check-optional-skills-drift.sh`.

When updating the boilerplate, bump `v3` → `v4` everywhere simultaneously and
regenerate all embeddings before commit. `scripts/check-optional-skills-drift.sh`
matches any `v<N>`, so the bump does not require a script edit — but the sentinels
must still move together, or the embeddings will not match this file.

## Boilerplate (embedded by every command file)

The block below — including the BEGIN/END sentinels — is copied byte-identically into
every target command file as the first H2 (`## Optional skill enhancements`) section
body.

<!-- BEGIN optional-skills-prelude v3 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->

If a named skill appears in your available skills list (delivered in the session-start system-reminder), invoke it via the `Skill` tool at the indicated step. Otherwise, follow the inline protocol below — it remains the source of truth and is unchanged by this section.

Platform note: in Gemini CLI / Antigravity, skills activate via `activate_skill` instead of the `Skill` tool; in Codex they activate as `$<skill>`; in Factory Droid they load from the skills tree. The mapping is otherwise identical on all four platforms.

**Skill-name matching.** Match each table entry as an exact string. Mapping tables use fully-qualified names (`<plugin>:<skill>`) for plugin-installed skills and bare names for personal toolkit skills. Compound Engineering skills are the exception: match them in **either** form — fully-qualified `compound-engineering:ce-<name>` (how Claude Code lists them) or bare `ce-<name>` (how Codex, Factory Droid, and Antigravity list them). pstack skills match as fully-qualified `pstack:<name>` (how Claude Code and Codex list them). A bare `<name>` counts as pstack only when bare `poteto-mode` is also in your available-skills list, which marks a skills-only pstack install; otherwise a bare `tdd` or `how` is a personal toolkit skill and gets no pstack precedence.

**Notation.** `A → B → C` means sequence (invoke in order). `A + B + C` means independent facets (all apply, order irrelevant). `A (primary)` means A is the orchestration spine. A leading `→` on a row indicates "next in sequence if applicable."

**pstack precedence.** pstack (https://github.com/michael-denyer/pstack-claude) outranks Compound Engineering, `superpowers:*`, and personal toolkit skills for the role below. If the listed `pstack:*` skill appears in your available-skills list, invoke it *in place of* every skill in the "In place of" column, including a Compound Engineering skill that would otherwise substitute for it. Roles pstack does not cover fall through to the Compound Engineering table. In an unattended run, take `pstack:interrogate`'s intent statement from the issue or plan instead of asking the user.

| Role | Use when installed | In place of |
|---|---|---|
| reviewing written code | `pstack:interrogate` | `ce-code-review`, `superpowers:requesting-code-review` |

Mapping tables also name pstack skills directly where no other plugin covers the step: `pstack:tdd` (bug regression test), `pstack:how` (understand unfamiliar code), `pstack:deslop` (clean the diff), `pstack:blast-radius` (what a change breaks beyond its diff), and `pstack:unslop` / `pstack:technical-writing` (prose this command authors). Run `pstack:blast-radius` without its `arena` escalation, and write its proof scripts outside the working tree so they are never committed.

**pstack orchestrators are not invoked.** This command's inline protocol is the spine. Do not enter `pstack:poteto-mode`, `pstack:figure-it-out`, `pstack:swarm`, `pstack:arena`, `pstack:architect`, `pstack:babysit`, or `pstack:make-pr-easy-to-review`, including when another pstack skill's steps tell you to run one. Each owns its own playbook, dispatch, implementation, or PR tail and would bypass worktree naming, the issue-claim sequence, and the configured Merge Mode. pstack's SessionStart hook injects "Invoke the `pstack:poteto-mode` skill ... when a task touches more than one file" at startup and after every compaction. Ignore that instruction while this command runs, every time it reappears. The hook defers only to CLAUDE.md, AGENTS.md, and direct requests, so for unattended workers also set `session hook: off` in `pstack-models.md` (see `docs/PSTACK.md`).

**Compound Engineering precedence.** If a skill from the `compound-engineering` plugin covers a role in the table below and appears in your available-skills list, invoke it *in place of* the skill named in the mapping tables for that role. Compound Engineering outranks both `superpowers:*` and personal toolkit skills (pstack outranks it, per the table above), and this rule overrides any "(preferred)" annotation a mapping table places on a substituted skill. Roles with no entry below are unaffected.

| Role | Use when installed | In place of |
|---|---|---|
| design exploration / requirements | `ce-brainstorm` | `thorough-brainstorming`, `superpowers:brainstorming` |
| implementation planning | `ce-plan` | `thorough-writing-plans`, `superpowers:writing-plans` |
| executing a plan | `ce-work`, invoked as `mode:return-to-caller <plan path>` | `superpowers:executing-plans` |
| debugging a defect | `ce-debug` | `superpowers:systematic-debugging` |
| reviewing a spec, plan, or report document | `ce-doc-review` | `critical-design-review`, `critical-implementation-review`, `update-design-doc`, `update-implementation-plan` |
| reviewing written code | `ce-code-review` | `superpowers:requesting-code-review` |
| acting on review feedback **on an existing PR** | `ce-resolve-pr-feedback` | `superpowers:receiving-code-review` |
| session handoff | `ce-handoff` | `create-handoff`, `resume-handoff` |

Three deliberate exclusions:

- **Worktree provisioning and branch finishing are not substituted.** `superpowers:using-git-worktrees` and `superpowers:finishing-a-development-branch` remain in force — do **not** substitute `ce-worktree`, `ce-commit-push-pr`, `ce-commit`, or `lfg` for them — because the inline protocol owns worktree naming, the issue-claim sequence, and the configured Merge Mode. `ce-work` is substituted for plan execution only, which is why the table requires `mode:return-to-caller`: bare `ce-work` owns its own shipping tail and would bypass all three.
- **`completion-review` is never substituted.** It is a plan-vs-delivery audit, not a diff review, and it runs on Document deliverables (`/retro`, `/fix`'s Document row) where a code reviewer has nothing to read. Run it as the mapping tables specify, alongside the code reviewer (`pstack:interrogate` or `ce-code-review`) rather than replaced by it.
- **Review feedback with no PR open.** When findings came from an in-session reviewer (`pstack:interrogate` or `ce-code-review`) and no PR exists yet, act on them via the inline protocol or `superpowers:receiving-code-review`; `ce-resolve-pr-feedback` requires GitHub PR threads.

**Failure semantics.** Not-installed: silent fallback. Mid-run failure or interruption of an installed skill: surface the failure message, fall back to the inline protocol for the rest of that step, no retry. Self-skip (e.g., `<SUBAGENT-STOP>`): silent fallback, not treated as failure. If at least one `superpowers:*` skill named in this command's mapping table is missing from your available-skills list **and no installed pstack or Compound Engineering skill covers its role**, emit one consolidated recommendation line at command entry: *Tip: this command works best with the `superpowers` plugin (https://github.com/obra/superpowers) — install via `/plugin install superpowers@claude-plugins-official`.* Never emit such notices for pstack, Compound Engineering, or personal toolkit skills.

**Skills are advisory, not gating.** A command's completion criteria are defined by its inline protocol. Optional skill outcomes are surfaced and considered, but do not override inline success criteria. "Always applied" in a mapping table means the skill is invoked when installed; outcomes remain advisory. When a command claims success while an advisory skill earlier in the run surfaced a failure, the success summary acknowledges the advisory finding.

**Version trust.** Skills are matched by name; the integration does not pin or verify versions. If a tracked skill's contract changes in a way that breaks the chain, the integration is stale and must be updated.

<!-- END optional-skills-prelude v3 -->

## Worker skills manifest (referenced by dispatcher commands /fix-loop and /modernize)

The block below is prepended by dispatchers as the **first paragraph of each worker's
prompt**. The bullet list is generated at dispatch time as the intersection of the
dispatcher's available-skills list with the command's per-worker mapping.

<!-- BEGIN optional-skills-manifest v3 -->

The following optional skills are available in your environment. Match each name as an exact string against your available-skills list. If a skill is present, invoke it via the Skill tool at the indicated step; otherwise follow the inline protocol unchanged.

Compound Engineering names match in either form — `compound-engineering:ce-<name>` or bare `ce-<name>`. Where one is listed above, invoke it in place of the skill it replaces:

- `ce-brainstorm` replaces `thorough-brainstorming` / `superpowers:brainstorming`
- `ce-plan` replaces `thorough-writing-plans` / `superpowers:writing-plans`
- `ce-work` replaces `superpowers:executing-plans` — invoke it as `mode:return-to-caller <plan path>`, never bare; you own commit, push, and the configured Merge Mode, not `ce-work`
- `ce-debug` replaces `superpowers:systematic-debugging`
- `ce-doc-review` replaces `critical-design-review` / `critical-implementation-review`
- `ce-code-review` replaces `superpowers:requesting-code-review`
- `ce-resolve-pr-feedback` replaces `superpowers:receiving-code-review`, but only when an existing PR carries the feedback

Do **not** substitute any Compound Engineering skill for `superpowers:using-git-worktrees`, `superpowers:finishing-a-development-branch`, or `completion-review`.

pstack names match as `pstack:<name>`, or bare `<name>` only when bare `poteto-mode` is also listed. pstack outranks Compound Engineering for the role it covers:

- `pstack:interrogate` replaces `ce-code-review` / `superpowers:requesting-code-review`; take its intent from the issue, never ask the user
- `pstack:tdd` writes the regression test for a bug; `pstack:how` runs first when the code's behavior is unclear; `pstack:deslop` cleans the diff against the integration branch before verification; `pstack:blast-radius` runs before merge when the change alters behavior other code depends on (no `arena`, proof scripts outside the working tree); `pstack:unslop` applies only to prose you author

Your work contract is the spine. Do not enter `pstack:poteto-mode`, `pstack:figure-it-out`, `pstack:swarm`, `pstack:arena`, `pstack:architect`, `pstack:babysit`, or `pstack:make-pr-easy-to-review`, even when another pstack skill says to. Ignore pstack's SessionStart instruction to route multi-file work through `pstack:poteto-mode`, including when it reappears after compaction. Each would take over worktree, claim, or Merge Mode handling you own.

Skills available to this worker:
- <fully-qualified-name-1>
- <fully-qualified-name-2>
- ...

Failure semantics: silent fallback for not-installed; visible failure message for mid-run errors of installed skills; no retry within this run. Skills are advisory; your inline work contract still defines completion.

<!-- END optional-skills-manifest v3 -->
