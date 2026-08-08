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
  - `plugins/autocoder/scripts/start-parallel-agents.sh` (start a swarm; for cmux+Codex: `start-parallel-agents.sh N --mux cmux --agent codex`)
  - `plugins/autocoder/scripts/add-worker.sh` (add one worker to a running swarm)
  - `plugins/autocoder/scripts/worker-health.sh` (report worker RSS + stall; flags UNHEALTHY = stalled AND high memory)
  - `plugins/autocoder/scripts/restart-worker.sh` (restart a wedged worker in place on the same worktree/issue)
  - `plugins/autocoder/scripts/fetch-blocked-issues.sh`
  - `plugins/autocoder/scripts/approve-blocked-issue.sh`
  - `plugins/autocoder/scripts/reject-blocked-issue.sh`

## Dispatch vs. Self-Select

**When a manager dispatches you to a specific issue, always invoke `/fix <N>` with that exact number.** Running `/fix` without a number self-selects the highest-priority unclaimed issue — that bypasses the manager's assignment and causes workers to collide on the same files or pick up issues already in-flight by peers.

Only self-select (run `/fix` with no number) when you are genuinely idle and have received no explicit assignment.

## Lock Hierarchy

A claim on issue `N` is signalled in three layers, in increasing strength:

1. `working` label on the GitHub issue — weakest; the manager clears it automatically only after confirming no live agent, dirty matching worktree, recent local/remote branch-tip commit, or recent issue/comment update. Missing evidence fails closed and retains the label.
2. `Automated Fix Started` comment on the issue with the branch name — durable, but posted after branch creation.
3. **Remote branch `feature/issue-N` on `origin`** — strongest lock; exists as soon as the worker pushes. Before attempting to claim any issue (both in explicit and self-select paths), check `git ls-remote --heads origin feature/issue-N`. A non-empty result means the issue is owned; skip it.

If the remote branch exists but the `working` label and start comment are absent (e.g. manager cleared a stale label), the branch is still the authoritative lock. The manager reports an old remaining branch as a takeover blocker and must not delete it automatically.

## Execution Notes

- Keep GitHub issue state as the source of truth.
- Before editing files for issue `N`, run `plugins/autocoder/scripts/start-issue-work.sh N` from the shared agents repo or installed plugin path. This claims the issue, switches to `feature/issue-N`, and posts the `Implementation Started` marker that peer workers use to validate the lock.
- If the issue-start helper fails, do not work that issue; select another claimable issue or report idle.
- When an issue's work is committed and tests pass, land it on the shared integration branch with `plugins/autocoder/scripts/merge-to-integration.sh`. Auto-detect the branch first: `INTEGRATION_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'); INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-main}"`. Then: `plugins/autocoder/scripts/merge-to-integration.sh --feature feature/issue-N --issue N --integration "$INTEGRATION_BRANCH" --test-cmd "<repo test command>"`. After a successful merge, delete the local feature branch: `git branch -d feature/issue-N 2>/dev/null || git branch -D feature/issue-N 2>/dev/null || true`. It is worktree-safe (never checks out the integration branch locally), re-runs tests on the combined tree, and pushes with retry. **Never** merge into or push the per-worktree `main-wt-N` branch — that strands work off the integration branch and fragments the swarm's output.
- Prefer existing repo scripts for automation-heavy steps.
- When acting as the manager of a swarm, periodically run `worker-health.sh`; for any worker it reports as UNHEALTHY (stalled AND high memory), run `restart-worker.sh --worktree <path> --agent codex` to recover it in place.
- Translate Claude slash commands into direct actions instead of preserving slash syntax.
- Continuous loops should be implemented with shell/session control, not Claude hooks.
- Do not depend on `agents/`; that tree is reserved for the OpenCode platform (see `agents/README.md`).
