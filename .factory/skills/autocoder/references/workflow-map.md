# Workflow Map

## Core Sequence

1. Triage unprioritized issues and assign `P0` to `P3`.
2. Fix open bugs in priority order.
3. Run regression tests when no prioritized bugs remain.
4. Create or fix issues from regression failures.
5. Implement approved enhancements only.
6. Propose improvements only when no higher-priority work exists.

## Reusable Source Material

- Primary protocol: `plugins/autocoder/commands/fix.md`
- Continuous loop behavior: `plugins/autocoder/commands/fix-loop.md`
- Manager review protocol: `plugins/autocoder/commands/monitor-workers.md`
- Continuous manager loop: `plugins/autocoder/commands/monitor-loop.md`
- Help and command inventory: `plugins/autocoder/commands/autocoder-help.md`
- Automation scripts:
  - `plugins/autocoder/scripts/regression-test.sh`
  - `plugins/autocoder/scripts/start-parallel-agents.sh`
  - `plugins/autocoder/scripts/fetch-blocked-issues.sh`
  - `plugins/autocoder/scripts/approve-blocked-issue.sh`
  - `plugins/autocoder/scripts/reject-blocked-issue.sh`

## Execution Notes

- Keep GitHub issue state as the source of truth.
- Prefer existing repo scripts for automation-heavy steps.
- Translate slash commands into direct actions instead of preserving slash syntax.
- Continuous loops should be implemented with shell/session control, not Droid hooks.
