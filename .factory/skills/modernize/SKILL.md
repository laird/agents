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

## When To Read More

- For workflow sequencing: [references/lifecycle.md](references/lifecycle.md)
- For source mapping and quality gates: [references/source-map.md](references/source-map.md)
