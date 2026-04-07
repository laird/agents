---
name: autocoder
description: Use this skill for autonomous GitHub issue resolution, issue triage, regression-test failure handling, proposal review, blocked-issue review, and continuous fix loops in repositories that use the autocoder workflow.
---

# Autocoder

Use this skill when the user wants Codex to operate the repo's autonomous issue-resolution workflow.

## Start Here

1. Read `AGENTS.md` first for repo rules.
2. Use the workflow order in [references/workflow-map.md](references/workflow-map.md).
3. Use [references/command-mapping.md](references/command-mapping.md) when translating legacy Claude plugin commands.
4. Prefer existing scripts over restating shell procedures.

## Operating Rules

- Prioritize: triage -> bugs -> regression failures -> approved enhancements -> proposals.
- Respect blocking labels: `needs-approval`, `needs-design`, `needs-clarification`, `too-complex`.
- Use `plugins/autocoder/scripts/regression-test.sh` for full regression runs when appropriate.
- Use `scripts/append-to-history.sh` to log significant work.
- Treat `AGENTS.md` as the primary configuration source; use `CLAUDE.md` only as legacy fallback.

## When To Read More

- For workflow sequencing: [references/workflow-map.md](references/workflow-map.md)
- For legacy command mapping: [references/command-mapping.md](references/command-mapping.md)
