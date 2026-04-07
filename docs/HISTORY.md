# Project History

This file tracks all significant changes, migrations, and decisions.


---

## 2025-12-10 10:11:09 - Init

**What Changed**: Created script

**Why Changed**: Verification

**Impact**: Enabled logging


---

## 2026-03-16 13:26:14 - Add Codex skill migration plan

**What Changed**: Added a Codex-only migration plan and initial skills/autocoder and skills/modernize scaffolds.

**Why Changed**: Needed an additive Codex path that preserves Claude Code plugins and Antigravity/Gemini agents without reuse or breakage.

**Impact**: Repo now has a concrete, non-breaking starting point for Codex support.


---

## 2026-03-16 13:33:41 - Add Codex runtime support

**What Changed**: Added Codex-only loop, monitor, stop, and tmux swarm scripts plus Codex integration docs and README updates.

**Why Changed**: Codex lacks Claude Code's built-in loop runtime, so repo-specific shell wrappers were needed to make fix-loop and monitor-loop usable without touching existing Claude or Gemini paths.

**Impact**: The repo now has an additive Codex workflow with one-shot runs, continuous loops, worker monitoring, and tmux-based swarm startup.


---

## 2026-03-16 14:00:58 - Add Codex installer script

**What Changed**: Added scripts/install-codex.sh plus Codex install docs so shared skills, parallel-agent symlinks, and alias sourcing can be installed from the agents repo into a target project.

**Why Changed**: Codex support had runtime scripts and alias snippets but no standalone installer, which left start-parallel unavailable in downstream repos using the shared agents checkout.

**Impact**: Codex users can now run one installer command from the shared repo, reload their shell, and start cmux or tmux worker swarms in project repos without manual symlink setup.


---

## 2026-03-16 14:45:41 - Install Codex Runtime Wrappers

**What Changed**: Updated install-codex.sh to symlink repo-local codex runtime wrappers into target repos and documented the behavior in Codex install docs.

**Why Changed**: Target repos like nextgen-CDD expected shared Codex loop scripts, but the installer only linked skills and aliases, causing bash scripts/codex-fix-loop.sh and bash scripts/codex-manage-workers-loop.sh to fail with missing-file errors.

**Impact**: Running the installer now makes worker and manager loop entrypoints available from the target repo and its git worktrees, matching AGENTS.md expectations.


---

## 2026-03-16 14:47:44 - Make startcc Work In Fresh Worktrees

**What Changed**: Updated Codex loop scripts to resolve sibling helpers from the shared agents repo, and changed the shared parallel launcher to invoke Codex worker and manager loops via absolute shared-script paths. Clarified install docs to match the new behavior.

**Why Changed**: Codex startcc/startct launched fresh git worktrees that did not contain repo-local codex wrapper files, so worker and manager startup failed even after install. The loop scripts also hardcoded helper lookups through REPO_ROOT/scripts, which broke shared-script execution.

**Impact**: Codex swarm startup now works from installed repos because startcc/startct no longer depend on per-worktree wrapper files, while manual repo-local loop commands still work through the installed target-repo symlinks.


---

## 2026-03-16 14:50:46 - Fix start-parallel Symlink Path Resolution

**What Changed**: Updated the shared parallel launcher to resolve its real script path before deriving the agents repo root, preventing Codex worker and manager commands from collapsing to /Users/scripts when invoked through ~/.local/bin symlinks.

**Why Changed**: The startcc alias launches the shared start-parallel command from a symlink in ~/.local/bin. Computing relative paths from the symlink location produced an invalid shared runtime path for Codex loops.

**Impact**: Codex startcc/startct now derive absolute runtime script paths from the real agents checkout, so fresh workspaces get valid worker and manager commands.


---

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

