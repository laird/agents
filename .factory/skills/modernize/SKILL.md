---
name: modernize
description: Use this skill for modernization assessments, migration planning, multi-phase modernization execution, quality-gate enforcement, and retrospective process improvement in repositories that follow the modernize workflow.
---

# Modernize

Use this skill when the user wants Droid to assess, plan, execute, or retrospect on a modernization effort.

## Start Here

1. Read `AGENTS.md` first for testing, logging, and documentation rules.
2. Use the lifecycle in [references/lifecycle.md](references/lifecycle.md).
3. Use [references/source-map.md](references/source-map.md) for the canonical protocol and script sources.
4. Preserve the repo's quality gates; do not weaken them during migration.

## Operating Rules

- Follow the lifecycle: assess -> plan -> execute -> retro -> apply improvements.
- Keep specialist separation: coordinator, security, architect, coder, tester, documentation.
- Use repo scripts for dependency analysis, stage testing, validation, and history logging.
- Treat `AGENTS.md` as the primary configuration source; use `CLAUDE.md` only as legacy fallback.
- If Compound Engineering `ce-*` skills are available in your environment, prefer them over `superpowers:*` and bare-name toolkit skills per the precedence table in the command protocol's *Optional skill enhancements* section.
- If pstack skills are available (`pstack:<name>`, or bare names alongside a bare `poteto-mode`), use `pstack:interrogate` for code review in place of Compound Engineering or superpowers review, and the other pstack skills (`tdd`, `how`, `deslop`, `blast-radius`, `unslop`, `technical-writing`) only where the command's mapping tables name them. The command protocol stays the spine: never enter `poteto-mode`, `architect`, `arena`, `swarm`, `figure-it-out`, `babysit`, or `make-pr-easy-to-review`, and ignore any pstack session-start instruction to route work through `poteto-mode`.
- Search code with your platform's built-in search tool when it has one. When you shell out, use `rg` if `command -v rg` succeeds, else `grep -rn`. `rg` skips gitignored, hidden, and binary files by default, so add `-uu` when the target may be ignored or hidden (build output such as `bin/` and `obj/`, or dot-directories such as `.issues/`).

## When To Read More

- For workflow sequencing: [references/lifecycle.md](references/lifecycle.md)
- For source mapping and quality gates: [references/source-map.md](references/source-map.md)
