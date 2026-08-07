---
name: autocoder
description: Use this skill for autonomous GitHub issue resolution, issue triage, regression-test failure handling, proposal review, blocked-issue review, worker monitoring, and continuous fix loops in repositories that use the autocoder workflow.
---

# Autocoder

Use this skill when the user wants Droid to operate the repo's autonomous issue-resolution or worker-coordination workflow.

## Start Here

1. Read `AGENTS.md` first for repo rules.
2. Use the workflow order in [references/workflow-map.md](references/workflow-map.md).
3. Use [references/command-mapping.md](references/command-mapping.md) when translating legacy Claude plugin commands.
4. Prefer existing scripts over restating shell procedures.

## Operating Rules

- **CONTEXT COMPACTION IS MANDATORY (NON-NEGOTIABLE).** Before starting work on ANY new issue in a fix loop, you MUST clear/compact the session context (the Droid equivalent of Claude's `/compact`). Every issue, every time, no exceptions. Each issue starts from a fresh, compacted context; never carry over detailed investigation notes from a previous issue. Skipping this WILL exhaust the context window and crash the worker mid-issue. See "Context Management (MANDATORY)" in `plugins/autocoder/commands/fix.md`.
- Prioritize: triage -> bugs -> regression failures -> approved enhancements -> proposals.
- Respect blocking labels: `needs-approval`, `needs-design`, `needs-clarification`, `too-complex`.
- Use `plugins/autocoder/scripts/regression-test.sh` for full regression runs when appropriate.
- Use `scripts/append-to-history.sh` to log significant work.
- Treat `AGENTS.md` as the primary configuration source; use `CLAUDE.md` only as legacy fallback.

## When To Read More

- For workflow sequencing: [references/workflow-map.md](references/workflow-map.md)
- For legacy command mapping: [references/command-mapping.md](references/command-mapping.md)
