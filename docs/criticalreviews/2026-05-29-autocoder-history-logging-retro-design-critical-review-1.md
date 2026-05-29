# Critical Design Review: 2026-05-29-autocoder-history-logging-retro-design (Round 1)

**Spec:** `docs/superpowers/specs/2026-05-29-autocoder-history-logging-retro-design.md`
**Verified Assumptions section:** MISSING

> ⚠️ This spec lacks a `Verified assumptions` section. Reviewer cannot distinguish verified facts from unverified assumptions; treat findings accordingly.

---

## 2. Literal-wrongness findings

### Finding 1: GitHub label `history-log` must pre-exist before `gh issue create --label history-log`

**Description:**  
The spec's GitHub backend path calls `gh issue create --label history-log`. GitHub CLI requires the label to already exist on the repository; if it does not, `gh issue create` exits with an error (`label 'history-log' not found`). The issue is not created. On first use of the GitHub backend in any fresh repo, every history-log call silently fails — the history accumulates nowhere, and the retro's primary data source is empty.

**Evidence:**  
Spec §Part 1, GitHub backend behavior, step 2: `gh issue create --label history-log --title "Autocoder History Log" ...`. The `history-log` label is never created by the script or by any other described mechanism. The existing label-setup block in `fix.md` (which creates P0-P3 and other labels) is not updated to include `history-log`.

**Proposed fix:**  
Add `history-log` label creation to `append-to-history.sh`'s GitHub path before the first issue create, or add it to `fix.md`'s one-time label-setup block alongside the existing priority labels.

---

## 3. Forced decisions

### Decision 1: Modernize deployment mechanism for `append-to-history.sh`

**The choice:**  
The spec lists `plugins/modernize/protocols/protocols-overview.md` as modified to "reference `scripts/append-to-history.sh` from plugin instead of creating inline." Two mechanisms are possible with substantially different change scope:

**Option A — Copy at deploy time:** `protocols-overview.md` gains a step that copies the script from the modernize plugin's scripts directory into `./scripts/` in the target project. This requires resolving the modernize plugin's install location at runtime inside a target project — the same `SCRIPT_DIR` detection problem autocoder already solves, but modernize does not currently have this infrastructure.

**Option B — Keep inline, use plugin file as maintainer sync source only:** `protocols-overview.md`'s runtime behavior is unchanged (it still creates the script via the inline heredoc). The new `plugins/modernize/scripts/append-to-history.sh` serves only as the maintainer's canonical source; humans update the heredoc to match it. No runtime change to how the script arrives in target projects.

**Why it's forced:**  
Option A requires modernize commands to gain plugin-location resolution that doesn't currently exist in that plugin. Option B requires no runtime change but leaves two representations of the script that can drift. The spec's wording implies A but doesn't address how the plugin's install location is resolved at runtime in a target project that may not contain the agents repo.

---

### Decision 2: `HISTORY.md` location when running inside a `fix-loop` git worktree

**The choice:**  
`fix-loop.md` dispatches parallel agents in isolated git worktrees. The spec says `fix.md` logs to `--history-file "HISTORY.md"` (relative path). In a worktree, this resolves to that worktree's root — a different directory than the main worktree. Parallel agents each write to their own disconnected `HISTORY.md`; the retro, which runs from one directory, sees only that fragment.

Three options:

**Option A — Always resolve to main worktree:** use `$(git worktree list --porcelain | grep -m1 '^worktree' | cut -d' ' -f2)/HISTORY.md`. All agents append to one file. Sequential appends are safe; concurrent writes from parallel agents can interleave (last-writer-wins on the append), but for a log this is usually tolerable.

**Option B — Per-worktree files; retro merges:** each worktree writes its own `HISTORY.md`; the retro scans `git worktree list` to find and merge them all. More complex retro; no concurrent-write risk.

**Option C — Skip logging in non-main worktrees:** only agents in the main worktree log; parallel worktree agents are silent. Simplest. Loses parallel-agent history.

**Why it's forced:**  
The spec adds logging to `fix.md` and names `fix-loop.md` as also getting a log entry. Without picking an option, implementation will default to per-worktree files (Option B behavior without the merge logic), making the retro's history incomplete on any project that uses `fix-loop`.

---

## 5. Recommendation

🛑 **Surface forced decisions to user** — user input needed on Decision 1 (modernize deployment mechanism) and Decision 2 (HISTORY.md location in worktrees) before the implementation plan can be written. Address the §2 literal-wrongness finding (GitHub label creation) alongside whichever path is chosen for Decision 1.
