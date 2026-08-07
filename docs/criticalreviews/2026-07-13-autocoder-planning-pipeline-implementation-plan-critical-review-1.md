# Critical Implementation Review: 2026-07-13-autocoder-planning-pipeline-implementation-plan (Round 1)

**Plan:** `/Users/Laird.Popkin/src/agents/docs/plans/2026-07-13-autocoder-planning-pipeline-implementation-plan.md`
**Verified plan-level assumptions section:** present

⚠️ 1 commit since plan-write time (SHA `538c4537`); cited file:line references re-checked under §1. (The commit is the plan-doc addition `c5132e0`; no source files changed.)

## 1. Verified-plan-assumptions cross-check

Fresh read of each cited evidence (unchanged since plan-write; all evidence gathered this session):

1. `commands/fix.md`/`fix-loop.md` exist to rename — **still holds.**
2. `.agent/workflows/fix.md`/`fix-loop.md` exist (+`.backup`) — **still holds.**
3. `commands/plan.md`, `.agent/workflows/autocoder-plan.md` are free — **still holds.**
4. `.agent/workflows/plan.md` is modernize's; autocoder mirror must be `autocoder-plan.md` — **still holds.**
5. `worker-launch-lib.sh:36/45` `WORKER_CMD` strings; single-source at `:6` — **still holds.**
6. `check-optional-skills-drift.sh:25–32` hardcodes fix/fix-loop paths — **still holds.**
7. `fix-loop.local.md` has ~10 consumers; keep the name — **still holds.**
8. Internal callers in gate/dispatch/monitor-workers/worker-launch-lib — **still holds.**
9. Claude+Factory list `commands[]`; Codex has none (skills-dir + references) — **still holds.**
10. Marketplace version fields (.claude-plugin root 3.22.0/autocoder 4.3.0; .factory root 3.19.0/autocoder 4.3.0; codex/agents none) — **still holds.**
11. `CLAUDE.md:191–192` are the fix/fix-loop mapping rows — **still holds.**
12. Decompose/sub-task template + linking strings at `fix.md:1225–1354` — **holds, with a caveat that is load-bearing for §2 finding 1:** the template at `fix.md:1262` posts the sub-task checklist via `issue_comment` (a *comment*), and the auto-close monitor at `fix.md:1327` reads the parent's `.body`. Copying the block faithfully therefore does **not** place the story refs where the monitor looks. Flagged in §2.
13. `monitor-workers.md` Steps 5b/5c present; `remove-worker` exists — **still holds.**
14. Repo commit-message convention — **still holds.**

## 2. Literal-wrongness findings

**1. Task 5 Step 5 writes the story checklist to the spec issue *body*, but no body-edit primitive exists — and the realizable alternative breaks the spec's auto-close outcome.**

- **Evidence:**
  - File backend `update` exposes only `--add-label/--remove-label/--status/--assignee` — no `--body` (`scripts/issues-file.py:583–588`).
  - gh backend `update` maps to `gh issue edit --add-label/--remove-label/--add-assignee` — no body edit (`scripts/issues-gh.sh:89–94`).
  - `issue-fns.sh` exposes no body-set verb (grep: no match). The only post-creation text primitive is `comment`.
  - The spec issue is created at Task 5 Step 2, *before* stories exist (Step 5), so its body cannot contain the story numbers at creation time; they can only be added afterward — which requires a body edit that does not exist.
  - The auto-close monitor enumerates children by grepping the **parent `.body`** for `#\K[0-9]+` (`fix.md:1327`). If the checklist is instead posted as a comment (the only available mechanism, matching `fix.md:1262`), the monitor reads an empty child set.
  - Worse than "won't close": with an empty `PARENT_SUBTASKS`, the monitor's `for` loop runs zero iterations, `ALL_CLOSED` stays `true`, and the parent is **closed on the first story's completion** (`fix.md:1319–1345`) — the spec issue closes prematurely, before the remaining stories are done.
- **Why it breaks the spec's outcome:** spec §3 step 6 / §7 state the spec issue auto-closes *when all stories are done*. As planned, it either never closes (checklist not in body) or closes immediately after the first story (empty enumeration). Both contradict the stated outcome.
- **Proposed fix (plan must pick one and specify it):**
  - (a) Add a `--body`/body-replace verb to the issue backends + `issue-fns.sh`, and have Step 5 rewrite the spec body to include the `- [ ] #<story>` checklist after stories are created; **or**
  - (b) Change the auto-close monitor in `dev.md` to enumerate children by scanning all issues for the child-side `## Sub-task of #<SPEC>` marker (which the plan already writes), instead of reading the parent body — removing the need to edit the parent body at all; **or**
  - (c) Post the checklist as a comment *and* change the monitor to read `.comments` as well as `.body`.
  Each is a real change the current plan does not contain. (Option (b) is the smallest and also fixes the latent premature-close behavior for the existing ultra-complex decomposition path.)

## 3. Forced decisions

**1. How does `/plan` guarantee the design doc lands on the *integration* branch (Task 5 Step 1)?**

- **The choice:** Task 5 Step 1 asserts "the manager session's cwd is the host workspace on the integration branch" and commits the doc directly. Whether the host workspace's *checked-out branch* is the integration branch is not guaranteed by anything in the codebase — the manager runs in the host workspace but on whatever branch is checked out.
- **Why it's forced:** spec B3/§3.2's outcome is that workers (which branch from the integration branch) can see the doc. If `/plan` commits the doc on a non-integration branch, workers never see it and the linked doc pointer dangles — the stated outcome breaks. The plan silently picked "assume current branch == integration."
- **The options (reviewer surfaces; does not pick):**
  - (a) `/plan` explicitly checks out / targets the configured integration branch (`CLAUDE_CODE_INTEGRATION_BRANCH`, default `main`/`master`) before committing the doc, then restores.
  - (b) `/plan` commits on the current branch and documents a precondition that the manager must be on the integration branch when planning.
  - (c) `/plan` pushes the doc to the integration branch via a separate ref without switching the working tree.

## 5. Recommendation

🛑 **Surface forced decisions to user** — §3 is non-empty (and §2 has one finding). §2 finding 1 must be resolved (the plan as written cannot auto-close the spec issue), and §3 finding 1 needs a user decision on integration-branch placement, before this plan is ready for `subagent-driven-development`. Recommended path: `update-implementation-plan` against this review.
