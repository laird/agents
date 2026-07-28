# Autocoder Planning Pipeline + `dev` Rename — Implementation Plan

> **For agentic workers:** REQUIRED: Use `superpowers:subagent-driven-development` to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Source spec:** `docs/specs/2026-07-13-autocoder-planning-pipeline-design.md` (commit SHA: `538c4537618c8c436bb170de42fce82ef66971a8`)

**Goal:** Add a human-gated `/autocoder:plan` command that drives brainstorm → spec → dual critical-review loops → decomposition into linked story issues, and rename `/fix`→`/dev` and `/fix-loop`→`/dev-loop` with aliases — all mirrored across the packaging trees.

**Architecture:** Planning is a new command (no new shipped skill — per user decision at plan time, refining spec §4) that encodes the pipeline and references external skills via the existing optional-skills-prelude. It emits `subtask` story issues linked to a `decomposed` spec issue using the exact convention the existing auto-close monitor already reads. The existing worker fleet (`/dev`, formerly `/fix`) implements the stories unchanged. The manager loop (`/monitor-workers`) gains backlog-aware scale-up-suggestion and idle scale-down.

**Tech stack:** Markdown command/workflow protocol files; bash scripts; `issue-fns.sh` issue abstraction (file + github backends); Claude Code / Antigravity / Codex / Factory packaging mirrors.

---

## File Structure

**Rename (git mv, content edited in place):**
- `plugins/autocoder/commands/fix.md` → `dev.md`; `fix-loop.md` → `dev-loop.md`
- `.agent/workflows/fix.md` → `dev.md`; `fix-loop.md` → `dev-loop.md`

**Create:**
- `plugins/autocoder/commands/fix.md`, `fix-loop.md` — thin alias stubs forwarding to `/dev`, `/dev-loop`
- `.agent/workflows/fix.md`, `fix-loop.md` — same alias stubs (Antigravity)
- `plugins/autocoder/commands/plan.md` — the `/autocoder:plan` pipeline command
- `.agent/workflows/autocoder-plan.md` — Antigravity mirror (distinct name; `plan.md` is modernize's)

**Modify (internal callers → `/dev` / `/dev-loop`):**
- `plugins/autocoder/commands/gate.md`, `dispatch.md`, `monitor-workers.md`
- `plugins/autocoder/scripts/worker-launch-lib.sh`
- `plugins/autocoder/hooks/stop-hook.sh`, `.agent/hooks/stop-hook.sh` (message text only — see Task 2)
- `scripts/check-optional-skills-drift.sh` (hardcoded file paths)
- `plugins/autocoder/scripts/README.md`, `fix-loop-gate.sh` (comments)
- `.agent/workflows/` mirrors of gate/dispatch/monitor-workers
- `plugins/autocoder/commands/autocoder-help.md` + `.agent/workflows/autocoder-help.md` (Task 6)

**Modify (packaging):**
- `.claude-plugin/plugins/autocoder/plugin.json`, `.factory-plugin/plugins/autocoder/plugin.json` — `commands[]` arrays + version
- `codex-plugins/autocoder/skills/autocoder/references/command-mapping.md` + `workflow-map.md`; `./skills/autocoder/references/command-mapping.md` + `workflow-map.md` — Codex/Gemini command references
- `.claude-plugin/marketplace.json`, `.factory-plugin/marketplace.json` — root + autocoder plugin version
- `CLAUDE.md` — parallel-maintenance mapping table (lines 191–192)

## Inherited from spec

Verified by `thorough-brainstorming` at spec-write time (spec §10) and by critical-design-review round 1; trusted as ground truth, NOT re-verified here:

- Auto-close monitor works on both backends — file backend emits `.state` CLOSED/OPEN (`issues-file.py:187,194`).
- `decomposed`/`subtask` labels + `Sub-task of #N` child header + `- [ ] #N` parent checklist + auto-close-parent logic exist (`fix.md:1205–1354`).
- `subtask` is non-blocking/claimable (`issues-file.py:54–62` `BLOCKING_LABELS`; `fix.md:1107`); `decomposed` parents are excluded from claiming (`fix.md:548,554,578`).
- No native parent field in either backend; convention is required.
- Scale-down primitive: `remove-worker` is per-worker; removing an idle+clean worker loses nothing (state in issue tracker).
- Manager loop is `/monitor-workers` (via `/monitor-loop`) with existing add-worker (5b) and review-blocked (5c) steps.

## Verified plan-level assumptions

Newly introduced by this plan and verified at plan-write time:

| # | Category | Assumption | Evidence |
|---|---|---|---|
| 1 | File path | `commands/fix.md` (~1500 lines) and `fix-loop.md` (392 lines) exist to rename | Read both files |
| 2 | File path | `.agent/workflows/fix.md`, `fix-loop.md` exist (plus `.backup` siblings — leave those) | `ls` |
| 3 | File path | `commands/plan.md` and `.agent/workflows/autocoder-plan.md` are free (new files) | `ls` → "No such file or directory" |
| 4 | Collision | `.agent/workflows/plan.md` is **modernize's** `/plan`; flat dir is not plugin-namespaced → autocoder mirror must be `autocoder-plan.md` | `head -5 .agent/workflows/plan.md` = "Create a detailed modernization plan" |
| 5 | Symbol/string | `worker-launch-lib.sh:36` `WORKER_CMD="/autocoder:fix-loop"`, `:45` `WORKER_CMD="/fix-loop"`; `:6` "change it here and callers stay in sync" (single source) | `grep -n WORKER_CMD` |
| 6 | Consumer (Cat 6) | `check-optional-skills-drift.sh:25–32` hardcodes `fix.md`/`fix-loop.md` paths (both mirrors) → breaks on rename unless updated | `grep` |
| 7 | Consumer (Cat 6) | `.claude/fix-loop.local.md` state file has ~10 consumers (stop-hook ×2 mirrors, stop-loop ×2, README ×3, writer, `.agent/scripts/watchdog-fix.sh`) → renaming is high-churn, zero-benefit; **keep the name** | `grep -rn "fix-loop.local.md"` |
| 8 | Internal callers | `autocoder:fix` / `fix-loop` invoked in `gate.md:56`, `dispatch.md:81`, `monitor-workers.md:24,189,195`, `worker-launch-lib.sh:36,45` | `grep -rn "autocoder:fix"` |
| 9 | Packaging | `.claude-plugin` + `.factory-plugin` plugin.json list `commands[]` incl. `fix.md`/`fix-loop.md`; **Codex has no `commands[]`** (skills-dir + `references/command-mapping.md`, `workflow-map.md`) | `grep`/`find` codex + factory plugin.json |
| 10 | Packaging | `.claude-plugin/marketplace.json` root `3.22.0` + autocoder `4.3.0`; `.factory-plugin/marketplace.json` root `3.19.0` + autocoder `4.3.0`; plugin.json version `4.3.0`. `.codex-plugin`/`.agents` marketplaces carry no per-plugin version field | `grep -n version` on all 4 marketplaces |
| 11 | File path | `CLAUDE.md:191–192` are the `/fix`, `/fix-loop` mapping rows | `grep -n "/fix" CLAUDE.md` |
| 12 | Reuse block | Decompose/sub-task issue template + auto-close linking strings to copy live at `fix.md:1225–1354`; optional-skills-prelude at `plugins/shared/optional-skills-prelude.md` | Read `fix.md`, referenced by `fix-loop.md:11` |
| 13 | Manager loop | `monitor-workers.md` has Step 5b (add-worker) and 5c (review-blocked) as insertion neighbors; `remove-worker` script exists | Read `monitor-workers.md:209–240`; `ls scripts/remove-worker.sh` |
| 14 | Commit convention | Repo uses mixed `type: subject` (e.g. `docs:`, `feat:`) and imperative subjects | `git log --oneline -6` |

---

## Tasks

### Task 1: Rename command files + alias stubs (Claude + Antigravity)

**Files:**
- Rename: `plugins/autocoder/commands/fix.md`→`dev.md`, `fix-loop.md`→`dev-loop.md`
- Rename: `.agent/workflows/fix.md`→`dev.md`, `fix-loop.md`→`dev-loop.md`
- Create: `plugins/autocoder/commands/fix.md`, `fix-loop.md`, `.agent/workflows/fix.md`, `fix-loop.md` (stubs)

- [ ] **Step 1: `git mv` the four files** (`fix.md`→`dev.md`, `fix-loop.md`→`dev-loop.md` in both `plugins/autocoder/commands/` and `.agent/workflows/`). Leave `.backup` files untouched.
- [ ] **Step 2: Edit in-file self-references** in the renamed `dev.md` / `dev-loop.md` (both mirrors): title headings ("Fix" → "Dev/Develop"), every `/autocoder:fix`→`/autocoder:dev`, `/autocoder:fix-loop`→`/autocoder:dev-loop`, and prose describing the command as fix-only → "fixes bugs and implements features". **Keep** the `.claude/fix-loop.local.md` state-file path unchanged (assumption #7) — it is internal and shared with unchanged consumers.
- [ ] **Step 3: Write the alias stubs.** Each new `fix.md`/`fix-loop.md` is a short forwarder, e.g.:
```markdown
# /fix — renamed to /dev

`/fix` was renamed to `/dev` (the loop both fixes bugs and implements features).
Run `/autocoder:dev` with the same arguments you passed here. This alias is kept
for convenience and forwards to `/dev`.
```
(and the `/fix-loop`→`/dev-loop` equivalent). Mirror identically in `.agent/workflows/`.
- [ ] **Step 4: Commit**
```bash
git add plugins/autocoder/commands/dev.md plugins/autocoder/commands/dev-loop.md \
        plugins/autocoder/commands/fix.md plugins/autocoder/commands/fix-loop.md \
        .agent/workflows/dev.md .agent/workflows/dev-loop.md \
        .agent/workflows/fix.md .agent/workflows/fix-loop.md
git commit -m "rename /fix→/dev and /fix-loop→/dev-loop with alias stubs"
```

### Task 2: Repoint internal callers to `/dev` (resolves B5)

**Files:**
- Modify: `plugins/autocoder/commands/gate.md`, `dispatch.md`, `monitor-workers.md` + their `.agent/workflows/` mirrors
- Modify: `plugins/autocoder/scripts/worker-launch-lib.sh`
- Modify: `scripts/check-optional-skills-drift.sh`
- Modify: `plugins/autocoder/hooks/stop-hook.sh`, `.agent/hooks/stop-hook.sh`, `plugins/autocoder/scripts/README.md`, `fix-loop-gate.sh` (comment/message text)

- [ ] **Step 1: Repoint dispatch targets** — in `gate.md`, `dispatch.md`, `monitor-workers.md` (and `.agent` mirrors), change every command-invocation `/autocoder:fix`→`/autocoder:dev` and `/autocoder:fix-loop`→`/autocoder:dev-loop`. These are the loop hot-path callers, so they must use the new name (not the alias) to avoid a double model-hop per iteration.
- [ ] **Step 2: Repoint the worker command** — `worker-launch-lib.sh:36` `"/autocoder:fix-loop"`→`"/autocoder:dev-loop"`, `:45` `"/fix-loop"`→`"/dev-loop"`. This is the single source (`:6`) for what workers run.
- [ ] **Step 3: Update the drift checker** — `check-optional-skills-drift.sh:25–26,31–32`: `fix.md`→`dev.md`, `fix-loop.md`→`dev-loop.md` (both `plugins/autocoder/commands/` and `.agent/workflows/` entries), so the optional-skills sync check targets the renamed files.
- [ ] **Step 4: Update prose/comment references** — `hooks/stop-hook.sh` + `.agent/hooks/stop-hook.sh` user-facing messages ("Run /fix-loop…"→"Run /dev-loop…"; **leave `LOOP_STATE_FILE=".claude/fix-loop.local.md"` unchanged**), `scripts/README.md`, `fix-loop-gate.sh` comments. `fix.md:534` reference is inside the now-renamed `dev.md` (handled in Task 1).
- [ ] **Step 5: Verify no stray invocation callers remain**
```bash
grep -rn "autocoder:fix\b\|/fix-loop\b" plugins/autocoder .agent scripts \
  | grep -v "\.backup\|fix-loop.local.md\|renamed to\|alias" || echo "clean"
```
- [ ] **Step 6: Commit**
```bash
git add plugins/autocoder/commands/gate.md plugins/autocoder/commands/dispatch.md \
        plugins/autocoder/commands/monitor-workers.md plugins/autocoder/scripts/worker-launch-lib.sh \
        scripts/check-optional-skills-drift.sh plugins/autocoder/hooks/stop-hook.sh \
        plugins/autocoder/scripts/README.md plugins/autocoder/scripts/fix-loop-gate.sh \
        .agent/workflows/gate.md .agent/workflows/dispatch.md .agent/workflows/monitor-workers.md \
        .agent/hooks/stop-hook.sh
git commit -m "repoint internal callers to /dev and /dev-loop"
```

### Task 3: Packaging — plugin.json, command references, versions

**Files:**
- Modify: `.claude-plugin/plugins/autocoder/plugin.json`, `.factory-plugin/plugins/autocoder/plugin.json`
- Modify: `codex-plugins/autocoder/skills/autocoder/references/command-mapping.md` + `workflow-map.md`; `./skills/autocoder/references/command-mapping.md` + `workflow-map.md`
- Modify: `.claude-plugin/marketplace.json`, `.factory-plugin/marketplace.json`

- [ ] **Step 1: Update `commands[]` arrays** (Claude + Factory plugin.json): rename the `fix.md`/`fix-loop.md` entries to `dev.md`/`dev-loop.md`, and **add** `fix.md`/`fix-loop.md` back as alias entries (so both resolve). Also add the new `plan.md` entry (Task 5 creates the file; registering it here or in Task 5 is fine — do it in Task 5's commit if the file doesn't exist yet, to avoid a dangling reference).
- [ ] **Step 2: Update Codex/Gemini command references** — in both `command-mapping.md` and `workflow-map.md` (codex-plugins + top-level `./skills/autocoder/`), rename fix/fix-loop entries to dev/dev-loop, note the aliases.
- [ ] **Step 3: Bump versions** — autocoder plugin version `4.3.0`→`4.4.0` in `.claude-plugin/plugins/autocoder/plugin.json`, `.factory-plugin/plugins/autocoder/plugin.json`, and the `plugins[].version` entries in `.claude-plugin/marketplace.json` + `.factory-plugin/marketplace.json`; bump the marketplace root `version` in both (`.claude-plugin` `3.22.0`→`3.23.0`, `.factory-plugin` `3.19.0`→`3.20.0`), per CLAUDE.md's version-management rule.
- [ ] **Step 4: Commit**
```bash
git add .claude-plugin/plugins/autocoder/plugin.json .factory-plugin/plugins/autocoder/plugin.json \
        codex-plugins/autocoder/skills/autocoder/references/command-mapping.md \
        codex-plugins/autocoder/skills/autocoder/references/workflow-map.md \
        skills/autocoder/references/command-mapping.md skills/autocoder/references/workflow-map.md \
        .claude-plugin/marketplace.json .factory-plugin/marketplace.json
git commit -m "register /dev,/dev-loop rename across packaging mirrors; bump autocoder to 4.4.0"
```

### Task 4: Update CLAUDE.md parallel-maintenance mapping

**Files:** Modify: `CLAUDE.md:191–192`

- [ ] **Step 1: Edit the mapping rows** — replace the `/fix` and `/fix-loop` rows with `/dev`: `plugins/autocoder/commands/dev.md ↔ .agent/workflows/dev.md` and `/dev-loop` equivalent; add a note that `/fix`, `/fix-loop` remain as alias stubs mirrored on both sides. Add a `/plan` row (`plugins/autocoder/commands/plan.md ↔ .agent/workflows/autocoder-plan.md`).
- [ ] **Step 2: Commit**
```bash
git add CLAUDE.md
git commit -m "update parallel-maintenance map for /dev,/dev-loop,/plan"
```

### Task 5: Create the `/autocoder:plan` command

**Files:**
- Create: `plugins/autocoder/commands/plan.md`, `.agent/workflows/autocoder-plan.md`
- Modify: `plugins/autocoder/commands/dev.md` (auto-close monitor — child-marker enumeration)
- Modify: `.claude-plugin/plugins/autocoder/plugin.json`, `.factory-plugin/plugins/autocoder/plugin.json` (register `plan.md`)

- [ ] **Step 1: Author `commands/plan.md`.** Start from the optional-skills-prelude block (copy the prelude pattern from an existing command, e.g. the header of `dev-loop.md`) with a mapping table referencing external skills:

| Step | Skill mapping |
|---|---|
| Brainstorm the goal | `thorough-brainstorming` (fallback `superpowers:brainstorming`) |
| Spec critical-review loop | `critical-design-review` → `update-design-doc` |
| Story critical-review loop | `critical-implementation-review` → `update-implementation-plan` |

Then encode the pipeline inline (steps 0–6 from spec §3):
  - Step 0: ensure `decomposed`/`subtask` labels exist (reuse the label-bootstrap block from `dev.md`, formerly `fix.md:442`).
  - Step 1: brainstorm → design doc under `docs/specs/`; **human approves**; commit the doc onto the configured integration branch (`CLAUDE_CODE_INTEGRATION_BRANCH`, default `main`/`master`) **without switching the manager's working tree** (resolves spec B8 + CIR §3.1): build the commit against the integration branch's tree via git plumbing (`git commit-tree` with the integration branch as parent, then `git update-ref refs/heads/<integration>`), so the doc lands on the branch worktrees derive from regardless of the manager's current branch.
  - Step 2: `issue_create` the spec issue — body = pointer to the doc path (no story checklist in the body; the auto-close monitor no longer reads the parent body — see Step 1b and Step 5).
  - Step 3: spec critical-review loop — `critical-design-review`→`update-design-doc`, stop on empty pass or after 3 passes (spec §3.1); post each pass summary as a spec-issue comment.
  - Step 4: decompose into 3–8 stories.
  - Step 4b: story critical-review loop — `critical-implementation-review`→`update-implementation-plan`, same cap-3 termination (spec §3.4); **human approves** the breakdown.
  - Step 5: `issue_create` each story — labels `subtask` + priority, body header `## Sub-task of #<SPEC>` (exact string — this child-side marker is the authoritative parent link the monitor enumerates by, per Step 1b), acceptance criteria + design context; label the spec issue `decomposed` and post the `- [ ] #<story>` checklist as a **comment** on the spec issue for human visibility (not the body). Copy the issue-body template shape from `dev.md` (formerly `fix.md:1225–1275`).
  - Step 6: document hand-off — note that the worker fleet running `/dev-loop`→`/dev` will pull the `subtask` stories and that the existing monitor auto-closes the spec when all stories close.
  Use `issue-fns.sh` (`issue_create`, `issue_comment`, `issue_update`) with the same `SCRIPT_DIR` resolution block used by `brainstorm-issue.md:57–63`.
- [ ] **Step 1b: Modify the auto-close monitor in `dev.md`** (formerly `fix.md:1319–1327`) so it enumerates a spec's stories by the authoritative child-side marker instead of the parent body (resolves CIR §2.1): replace `PARENT_SUBTASKS=$(issue_get "$PARENT_ISSUE" | jq -r '.body' | grep -oP '#\K[0-9]+')` with a scan that lists issues (`issue_list --state all`) and selects those whose body contains `Sub-task of #<PARENT>`; and **add a guard that skips closing the parent when zero children are found** (fixes the premature-close bug: an empty enumeration previously left `ALL_CLOSED=true` and closed the parent immediately). This makes auto-close independent of the parent-issue body — no body edit is ever required.
- [ ] **Step 2: Mirror to `.agent/workflows/autocoder-plan.md`** (identical content; Antigravity skill-activation note per the prelude, matching how other workflow mirrors differ).
- [ ] **Step 3: Register `plan.md`** in the `commands[]` arrays of `.claude-plugin` + `.factory-plugin` plugin.json, and in the Codex/Gemini `command-mapping.md` + `workflow-map.md` references.
- [ ] **Step 4: Commit**
```bash
git add plugins/autocoder/commands/plan.md plugins/autocoder/commands/dev.md .agent/workflows/autocoder-plan.md \
        .claude-plugin/plugins/autocoder/plugin.json .factory-plugin/plugins/autocoder/plugin.json \
        codex-plugins/autocoder/skills/autocoder/references/command-mapping.md \
        codex-plugins/autocoder/skills/autocoder/references/workflow-map.md \
        skills/autocoder/references/command-mapping.md skills/autocoder/references/workflow-map.md
git commit -m "add /autocoder:plan planning-pipeline command"
```

### Task 6: Manager-loop backlog-aware behaviors + help docs

**Files:**
- Modify: `plugins/autocoder/commands/monitor-workers.md` + `.agent/workflows/monitor-workers.md`
- Modify: `plugins/autocoder/commands/autocoder-help.md` + `.agent/workflows/autocoder-help.md`

- [ ] **Step 1: Add the backlog-low → suggest-`/plan` step** to `monitor-workers.md` (near Step 5b): when unblocked+in-progress work is low relative to worker count and no planning is in flight, print a suggestion recommending `/autocoder:plan "<goal>"`. Human-gated (a printed suggestion, not an autonomous action).
- [ ] **Step 2: Add the idle scale-down step** (near Step 5c): when there is no claimable work AND a worker is idle AND its worktree is clean (no claimed issue / no uncommitted changes), run `remove-worker N` to stop token burn; scale back up with `add-worker` when work reappears. Explicitly guard: never auto-remove a worker with a claimed issue or uncommitted changes.
- [ ] **Step 3: Mirror both steps** to `.agent/workflows/monitor-workers.md`.
- [ ] **Step 4: Document** `/autocoder:plan` and the full scaling ladder in `autocoder-help.md` + its `.agent` mirror.
- [ ] **Step 5: Commit**
```bash
git add plugins/autocoder/commands/monitor-workers.md .agent/workflows/monitor-workers.md \
        plugins/autocoder/commands/autocoder-help.md .agent/workflows/autocoder-help.md
git commit -m "manager loop: suggest /plan on low backlog, scale down idle workers"
```

## Tasks NOT in this plan

Inherited from spec §9 (a new spec → new plan cycle is required to add any of these):

- No native parent/child field added to either issue backend (convention suffices).
- No new `planner` agent definition file.
- No new `stop-worker` script (scale-down reuses `remove-worker`).
- No change to the worker implementation flow (TDD, progress comments, merge, close already exist).

Additional plan-level scope exclusions (verified during planning):

- **State file NOT renamed** — `.claude/fix-loop.local.md` stays (assumption #7): ~10 consumers across mirrors, zero functional benefit.
- **Script filenames NOT renamed** — `fix-loop-gate.sh`, `.agent/scripts/watchdog-fix.sh`, `run-phase-experiment.sh` keep their names; only their command-invocation comments change. Renaming script files is out-of-scope churn the spec didn't ask for.
- **`.codex-plugin` / `.agents` marketplaces** carry no per-plugin version field (assumption #10) — no version edit needed there.

## Known issues inherited from spec

From spec §11 (deferred to this implementation and its review):

- **B6 (parent-close race):** two workers closing the last two stories concurrently both run the parent-complete check; benign — `issue_close` on an already-closed issue is idempotent. No action.
- **B8 (doc-to-integration-branch commit):** addressed in Task 5 Step 1 (commit the doc onto the integration branch via git plumbing — `commit-tree` + `update-ref` — without switching the manager's working tree; CIR §3.1).
- **B9 (clean spec-parent body):** moot — the auto-close monitor now enumerates stories via the child-side `Sub-task of #<SPEC>` marker (Task 5 Step 1b), so stray `#N` in the spec issue body no longer affects auto-close.
