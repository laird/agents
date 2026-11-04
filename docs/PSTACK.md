# pstack integration

[pstack](https://github.com/michael-denyer/pstack-claude) is an optional skill set that autocoder and modernize use when it is installed. Without it, both plugins behave exactly as before. It is not vendored into this repository; install it from its own source so it stays current with upstream.

## What the commands use it for

The rules live in the optional-skills prelude (`plugins/shared/optional-skills-prelude.md`, mirrored in `.agent/shared/`) and in each command's mapping table. When both pstack and another plugin cover a role, pstack wins. The order is pstack, then Compound Engineering, then superpowers, then personal toolkit skills.

| Role | pstack skill | Replaces |
|---|---|---|
| Reviewing written code | `interrogate` | `ce-code-review`, `superpowers:requesting-code-review` |

In unattended runs, `interrogate` takes its intent from the issue or plan and never asks the user.

The commands also use these pstack skills as extra steps. Each runs only where a command's mapping table names it.

| Skill | Where it runs |
|---|---|
| `tdd` | `/fix` Bug deliverables only, for the regression test. It is a bug-fix skill, not general test-first development. |
| `how` | `/fix` bugs and refactors when the affected code is unfamiliar, `/brainstorm-issue` when the issue touches an existing subsystem |
| `deslop` | `/fix` Branch deliverables, on `git diff $INTEGRATION_BRANCH...HEAD`, before verification so the verified code is the committed code |
| `blast-radius` | `/fix` Branch deliverables that change a contract other code depends on, `/approve-proposal`, `/modernize` phases that change public APIs. Always without arena, and with proof scripts written outside the working tree. |
| `unslop`, `technical-writing` | Text the command authors: `/fix` Document deliverables, `/brainstorm-issue` specs, `/plan`, `/retro`. Never existing files an issue merely edits. |

`/fix-loop` and `/modernize` pass the relevant pstack names to their workers in the optional-skills manifest.

## What the commands never use

The commands never enter `poteto-mode`, `architect`, `arena`, `swarm`, `figure-it-out`, `babysit`, or `make-pr-easy-to-review`, even when another pstack skill says to run one. Each runs its own playbook, dispatch loop, design bakeoff, or PR tail. That would bypass worktree naming, the issue-claim sequence, and the configured Merge Mode. `architect` in particular implements its winning design with no checkpoint. `why` is not used either. It fans out up to seven investigators, which costs too much for a per-issue step.

## The session-start hook

On Claude Code and Codex, the pstack plugin installs a session-start hook. It fires on startup, resume, clear, and after every compaction. It tells the agent to "Invoke the `pstack:poteto-mode` skill ... when a task touches more than one file". The hook says it defers to "User instructions (CLAUDE.md, AGENTS.md, direct requests)". Command protocols are none of those, so the prelude tells the agent to ignore the instruction each time it reappears. `/fix` repeats that in its compaction section.

On unattended worker hosts, a structural off switch is more reliable than a prompt override. Add this line to `~/.claude/pstack-models.md` (or the Codex home equivalent):

```
session hook: off
```

A line in the project's `CLAUDE.md` or `AGENTS.md` telling agents not to route through `poteto-mode` also works, because the hook defers to those files.

## Cost and models

`interrogate` and `how` run multi-model panels through subagents. By default, some panel slots use a model other than the session's. To keep workers on the parent model, run `/setup-pstack` and set those roles to `inherit-parent`. `tdd`, `deslop`, `unslop`, `technical-writing`, and `blast-radius` are single-agent skills.

## Install per platform

| Platform | Install | How skills are named |
|---|---|---|
| Claude Code | `/plugin marketplace add michael-denyer/pstack-claude`, then `/plugin install pstack@pstack-claude` | `pstack:<name>` |
| Codex | `codex plugin marketplace add michael-denyer/pstack-claude`, then `codex plugin add pstack@pstack-claude`. Trust the hook through `/hooks`. | `pstack:<name>` |
| Droid, Antigravity, Gemini CLI, pi | `npx skills add https://github.com/michael-denyer/pstack-claude/tree/main/plugins/pstack/skills --skill '*' --agent droid antigravity gemini-cli pi -g --yes` | bare `<name>` |

The skills CLI puts Droid, Antigravity, and Gemini CLI skills in `~/.agents/skills/` and pi skills in `~/.pi/agent/skills/`. Skills-only installs do not include the session-start hook.

A bare name counts as pstack only when bare `poteto-mode` is also installed. That marks a skills-only pstack install. Otherwise a bare `tdd` or `how` is treated as a personal toolkit skill and gets no pstack precedence.

On runtimes without subagents, the panel skills (`interrogate`, `how`) degrade to one reviewer. The single-agent skills work unchanged.

Install every skill directory, including the `principle-*` ones. The workflow skills load them by reference.

## Maintenance

`tests/test_optional_skills_semantics.sh` checks the pstack rules:

- Orchestrators never appear in the precedence table or any mapping block.
- `tdd` appears only on the `/fix` Bug row.
- `deslop` runs before verification.
- The session-start override, including the compaction case, is present.
- Worker dispatch lists use qualified names.
- `.pi/prompts` blocks match the plugin blocks.
- Every pstack skill a command names exists.

When pstack adds or renames a skill, update `PSTACK_SKILLS` in that test.
