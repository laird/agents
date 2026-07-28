# Project History

This file tracks all significant changes, migrations, and decisions.


---

## 2025-12-10 10:11:09 - Init

**What Changed**: Created script

**Why Changed**: Verification

**Impact**: Enabled logging


---

## 2026-04-16 08:22:40 - Autocoder regression pass

**What Changed**: Ran plugins/autocoder/scripts/regression-test.sh, verified the reported pass was false, logged the regression pass, and attempted to open a GitHub bug for the broken regression workflow.

**Why Changed**: The live issue queue was empty, so the next required autocoder step was regression testing. The script failed on this repo's missing test config and macOS grep incompatibility.

**Impact**: Recorded the regression report path for reproduction and identified a P1 workflow bug, but automatic issue creation was blocked by GitHub Enterprise Managed User authorization.

---

## 2026-04-16 08:24:23 - Autocoder single-pass queue check

**What Changed**: Read AGENTS.md and autocoder workflow docs, confirmed there are no open or blocked GitHub issues, ran plugins/autocoder/scripts/regression-test.sh, and captured the false-positive success conditions from the script output and report.

**Why Changed**: The requested one-pass autocoder flow required checking the live queue first, then moving to regression testing because no actionable issue existed.

**Impact**: Validated that the repo currently has no queued work, but the regression harness is not trustworthy in this environment because it treats missing package/test execution and BSD grep failures as a passing run.
## 2026-03-16 13:26:14 - Add Codex skill migration plan

**What Changed**: Added a Codex-only migration plan and initial skills/autocoder and skills/modernize scaffolds.

**Why Changed**: Needed an additive Codex path that preserves Claude Code plugins and Antigravity/Gemini agents without reuse or breakage.

**Impact**: Repo now has a concrete, non-breaking starting point for Codex support.


---

## 2026-04-16 09:11:17 - Fix regression runner false-green failures

**What Changed**: Updated plugins/autocoder/scripts/regression-test.sh to preserve test command exit codes, remove grep -P parsing, handle missing matches safely, and honor CLAUDE unit-test commands without requiring a working-directory override.

**Why Changed**: The autocoder workflow was reporting successful regressions even when unit and E2E commands failed on this macOS workspace, which breaks the queue's quality gate.

**Impact**: Regression runs now fail correctly, produce reports without BSD grep errors, and complete their summaries on failing paths.
## 2026-03-16 13:33:41 - Add Codex runtime support

**What Changed**: Added Codex-only loop, monitor, stop, and tmux swarm scripts plus Codex integration docs and README updates.

**Why Changed**: Codex lacks Claude Code's built-in loop runtime, so repo-specific shell wrappers were needed to make fix-loop and monitor-loop usable without touching existing Claude or Gemini paths.

**Impact**: The repo now has an additive Codex workflow with one-shot runs, continuous loops, worker monitoring, and tmux-based swarm startup.


---

## 2026-04-16 09:16:05 - Harden regression failure handling

**What Changed**: Updated plugins/autocoder/scripts/regression-test.sh to record command/setup failures in the report, skip missing labels when filing issues, and treat GitHub issue creation auth failures as non-fatal.

**Why Changed**: The regression workflow was aborting on missing labels and Enterprise Managed User issue-creation limits, and it obscured command failures as 0/0 test runs.

**Impact**: Regression passes now finish with actionable reports and clear warnings instead of crashing mid-run.
## 2026-03-16 14:00:58 - Add Codex installer script

**What Changed**: Added scripts/install-codex.sh plus Codex install docs so shared skills, parallel-agent symlinks, and alias sourcing can be installed from the agents repo into a target project.

**Why Changed**: Codex support had runtime scripts and alias snippets but no standalone installer, which left start-parallel unavailable in downstream repos using the shared agents checkout.

**Impact**: Codex users can now run one installer command from the shared repo, reload their shell, and start cmux or tmux worker swarms in project repos without manual symlink setup.


---

## 2026-04-16 09:21:05 - Make regression failure summaries truthful

**What Changed**: Updated plugins/autocoder/scripts/regression-test.sh so per-suite and final summaries display FAILED in red when the command exits non-zero before any tests are counted; verified with bash -n and a focused output assertion while the full regression harness still reports the existing npm/package setup failures.

**Why Changed**: The autocoder single-pass workflow hit regression command failures with an empty queue, and the runner still emitted green 0/0 passed summaries that understated the failure severity.

**Impact**: Autocoder operators now get unambiguous failure-path output during regression runs, reducing the chance of treating broken test commands as healthy suites.
## 2026-03-16 14:45:41 - Install Codex Runtime Wrappers

**What Changed**: Updated install-codex.sh to symlink repo-local codex runtime wrappers into target repos and documented the behavior in Codex install docs.

**Why Changed**: Target repos like nextgen-CDD expected shared Codex loop scripts, but the installer only linked skills and aliases, causing bash scripts/codex-fix-loop.sh and bash scripts/codex-manage-workers-loop.sh to fail with missing-file errors.

**Impact**: Running the installer now makes worker and manager loop entrypoints available from the target repo and its git worktrees, matching AGENTS.md expectations.


---

## 2026-04-16 09:23:11 - Autocoder single-pass regression triage

**What Changed**: Read AGENTS.md and autocoder workflow references, checked the open GitHub issue queue, ran plugins/autocoder/scripts/regression-test.sh, and captured the generated regression report.

**Why Changed**: The repo had no open actionable issues, so the workflow advanced to regression testing for one pass.

**Impact**: Identified two blockers: default test commands fail at repo root because no package.json is present there, and GitHub issue creation failed due Enterprise Managed User authorization limits. Report saved under docs/test/regression-reports/.
## 2026-03-16 14:47:44 - Make startcc Work In Fresh Worktrees

**What Changed**: Updated Codex loop scripts to resolve sibling helpers from the shared agents repo, and changed the shared parallel launcher to invoke Codex worker and manager loops via absolute shared-script paths. Clarified install docs to match the new behavior.

**Why Changed**: Codex startcc/startct launched fresh git worktrees that did not contain repo-local codex wrapper files, so worker and manager startup failed even after install. The loop scripts also hardcoded helper lookups through REPO_ROOT/scripts, which broke shared-script execution.

**Impact**: Codex swarm startup now works from installed repos because startcc/startct no longer depend on per-worktree wrapper files, while manual repo-local loop commands still work through the installed target-repo symlinks.


---

## 2026-04-16 09:39:48 - Autocoder one-pass regression check

**What Changed**: Ran the autocoder workflow in priority order, found no open GitHub issues, executed the full regression script, and captured environment/configuration failures before any tests ran.

**Why Changed**: The repository had no actionable queue items, so the workflow advanced to regression validation as required.

**Impact**: Generated a regression report showing missing local test configuration and npm cache permission blockers; no code changes were made in this pass.
## 2026-03-16 14:50:46 - Fix start-parallel Symlink Path Resolution

**What Changed**: Updated the shared parallel launcher to resolve its real script path before deriving the agents repo root, preventing Codex worker and manager commands from collapsing to /Users/scripts when invoked through ~/.local/bin symlinks.

**Why Changed**: The startcc alias launches the shared start-parallel command from a symlink in ~/.local/bin. Computing relative paths from the symlink location produced an invalid shared runtime path for Codex loops.

**Impact**: Codex startcc/startct now derive absolute runtime script paths from the real agents checkout, so fresh workspaces get valid worker and manager commands.


---

## 2026-04-16 09:57:43 - Autocoder regression skip handling

**What Changed**: Updated plugins/autocoder/scripts/regression-test.sh to skip Node-based unit and E2E commands when the configured working directory has no package.json, and to report skip reasons in the regression report.

**Why Changed**: The single-pass autocoder run found false regression failures in a protocol-only repo with no runnable Node test project at the root.

**Impact**: Regression runs now complete without creating bogus command-failure bugs for missing test infrastructure.
## 2026-03-16 14:53:25 - Harden Codex Prompt Construction

**What Changed**: Replaced heredoc-based prompt assembly in codex-autocoder.sh with printf-based builders and verified the shared runtime script still parses and prints usage correctly from a target repo.

**Why Changed**: The shared Codex fix loop reached codex-autocoder.sh successfully, but prompt assembly was failing at runtime with a bash command-substitution parse error in worker worktrees.

**Impact**: Codex fix-loop startup now gets past prompt construction reliably when invoked from the shared agents runtime and installed target-repo wrappers.


---

## 2026-03-16 14:57:57 - Add Dedicated startcc/startct Wrapper

**What Changed**: Added codex-start-parallel.sh as a Codex-specific launcher wrapper, rewired startcc/startct aliases to use it, updated the installer to install the new command, and refreshed Codex install docs.

**Why Changed**: Codex swarm startup was still routed through a generic start-parallel alias path, which made debugging and path resolution more brittle than necessary for the shared-runtime setup.

**Impact**: startcc and startct now enter the shared Codex launcher through a stable dedicated command, while retaining the generic parallel-agent infrastructure underneath.


---

## 2026-03-16 15:12:11 - Add Commit And Push To Codex Fix Pass

**What Changed**: Updated the Codex autocoder fix prompt to require a commit after successful tests and to push the resulting branch when repo rules allow it. Documented the behavior in the Codex docs.

**Why Changed**: The worker loop previously stopped after tests and summary, which left completed units of work uncommitted and unpushed unless the agent decided to do it on its own.

**Impact**: Successful Codex fix passes now explicitly carry work through commit and push, aligning the automation with the expected branch workflow.


---

## 2026-03-17 09:46:51 - Add Automatic Codex Worker Dispatch

**What Changed**: Updated the Codex manager and worker loops to coordinate through worktree-local dispatch/status files. The manager now assigns dispatchable issues to idle worker worktrees, and idle workers wake early to run assigned issues before resuming the general loop. Documented the new behavior in the Codex docs.

**Why Changed**: Codex worker coordination previously depended on each worker polling for the next issue on its own, and the manager explicitly reported that no automatic dispatch existed. That made the Codex swarm slower and clunkier than the established autocoder flow.

**Impact**: Codex manager sessions now perform real worker dispatch without tmux/cmux keystroke hacks, making idle recovery faster and the overall swarm workflow smoother and more efficient.


---

## 2026-03-31 15:15:58 - Align Gemini/OpenCode docs with actual workflow support

**What Changed**: Updated OpenCode autocoder docs and metadata to match the workflows present, removed the broken sre-monitor reference from agents/autocoder/agent.md, and refreshed Antigravity workflow docs to reflect the current .agent command set.

**Why Changed**: The Gemini-facing docs had drifted from the implemented workflow surface, which made support status ambiguous and left at least one broken workflow reference in place.

**Impact**: Gemini support is now documented more accurately: OpenCode is described as the core autocoder subset, while Antigravity docs better match the workflows that actually exist in the repo.


---

## 2026-03-31 15:19:13 - Add Gemini manager-loop parity for parallel swarms

**What Changed**: Added Antigravity monitor-workers and monitor-loop workflows, updated Gemini parity mappings and Antigravity docs, and changed the shared parallel launchers to start Gemini manager sessions with /monitor-loop instead of only /review-blocked.

**Why Changed**: Gemini swarm support lagged behind Claude on manager-session behavior, which left parallel Gemini sessions without the documented worker-monitoring loop.

**Impact**: Gemini/Antigravity swarms now have a documented and wired manager loop for worker coordination, bringing them closer to Claude's parallel-agent behavior.


---

## 2026-04-02 08:16:00 - Fix Parallel Start Script Parity

**What Changed**: Unified the Codex start entrypoints around the shared multi-agent launcher, made the Codex and Droid wrappers accept optional mux selection, synchronized the Antigravity start script with the shared runtime path for Codex/Droid managers, and updated startup docs to reflect Claude, Gemini, Codex, and Droid support.

**Why Changed**: The repo still exposed an older tmux-only Codex starter and an out-of-sync Antigravity start script, which made startup behavior depend on which command or implementation a user happened to invoke.

**Impact**: Parallel startup now routes through the same cross-agent launcher for all supported agent technologies, reducing drift between Claude, Gemini, Codex, and Droid startup paths and making the documented commands match actual behavior.


---

## 2026-04-16 08:22:17 - Monitor worker swarm state

**What Changed**: Ran the /monitor-workers checks against the agents repo, including worktree status, cmux workspace discovery, label/issue state, and deploy readiness checks.

**Why Changed**: AGENTS.md requires logging agent activity, and this pass needed a persistent record of the current manager/worker state without changing code.

**Impact**: Captured that the swarm is currently idle: no open GitHub issues, no working locks, no integration branch to deploy from, and worker worktrees only contain lingering untracked files.


---

## 2026-04-16 09:07:11 - Monitor worker swarm state

**What Changed**: Ran the /monitor-workers checks against the agents repo again, including worktree status, cmux worker screens, loop status files, GitHub issue state, and deploy-readiness validation.

**Why Changed**: AGENTS.md requires logging agent activity, and this monitor pass identified whether any workers needed dispatch or cleanup.

**Impact**: Confirmed there are no open or working GitHub issues, two workers are idle, one worker is stuck in a regression-harness/config validation pass, and deployment is not applicable because origin/integration does not exist in this repository.


---

## 2026-04-16 09:23:24 - Monitor-workers status pass

**What Changed**: Ran the manager-side monitor-workers checks across agents worktrees, cmux worker sessions, GitHub queue state, and deploy-readiness refs. Confirmed three worker worktrees, three Codex fix-loop sessions, no open GitHub issues, and no integration branch configured for deploy gating.

**Why Changed**: The autocoder manager workflow requires periodic worker monitoring to detect idle capacity, stale work, queue state, and whether deployment conditions have been met.

**Impact**: Confirmed the swarm is idle because no actionable queue exists. Worker worktrees only show local history/report artifacts from their completed passes, and deployment was not attempted because this repo uses origin/master rather than origin/integration.


---

## 2026-04-16 09:39:32 - Monitor workers status check

**What Changed**: Ran the /monitor-workers manager checks across agents worktrees, cmux worker screens, GitHub queue state, and deploy-readiness refs. Confirmed three worker worktrees, one active fix-loop session, two idle fix-loop sessions, zero open issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user requested the manager-side monitor pass for the autocoder swarm, which requires an up-to-date status snapshot before dispatch or deploy decisions.

**Impact**: Provides a current worker/queue summary, confirms there is no work to dispatch or stale working label to clear, and shows deploy cannot be evaluated against an integration branch because the ref is not configured.


---

## 2026-04-16 09:55:40 - Monitor workers

**What Changed**: Ran the /monitor-workers manager checks across agents worktrees, cmux worker sessions, GitHub queue state, and deploy-readiness refs. Confirmed three worker worktrees, three Codex fix-loop sessions, zero open issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: Provide a manager-side status snapshot for the active swarm and verify whether any work dispatch or stale-lock cleanup was required.

**Impact**: Workers are idle with no queue to dispatch; deploy is not gated because origin/integration is not configured, and worker worktrees still contain local history/test artifacts from recent regression passes.


---

## 2026-04-16 10:11:38 - Monitor workers pass

**What Changed**: Ran /monitor-workers manager checks across agents worktrees, cmux worker sessions, GitHub queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: User invoked /monitor-workers and the autocoder workflow requires manager-side queue and worker visibility.

**Impact**: Current swarm is idle with no dispatchable work and no deploy action available.


---

## 2026-04-16 10:27:50 - Monitor workers status check

**What Changed**: Ran the /monitor-workers manager checks across agents worktrees, cmux worker sessions, GitHub queue state, and deploy-readiness refs. Confirmed three worker worktrees, three Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a point-in-time view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: Verified all workers are idle with no actionable queue items, so no dispatch, stale-label cleanup, review-blocked action, or deploy step was needed.


---

## 2026-04-16 10:43:54 - Monitor-workers status pass

**What Changed**: Ran the manager-side /monitor-workers checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: Verified the swarm is idle with no actionable queue items, no stale working labels to clear, and no deploy trigger because the integration ref is not configured in origin.


---

## 2026-04-16 10:59:58 - Monitor workers status check

**What Changed**: Ran the /monitor-workers manager checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: No dispatch, stale-label cleanup, review-blocked escalation, or deploy action was needed. The swarm is idle because the GitHub queue is empty, and deployment remains ungated until an integration branch exists.


---

## 2026-04-16 11:16:06 - Monitor workers manager pass

**What Changed**: Ran the /monitor-workers manager checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: No work was dispatched because every worker is idle and the GitHub queue is empty. Deploy was not attempted because there is no origin/integration ref available to evaluate staging readiness.


---

## 2026-04-16 11:32:23 - Monitor workers manager check

**What Changed**: Ran the /monitor-workers manager checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: No dispatch, stale-label cleanup, blocked-issue review, or deploy action was required because the queue is empty and all workers are already idle.


---

## 2026-04-16 11:48:25 - Monitor-workers status pass

**What Changed**: Ran the /monitor-workers manager checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: There is no actionable queue to dispatch and no deploy gate branch to evaluate, so the swarm is idle and waiting for new work or an explicit integration/deploy configuration.


---

## 2026-04-16 12:04:24 - Monitor workers

**What Changed**: Ran the manager-side /monitor-workers checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: The repository now has a fresh point-in-time worker monitor record showing no dispatchable work, no stale working labels, and no deploy-ready integration branch.


---

## 2026-04-16 12:20:34 - Monitor workers manager check

**What Changed**: Ran the /monitor-workers manager checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: The repository now has a fresh point-in-time worker monitor record showing no dispatchable work, no stale working labels, and no deploy-ready integration branch.


---

## 2026-04-16 12:36:56 - Monitor workers status snapshot

**What Changed**: Ran the /monitor-workers manager checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: Confirmed there is no actionable queue to dispatch, no stale working labels to clear, and no deploy gate to evaluate because origin/integration is not configured in this repository.


---

## 2026-04-16 12:52:59 - Monitor workers manager sweep

**What Changed**: Ran the /monitor-workers manager checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: No dispatch actions were needed because the GitHub queue is empty and all workers are already idle. Deploy is not eligible because there is no origin/integration ref configured for readiness checks.


---

## 2026-04-16 13:09:11 - Monitor workers status check

**What Changed**: Ran the /monitor-workers manager checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: The repository now has a fresh point-in-time worker monitor record showing no dispatchable work, no stale working labels, and no deploy-ready integration branch.


---

## 2026-04-16 13:25:32 - Monitor workers: idle queue check

**What Changed**: Ran the /monitor-workers manager checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: No worker dispatch or stale-label cleanup was needed. The swarm is idle, the queue is empty, and staging deploy gating cannot proceed until an integration branch/ref is configured and new integration commits exist.


---

## 2026-04-16 13:42:13 - Monitor workers status check

**What Changed**: Ran the manager-side /monitor-workers checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: No dispatch or stale-label cleanup was required. Workers remain idle because there is no actionable queue work, and deploy is not gated because origin/integration is not configured.


---

## 2026-04-16 13:58:28 - Monitor workers

**What Changed**: Ran one-shot /monitor-workers status check across worktrees, GitHub issue queue, and tmux availability.

**Why Changed**: Repo policy requires logging agent activity and the monitor pass established current worker state before taking further action.

**Impact**: Confirmed no open GitHub issues or active tmux workers; surfaced dirty worker worktrees that may need cleanup or integration review.


---

## 2026-04-16 14:14:30 - Monitor-workers status pass

**What Changed**: Ran the manager-side /monitor-workers checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: Verified there was no work to dispatch, no stale working labels to clear, and no deploy trigger available from this repo state.


---

## 2026-04-16 14:30:26 - Monitor workers status check

**What Changed**: Ran the manager-side /monitor-workers checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: No dispatch or deploy action was taken because there is no available or blocked work in the queue, all workers are idle, and integration deploy readiness is not configured.


---

## 2026-04-16 14:46:23 - Monitor workers status check

**What Changed**: Ran the manager-side /monitor-workers checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: No worker dispatch or deploy action was needed. The system is idle and ready for new issues, while the missing integration ref means automated deploy readiness cannot be evaluated in this repo state.


---

## 2026-04-16 15:02:12 - Monitor workers

**What Changed**: Ran the manager-side /monitor-workers checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: No dispatches were needed because the queue is empty. Current risk is limited to stale uncommitted worker artifacts in the worktrees and an unconfigured integration deploy ref.


---

## 2026-04-16 15:18:07 - Monitor workers

**What Changed**: Ran the /monitor-workers workflow from the manager session. Verified three worker worktrees and cmux workspaces, checked GitHub issue state, and inspected worker screens.

**Why Changed**: Confirm whether any workers were active, whether dispatch/review was needed, and whether stale working labels existed.

**Impact**: No open or blocked GitHub issues were present, all three workers were idle at IDLE_NO_WORK_AVAILABLE, and no dispatch or review-blocked action was required.


---

## 2026-04-16 15:34:36 - Monitor-workers status pass

**What Changed**: Ran the manager-side /monitor-workers checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, three idle Codex fix-loop sessions, zero open issues, zero working issues, zero blocked issues, and no origin/integration ref configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, and deploy readiness before dispatching or escalating anything.

**Impact**: No dispatch or deploy action was required. All workers are idle with no actionable queue, and deploy remains gated because the repository has no origin/integration ref configured.


---

## 2026-04-16 21:56:06 - Monitor workers status check

**What Changed**: Ran the manager-side /monitor-workers checks across agents worktrees, cmux worker sessions, GitHub issue queue state, and deploy-readiness refs. Confirmed three worker worktrees, zero open issues, zero working issues, zero blocked issues, two idle Codex fix-loop workers, and one disconnected worker session in agents-wt-2 showing repeated Codex websocket reconnect failures. Also confirmed origin/integration is not configured for deploy gating.

**Why Changed**: The user invoked /monitor-workers and AGENTS.md requires agent activity to be logged. The manager workflow needs a current view of worker utilization, queue state, worker health, and deploy readiness before dispatching or escalating anything.

**Impact**: The repository has no dispatchable GitHub work at this time, so no worker was assigned. The only actionable follow-up is to restart or repair the wt2 worker session if that worker should remain available; deploy cannot be evaluated against an integration branch because origin/integration does not exist.


---

## 2026-04-20 13:36:43 - Attempted user-level skillporter install

**What Changed**: Inspected the skill-installer workflow, verified https://github.com/keithmackay/skillporter is a valid root-level skill, and attempted installation into ~/.codex/skills/skillporter. The install was blocked by sandbox write restrictions on the user-level Codex directory.

**Why Changed**: The request was to install skillporter at the user level using the standard Codex skill install path.

**Impact**: No global skill was installed from this session, but the exact working install command and blocker were identified.


---

## 2026-04-20 13:52:49 - Port shared skills for Gemini and sync plugin parity

**What Changed**: Applied the skillporter workflow to the shared autocoder and modernize skills by adding Gemini CLI extension manifests and context files, adding per-skill cross-platform READMEs, and updating the repo README to document Gemini CLI packaging. Synced autocoder metadata across Claude, Codex, and Factory manifests, and updated the shared autocoder skill references to include worker monitoring and manager-loop capabilities.

**Why Changed**: The repository already had Claude, Codex, Antigravity, and Factory surfaces, but the shared skills were missing Gemini CLI packaging and some autocoder command metadata had drifted between platform manifests.

**Impact**: Shared skills are now portable across Claude, Codex, Antigravity, and Gemini CLI packaging patterns, and the autocoder command and version metadata is aligned across the supported platform surfaces.


---

## 2026-05-03 13:29:55 - Install ARI Codex plugin

**What Changed**: Installed tv-ari-skills 1.0.2 from nextgen-CDD ari-plugin bundle into Codex marketplace configuration

**Why Changed**: User requested installation from the integration ari-plugin source

**Impact**: Codex now has the TV ARI Skills marketplace enabled; start with ari_help


---

## 2026-05-03 13:32:41 - Install ARI plugin from zip URL

**What Changed**: Downloaded tv-ari-skills-1.0.2.zip via authenticated GitHub API from the integration ari-plugin path, extracted it into a durable Codex marketplace directory, and registered tv-ari-skills from that bundle

**Why Changed**: User requested installation specifically from the tv-ari-skills-1.0.2.zip URL

**Impact**: Codex tv-ari-skills marketplace now points to /Users/Laird.Popkin/.codex/marketplaces/tv-ari-skills-url-1.0.2 with plugin version 1.0.2 enabled


---

## 2026-06-03 11:53:03 - Install Codex marketplace

**What Changed**: Verified the repository is registered as the laird-agents Codex marketplace and updated the Codex marketplace manifest policy metadata.

**Why Changed**: The user requested this checkout be installed as a plugin marketplace, and current Codex marketplace entries should include authentication policy metadata.

**Impact**: Codex lists laird-agents at /Users/Laird.Popkin/src/agents with autocoder available/installed and modernize available; validation commands confirmed JSON syntax.


---

## 2026-06-03 12:01:01 - Fix Codex worker dispatch handshake

**What Changed**: Updated monitor-workers guidance so Codex worker dispatch uses scripts/codex-autocoder.sh fix N, which runs the issue-start handshake before launching Codex.

**Why Changed**: A Codex worker could otherwise be dispatched with a Claude-only slash command and work from its main-wt-N branch without the feature/issue-N branch or Implementation Started marker peers use to validate locks.

**Impact**: Manager-dispatched Codex workers now route through the wrapper that claims the issue, switches to feature/issue-N, and posts the visible start marker before implementation.


---

## 2026-06-15 11:58:18 - Paused swarm issue source spec

**What Changed**: Added a draft spec for paused swarm startup, per-run issue source selection, worker start controls, and Claude/Gemini/Codex/Droid compatibility.

**Why Changed**: Document the design and critical risks before implementation.

**Impact**: Creates an implementation target without changing runtime behavior.


---

## 2026-06-15 12:45:36 - Revise paused swarm spec after design review

**What Changed**: Updated the paused swarm spec to add a minimal swarm manifest, safer manager readiness instructions, explicit start-worker/start-workers CLI grammar, lifecycle issue-source inheritance, and stricter bulk-start safeguards.

**Why Changed**: Address critical design review findings before implementation.

**Impact**: The implementation target now covers issue-source continuity, reliable worker targeting, and safer paused-mode semantics across supported agents.


---

## 2026-06-15 12:52:51 - Revise paused swarm spec after second review

**What Changed**: Updated the paused swarm spec to require manifest issue-source exports before start-worker commands, Droid-specific interactive-launch wording, durable .ready.txt readiness instructions, atomic manifest writes, and partial start failure states.

**Why Changed**: Address the latest critical design review findings before implementation.

**Impact**: The spec now gives more precise execution semantics for paused worker start, readiness display, and failure handling.


---

## 2026-06-15 12:55:23 - Revise paused swarm spec with launch modes

**What Changed**: Updated the paused swarm spec to add worker launchMode and agentLaunched fields, conditional manager launch based on no-submit readiness display, serialized manifest locks, and shell-only issue-source export rules.

**Why Changed**: Address critical design review issues around interactive REPL panes, manager readiness visibility, and concurrent manifest updates.

**Impact**: Implementation now has explicit rules for when shell commands can be sent safely and how manifest updates must be protected.


---

## 2026-06-15 12:59:11 - Refine paused swarm readiness design

**What Changed**: Updated the paused swarm spec with separate shell and agent readiness templates, manager readiness manifest fields, explicit command-delivery semantics for worker state, flock-based manifest locking, and corrected launch-mode wording.

**Why Changed**: Resolve the latest design review findings and remove contradictory wording before implementation.

**Impact**: The spec is more internally consistent and exposes the remaining implementation risks clearly.


---

## 2026-06-15 13:19:57 - Finalize paused swarm manifest design updates

**What Changed**: Updated the paused swarm spec to require manifests for paused worker starts, add worker commandMode, make normal startup manifest-free for v1, add manager.readyFile, and remove no-manifest target inference.

**Why Changed**: Resolve the latest critical design review issues around unsafe fallback targeting and shell-vs-agent command delivery.

**Impact**: The spec now defines a tighter v1 scope with fewer ambiguous runtime paths.


---

## 2026-06-15 13:21:32 - Update paused swarm spec after latest review

**What Changed**: Updated the paused swarm spec to require manifests for paused worker starts, add commandMode, clarify normal non-paused issue-source continuity limits, define paused add-worker behavior, and require shared launch/readiness mode helpers.

**Why Changed**: Resolve review findings around unsafe no-manifest fallback, shell-vs-agent command delivery, and unclear add-worker semantics.

**Impact**: The spec now has a narrower v1 scope and a clearer implementation contract for lifecycle scripts.


---

## 2026-06-15 13:24:38 - Focus README swarm docs on start-parallel

**What Changed**: Updated autocoder README swarm documentation to lead with start-parallel commands and option tables, replacing alias-led quick starts and lifecycle examples.

**Why Changed**: Users should see the canonical start-parallel command and options instead of being pushed toward bundled aliases.

**Impact**: README now documents swarm startup through explicit commands; users can define their own aliases if desired.


---

## 2026-06-15 13:29:01 - Update paused swarm spec and review

**What Changed**: Refined paused swarm spec for read-only issue-source resolution, manifest issueSourceOrigin, restart-worker paused semantics, fail-closed target handling, and environment-origin file backend validation; cleaned README command references to focus on start-parallel and installed commands.

**Why Changed**: The design review found remaining ambiguity around config mutation, incomplete file backend env, restart starting behavior, and stale alias/script-name documentation.

**Impact**: Spec now has clearer implementation constraints and CDR findings; README no longer points users at shell aliases or internal start/join/end/stop script names.


---

## 2026-06-15 13:45:27 - Write paused swarm implementation plans

**What Changed**: Added a dedicated implementation-plans section to the paused swarm spec covering shared helpers, paused start, delayed worker start commands, lifecycle integration, documentation, validation sequence, rollback notes, and dry-run seams.

**Why Changed**: The design was ready for implementation but needed concrete phased plans tied to current files and test gates.

**Impact**: Future implementation can proceed in bounded phases with explicit exit criteria and lower risk around mux command delivery.


---

## 2026-06-15 13:50:03 - Review paused swarm implementation plans

**What Changed**: Performed a critical review of the paused swarm implementation plan against the current launcher, helper scripts, installer docs, autocoder help, and test layout.

**Why Changed**: The implementation plan needed scrutiny before coding because paused start affects command delivery, issue-source resolution, manifests, lifecycle scripts, and install surfaces.

**Impact**: Identified plan risks around default behavior changes, concurrent start races, stable tmux targets, manifest lookup, installer/help gaps, test gating, and backend compatibility.


---

## 2026-06-15 13:54:31 - Update and review paused swarm plan

**What Changed**: Updated the paused swarm spec and implementation plans so omitted --issue-source uses the project's last-used .autocoder.json source before environment fallback; added stable tmux pane IDs, locked starting-state worker start, stale starting recovery, custom ISSUE_BACKEND preservation, installer relink requirements, and per-plan test gates; performed another critical plan review.

**Why Changed**: The prior review found ambiguity around default issue-source behavior, double-start races, tmux target identity, manifest lookup, installer coverage, staged testing, helper compatibility, and custom backend handling.

**Impact**: The plan is more implementation-ready, with remaining review risks narrowed to bounded command-send timeouts, exact stale thresholds, and manual smoke examples that still use pane-index inspection for convenience.


---

## 2026-06-15 13:59:21 - Update and review paused swarm plan again

**What Changed**: Updated paused swarm implementation plans with timeout-wrapped tmux/cmux send helpers, portable stale-age helper requirements, a 5-minute stale starting threshold, manifest-derived smoke inspection, explicit source-preflight rollback, and CDR findings for lock bottlenecks, stale recovery, rollback scope, and macOS portability.

**Why Changed**: The prior critical review found remaining risks around unbounded mux sends while locked, unspecified stale recovery, pane-index smoke examples, rollback scope, and nonportable timeout/date assumptions.

**Impact**: The plan now has clearer safety bounds and portability requirements; remaining risks are limited to implementation discipline around lock duration, large-swarm startup latency, and installer test isolation.


---

## 2026-06-15 13:59:38 - Tighten paused swarm validation plan

**What Changed**: Added validation-plan requirements for multi-worker bounded-lock testing and isolated installer tests using temporary HOME, PATH, and install directories.

**Why Changed**: The final critical review found that timeout behavior and installer relink behavior need realistic test harness constraints, not just single-command checks.

**Impact**: Implementation has clearer validation expectations for lock duration under worker batches and safe installer testing without mutating the operator environment.


---

## 2026-06-15 14:16:46 - Implement paused swarm startup

**What Changed**: Added paused start-parallel mode, read-only issue-source CLI resolution, paused swarm manifests, delayed start-workers/start-worker commands, lifecycle inheritance for add/restart worker, installer links, docs, and focused tests.

**Why Changed**: Users need to create Claude/Gemini/Codex/Droid swarms that are ready for issue review without immediately pulling tickets, while preserving the project issue source by default.

**Impact**: start-parallel now supports --paused/--no-start and --issue-source/--issue-dir; paused swarms can later start all or selected workers with manifest-backed safeguards.


---

## 2026-06-15 14:25:26 - Make add-worker the start scale command

**What Changed**: Changed add-worker to start existing idle manifest workers before creating new workers, support add-worker [count], start newly added manifest workers through the internal delivery helper, remove start-worker/start-workers from user-facing docs/installers, and install pytest into /private/tmp/agents-pytest for Python test execution.

**Why Changed**: The manager should have one user-facing command for starting or scaling worker capacity; users should tell the manager to add workers, and idle workers should be used before creating new capacity.

**Impact**: Paused swarms now surface add-worker as the command to begin work or scale up; tests can run Python coverage with PYTHONPATH=/private/tmp/agents-pytest.


---

## 2026-06-15 14:42:14 - Add remove-worker command

**What Changed**: Added plugins/autocoder/scripts/remove-worker.sh, manifest removal support, installer links, README/help/install documentation, and tests for remove-worker help and manifest worker removal.

**Why Changed**: Users need a manager-facing way to shut down one or more selected swarm workers without tearing down the entire swarm.

**Impact**: remove-worker WORKER_NUMBER [...] now closes manifest-backed tmux panes or cmux workspaces, removes workers from the manifest, and preserves worktrees by default unless --remove-worktree is passed.


---

## 2026-06-16 09:42:49 - Bump autocoder plugin version

**What Changed**: Updated Autocoder plugin metadata to 4.3.0 across Claude, Factory, and Codex plugin manifests; bumped Claude marketplace to 3.22.0 and Factory marketplace to 3.19.0; fixed ignored local issue YAML front matter titles.

**Why Changed**: Release the paused swarm lifecycle controls and keep marketplace update detection aligned with plugin metadata.

**Impact**: Plugin consumers can receive the new Autocoder release metadata; local file issue parsing no longer trips over unquoted title colons in ignored .issues files.


---

## 2026-07-28 11:34:16 - Fix #14: hold the 'working' claim lock until a terminal outcome

**What Changed**: Rewrote the lock-lifecycle rules in plugins/autocoder/commands/dev.md and .agent/workflows/dev.md: replaced the blanket 'remove in ALL exit paths / before moving to the next issue' instruction with a terminal-outcome-only rule, added an explicit anti-pattern example for partial commits, made the PR-creation and paused-enhancement paths retain the lock, and turned the enhancement-skip path into an announced release (comment first, then label removal). Added tests/test_dev_working_lock.py (23 assertions) guarding the wording, the per-site terminal justification, and Claude/Antigravity mirror parity.

**Why Changed**: The 'working' label is the concurrency lock, but the protocol told agents to drop it at any stop — including after a partial commit. The issue stayed OPEN and re-entered the claimable pool while a worker still held the branch, so a peer double-claimed it and the duplicate work was discarded.

**Impact**: Partial progress no longer re-exposes an in-progress issue. Deliberate hand-offs are now visible as release comments rather than a silently vanished lock; abandoned locks remain the responsibility of /monitor-workers stale detection.


---

## 2026-07-28 12:22:25 - Port master's claim arbitration onto the /dev line (guards #15 against regression)

**What Changed**: Backported the race-safe claim arbitration from origin/master's fix.md (3124b99) into plugins/autocoder/commands/dev.md and .agent/workflows/dev.md — byte-identical block. Additionally fixed three defects not present upstream: a redundant second label-add claim in the specified-issue path that aborted without releasing the lock; a weak enhancement-path claim that leaked the lock (.agent variant did not even exit on race, falling through to implement); and .agent assigning ISSUE_NUM after the claim block that references it. Added tests/test_dev_claim_arbitration.py (23 assertions).

**Why Changed**: The /fix -> /dev rename left fix.md as a 7-line alias stub. Master's hardening lives in fix.md, so merging the integration branch into master would replace it with a dev.md that never had the arbitration — silently regressing #15 after it was closed.

**Impact**: The /dev line now has claim parity with master, and a red test blocks any future rename from dropping it again. Two lock-leak paths that could strand issues with no worker holding them are closed.


---

## 2026-07-28 13:11:54 - Fix #32: CI now runs the shell test suites

**What Changed**: Added scripts/run-shell-suites.sh (runs every tests/*.sh, continues past failures, summarises, exits non-zero on any failure) and wired it into .github/workflows/test.yml as a step alongside pytest. Added tests/test_ci_runs_shell_suites.py (7 assertions) guarding that CI keeps invoking it, that pytest still runs, that fixtures stay excluded, and that a failing suite actually turns the run red.

**Why Changed**: CI ran only 'pytest tests/', which collects Python tests. All 9 tests/*.sh suites — including those covering the claim lock, the issue backend, and the multiplexer probe — were never executed. CI was green and that green said nothing about them.

**Impact**: Shell regressions now fail CI. Also found that the suites are sensitive to an inherited ISSUE_SOURCE: three failed locally purely because the developer shell exported one. The runner scrubs those vars per suite, so local and CI results agree.

