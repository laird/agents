# Design Spec: Autocoder Planning Pipeline + `dev` Rename

**Date:** 2026-07-13
**Status:** Design approved — passed critical-design-review round 1 (✅ approve as-is; 0 literal-wrongness findings, 0 forced decisions). See `docs/criticalreviews/2026-07-13-autocoder-planning-pipeline-design-critical-review-1.md`.
**Scope:** `plugins/autocoder` (+ mandatory `.agent/` mirror per CLAUDE.md parallel-maintenance rule)

## 1. Goal

Add a **planning** capability to the autocoder so a human, working with the manager
session, can take a raw feature goal through:

> brainstorm → spec → critical review (iterate until it passes) → decompose into
> stories → (existing) worker fleet implements each story, documents progress on the
> issue, validates, merges, closes → spec auto-closes when all stories are done.

Planning is **added to the manager's skill set**, not to a new agent. The manager
remains a set of skills used interactively in the manager session, and the
auto-invoked manager loop becomes **backlog-aware** so it keeps the fleet fed (suggest
planning when work is low) and stops burning tokens when work is absent (scale the
fleet down).

Secondary: rename `/fix` → `/dev` and `/fix-loop` → `/dev-loop` (the loop both fixes
bugs and implements features), keeping the old names as convenience aliases.

**Design principle:** maximum reuse. ~90% of this is orchestration over existing
skills and existing autocoder machinery. New infrastructure is deliberately minimal.

## 2. Manager model (unchanged structurally)

- The **manager** is the human's conversational session running in the host workspace
  (not a worktree). It is a *set of skills*, not an agent.
- **Workers** are separate agent sessions in isolated worktrees, each pulling
  claimable issues from the shared issue source and running `/dev` (formerly `/fix`).
- The manager loop (`/monitor-workers`, auto-invoked by `/monitor-loop`) supervises
  the fleet: dispatch, health/restart, scale, review-blocked, deploy.

This spec adds planning to the manager's skills and adds two behaviors to the manager
loop (§5). It does **not** change the worker implementation flow, which already does
TDD, posts progress comments, merges, and closes issues.

## 3. Planning pipeline — `/autocoder:plan "<goal>"`

New manager-facing command. Human-gated. Orchestrates existing skills; does **not**
reimplement them. Runs in the host workspace so its artifacts land on the shared
integration branch (see §3.2, B3).

| Step | Action | Reuses | Gate |
|---|---|---|---|
| 0 | Ensure `decomposed`/`subtask` labels exist | fix/dev label-bootstrap block | — |
| 1 | Brainstorm the goal → design doc committed to `docs/specs/YYYY-MM-DD-<topic>-design.md` on the integration branch | `thorough-brainstorming` (fallback `superpowers:brainstorming`) | **Human approves the design** |
| 2 | Create the **spec issue**: a thin pointer to the committed doc + an (initially empty) story checklist | `issue_create` | — |
| 3 | **Critical-review loop:** review the doc; apply findings; re-review. Post each pass's summary as a spec-issue comment | `critical-design-review` → `update-design-doc` | Autonomous iterate (see §3.1 termination) |
| 4 | **Decompose into stories:** break the reviewed spec into 3–8 independently-implementable, independently-testable stories | `/plan` logic (may borrow structure from `thorough-writing-plans`) | — |
| 4b | **Critical-implementation-review loop:** review the decomposition; apply findings; re-review | `critical-implementation-review` → `update-implementation-plan` | Autonomous iterate (see §3.4), then **human approves the breakdown** |
| 5 | Create one **story issue** per story: labeled `subtask` + priority, body header `## Sub-task of #<SPEC>`, acceptance criteria, and enough design context to act. Add `- [ ] #<story>` to the spec issue checklist and label the spec `decomposed` | `issue_create`, existing linkage convention | — |
| 6 | **Hand off:** the existing worker fleet (`/dev-loop` → `/dev`) pulls the `subtask` stories, implements each (TDD), comments progress, validates, merges, closes. The existing "Monitoring Decomposed Issues" logic auto-closes the spec when all stories are closed | worker fleet, existing auto-close monitor | — |

Artifact model: the `docs/specs/` doc is **canonical**; the spec issue is a pointer +
tracking checklist. (Chosen over doc-in-issue duplication.)

### 3.1 Critical-review loop termination (resolves B2)

Loop: `critical-design-review` on the doc → if it returns findings, `update-design-doc`
applies them → re-review. **Stop when a pass returns no findings, OR after a cap of 3
passes**, whichever comes first. If passes remain capped-out with open findings, surface
the residual findings to the human rather than looping indefinitely.

### 3.2 Design-doc visibility to workers (resolves B3)

`/plan` runs in the host workspace and commits the design doc to the **shared
integration branch** before/at story creation, so worktrees created or rebased
afterward contain it. Story-issue bodies additionally link the doc path **and** carry
enough context to act if the branch is stale.

### 3.3 Story granularity (resolves B4)

Decomposition-into-stories is its own step (3–8 feature-level, independently-testable
stories), **not** bound to `thorough-writing-plans`'s fine-grained-task output contract.
It may borrow structure from writing-plans but the unit of work is a *story issue*, sized
for a single worker to carry to merge.

### 3.4 Critical-implementation-review gate (step 4b)

The decomposition itself is reviewed before any story issue is created, mirroring the
spec review in §3.1: loop `critical-implementation-review` over the story breakdown → if
it returns findings, `update-implementation-plan` applies them → re-review. **Stop when a
pass returns no findings, OR after a cap of 3 passes**; surface residual findings to the
human. The human then approves the reviewed breakdown before step 5 creates the story
issues. This catches decomposition-level problems (missing stories, wrong boundaries,
hidden inter-story dependencies) before they become worker-level bugs.

## 4. `autocoder:planning` skill

A discoverable skill encoding the pipeline above, wired through the existing
`optional-skills-prelude` pattern used by every autocoder command. It:

- Documents the step sequence, gates, and reused external skills.
- Is invoked by `/autocoder:plan`; autonomous sub-steps (critical review, decomposition)
  may dispatch subagents. Interactive brainstorming runs in the manager session (a
  dispatched subagent cannot hold a live dialogue with the user).

No new **agent** definition file is added (autocoder has no `agents/` dir today, and the
human-gated flow needs none).

## 5. Manager-loop scaling ladder (backlog-aware)

`/monitor-workers` gains two behaviors so it understands the sequence of manager skills
and nudges/does the right next action. Full ladder:

| Condition | Action | Gating |
|---|---|---|
| Unblocked queue backing up, not draining | `add-worker` | Autonomous (existing 5b) |
| Backlog low but nonzero | Suggest `/autocoder:plan "<goal>"` to the human | Human-gated suggestion (**new**) |
| No claimable work **and** worker is idle **and** its worktree is clean (no claimed issue, no uncommitted changes) | `remove-worker N` to stop token burn; scale back up with `add-worker` when work reappears | Autonomous (**new**) |
| All open issues blocked, none claimable | `/review-blocked` | Autonomous (existing 5c) |

**Scale-down safety (resolves B1):** all durable state lives in the issue tracker
(gh/file), so removing an **idle, clean** worker loses nothing — a fresh worker started
later just pulls from the queue. Only idle+clean workers are auto-removed; a worker
mid-issue (claimed issue or uncommitted changes) is never auto-removed. No new script —
reuses existing `remove-worker` / `add-worker`.

## 6. Rename `/fix` → `/dev`, `/fix-loop` → `/dev-loop` (with aliases)

- `commands/dev.md` and `commands/dev-loop.md` become **canonical** (content moved from
  `fix.md` / `fix-loop.md`). Old `fix.md` / `fix-loop.md` become **thin alias stubs**
  that instruct the model to run `/dev` / `/dev-loop` with the same arguments.
- Mirror all of the above in `.agent/workflows/`.
- Repoint **all internal callers** to the new name: `gate.md`, `dispatch.md`, the
  `LOOP_TARGET`/dev-loop wiring, `hooks/stop-hook.sh`, `monitor-workers` dispatch, and
  any `autocoder:fix` reference (~54 files across mirrors). Internal callers MUST use the
  new name so loop iterations don't pay a double model-hop through the alias (B5).
- Update `plugin.json` in every packaging mirror (`.claude-plugin`, `codex-plugins`,
  `.factory-plugin`) and bump the marketplace root version.
- Update the CLAUDE.md parallel-maintenance mapping table.
- Bare `/fix` appears in prose ("fix a bug"); rename command-invocation contexts only —
  careful edits, not a blind sed.

## 7. Issue ↔ spec linkage (reuse `decomposed`/`subtask`)

Bidirectional, reusing the exact convention the auto-close monitor already reads:

- Child → parent: story body header `## Sub-task of #<SPEC>`.
- Parent → children: spec body/comment checklist `- [ ] #<story>`, spec labeled `decomposed`.
- Any follow-up/bug issue spawned while implementing a story likewise references the spec,
  so all work traces to a goal.

**Verified:** `issues-file.py:187,194` emits `.state` = `"CLOSED"`/`"OPEN"` mirroring gh's
JSON, so the existing `Sub-task of #N` auto-close monitor (in `/fix`, moving to `/dev`)
closes parent specs unchanged on **both** file and github backends.

## 8. Reuse map (external skills — NOT replicated here)

- `thorough-brainstorming` / `superpowers:brainstorming` — step 1
- `critical-design-review` + `update-design-doc` — step 3 iterate loop
- `thorough-writing-plans` — optional structural aid for step 4 (not contractually bound)
- `critical-implementation-review` + `update-implementation-plan` — step 4b iterate loop
- `superpowers:subagent-driven-development` / `dispatching-parallel-agents` — already wired
  into the worker/dev-loop path
- Existing autocoder machinery: `decomposed`/`subtask` labels, auto-close monitor, worker
  fleet, `issue-fns.sh`, `add-worker`/`remove-worker`/`start-worker`

## 9. Out of scope (YAGNI)

- No native parent/child field added to either issue backend (convention suffices).
- No new `planner` agent definition file.
- No new `stop-worker` script (scale-down reuses `remove-worker`).
- No change to the worker implementation flow (TDD, progress comments, merge, close already exist).

## 10. Verified assumptions

| Assumption | Evidence | Result |
|---|---|---|
| Auto-close monitor works on file backend, not just gh | `issues-file.py:187,194` emits `.state` CLOSED/OPEN | ✅ Holds |
| `decomposed`/`subtask` labels + `Sub-task of #N` + parent checklist auto-close exist | `commands/fix.md:1205–1354` | ✅ Reused verbatim |
| No native parent field in file backend | `issues-file.py` create/get fields: number,title,priority,labels,status,assignee,body,comments | ✅ Convention required |
| Resume-worker primitive exists | `scripts/start-workers.sh` (`start-worker N`) | ✅ |
| No per-worker pause primitive exists | scripts: add/remove/restart/start-workers/stop-parallel only | ✅ → scale-down uses `remove-worker` (§5) |
| Rename blast radius | ~54 files reference `/fix`,`/fix-loop`,`autocoder:fix` across mirrors | ✅ Scoped as mechanical workstream |
| Manager loop is `/monitor-workers` via `/monitor-loop`; has add-worker(5b)/review-blocked(5c) | `commands/monitor-workers.md`, `commands/monitor-loop.md` | ✅ Extend here |

## 11. Known risks / notes

- **B5 (alias hops):** internal callers must use the new `/dev` name; only human-typed
  legacy names hit the alias stub, else every loop iteration double-hops (token waste).
- **B6 (parent-close race):** two workers closing the last two stories concurrently both
  run the parent-complete check; benign — `issue_close` on an already-closed issue is
  idempotent. No action.
- **B7 (label bootstrap):** `/plan` step 0 must ensure `decomposed`/`subtask` labels exist.

Deferred to `critical-implementation-review` (implementation mechanics, not design defects — flagged by CDR round 1):

- **B8 (doc-to-integration-branch commit):** the plan must specify the exact sequence by
  which `/plan` guarantees the design doc lands on the shared integration branch (checkout
  / commit / push) so worktrees created or rebased afterward contain it. Outcome is fixed
  by §3.2; the mechanism is a plan-level detail.
- **B9 (clean spec-parent body):** the reused auto-close monitor treats *every* `#N` in the
  spec parent body as a story to wait on (`fix.md` greps `#\K[0-9]+`). `/plan` must keep the
  spec parent body limited to the doc pointer + the `- [ ] #<story>` checklist and avoid
  stray issue references, or the spec will never auto-close.

## 12. Implementation workstreams (rough sequencing)

1. **Rename** `/fix`→`/dev`, `/fix-loop`→`/dev-loop` + aliases + repoint internal callers +
   plugin.json/marketplace + CLAUDE.md map + `.agent` mirror. (Mechanical, do first so the
   planning work references the final names.)
2. **`autocoder:planning` skill** + **`/autocoder:plan` command** (§3–§4) + `.agent` mirror.
3. **Manager-loop** backlog-aware suggest-`/plan` + autonomous idle-clean scale-down (§5) +
   `.agent` mirror.
4. Docs: `autocoder-help.md` (+ mirror) documents `/plan` and the scaling ladder.

## 13. Parallel-maintenance requirement

Per CLAUDE.md, every command/skill/script/doc change here MUST be mirrored between the
Claude Code (`plugins/autocoder/…`) and Antigravity (`.agent/…`) trees, and reflected in
the codex/factory packaging mirrors and `plugin.json` command lists where applicable.
