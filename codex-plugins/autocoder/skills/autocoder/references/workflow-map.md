# Workflow Map

## Core Sequence

1. Triage unprioritized issues and assign `P0` to `P3`.
2. Fix open bugs in priority order.
3. Run regression tests when no prioritized bugs remain.
4. Create or fix issues from regression failures.
5. Implement approved enhancements only.
6. Propose improvements only when no higher-priority work exists.

## Reusable Source Material

- Planning pipeline (goal → design doc → story issues): `plugins/autocoder/commands/plan.md`
- Primary protocol: `plugins/autocoder/commands/dev.md`
- Continuous loop behavior: `plugins/autocoder/commands/dev-loop.md`
- Manager review protocol: `plugins/autocoder/commands/monitor-workers.md`
- Continuous manager loop: `plugins/autocoder/commands/monitor-loop.md`
- Help and command inventory: `plugins/autocoder/commands/autocoder-help.md`
- Automation scripts:
  - `plugins/autocoder/scripts/regression-test.sh`
  - `plugins/autocoder/scripts/start-parallel-agents.sh` (start a swarm; for cmux+Codex: `start-parallel-agents.sh N --mux cmux --agent codex`)
  - `plugins/autocoder/scripts/add-worker.sh` (add one worker to a running swarm)
  - `plugins/autocoder/scripts/worker-health.sh` (report worker RSS + stall; flags UNHEALTHY = stalled AND high memory)
  - `plugins/autocoder/scripts/restart-worker.sh` (restart a wedged worker in place on the same worktree/issue)
  - `plugins/autocoder/scripts/fetch-blocked-issues.sh`
  - `plugins/autocoder/scripts/approve-blocked-issue.sh`
  - `plugins/autocoder/scripts/reject-blocked-issue.sh`

## Execution Notes

- Keep GitHub issue state as the source of truth.
- Prefer existing repo scripts for automation-heavy steps.
- Translate Claude slash commands into direct actions instead of preserving slash syntax.
- Continuous loops should be implemented with shell/session control, not Claude hooks.
- When acting as the manager of a swarm, periodically run `worker-health.sh`; for any worker it reports as UNHEALTHY (stalled AND high memory), run `restart-worker.sh --worktree <path> --agent codex` to recover it in place.
- Do not depend on `agents/`; that tree is reserved for Antigravity / Gemini.
