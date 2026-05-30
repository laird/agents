# Critical Implementation Review: 2026-05-22-issue-storage-and-backend-abstraction-implementation-plan (Round 1)

**Plan:** `/Users/Laird.Popkin/src/agents/docs/plans/2026-05-22-issue-storage-and-backend-abstraction-implementation-plan.md`
**Verified plan-level assumptions section:** present (19 items)

No drift (plan spec SHA `c0b3df6` is reachable; only commit since is the plan commit itself, `c2b8066`).

## 1. Verified-plan-assumptions cross-check

| # | Result |
|---|---|
| 1 | Still holds. `plugins/autocoder/scripts/issues-gh.sh` absent. |
| 2 | Still holds. `plugins/autocoder/scripts/README.md` absent. |
| 3 | Still holds. `plugins/autocoder/commands/show-issue.md` absent. |
| 4 | Still holds. `plugins/autocoder/commands/migrate-issues-layout.md` absent. |
| 5 | Still holds (literal text). `--if-unset` callers outside `issues-file.py` declaration site = `fix-loop-gate.sh:159` only. But see §2.3: the related `--add-label working` (without `--if-unset`) is called from many more sites, and the plan's Task 1 Step 7 changes their behavior without enumerating them. |
| 6 | Still holds. `parse_issue_file`/`write_issue_file` only called inside `issues-file.py`. |
| 7 | Still holds. Confirmed against current files; same line numbers. |
| 8 | Still holds. Backend scripts plugin-only. |
| 9 | Still holds. `.agent/scripts/README.md` exists with unrelated content. |
| 10 | Still holds. `.agent/workflows/list-needs-feedback.md:42` and `.agent/workflows/monitor-workers.md:82,261` mirror plugin versions at same lines. |
| 11 | Still holds. pytest, no `package.json`. |
| 12 | Still holds. `tests/test_issues_file_if_unset.py` is `--if-unset`-dedicated. |
| 13 | **Partially failed.** The assumption states "lowercase, no Conventional-Commits scope," but `git log --format=%s -10` shows scoped commits already coexist (`docs(spec):`, `docs(autocoder):`, `chore(issues):`). The codebase uses scopes *optionally*; both with-scope and without-scope commits are valid. The plan's own task commits use scopes (`feat(issues-file):`, `refactor(issue-fns):`, etc.), which is consistent with the codebase's actual mixed style — but the assumption text understates the convention. No behavioral consequence for plan execution; flag here for accuracy. |
| 14 | Still holds. POSIX rename behavior. |
| 15 | Still holds. Verified. |
| 16 | Still holds. Logical ordering claim, intact. |
| 17 | Still holds. Logical ordering claim, intact. |
| 18 | Still holds. Mirror is a copy operation. |
| 19 | Still holds. `git log -1 --format=%H -- <spec>` → `c0b3df6` matches header. |

## 2. Literal-wrongness findings

### 2.1 Task 1 Step 7's code block references the undefined variable `src`

**Description.** Step 7's Python snippet for blocking-label transitions inside `cmd_update` includes:

```python
# After write_issue_file_fd(f, data) and before unlock:
current_bucket = src.parent.name
```

But Step 7 never defines `src`. `src` is only defined locally in Steps 5 (`cmd_claim`) and 6 (`cmd_release`) — different functions. The new `cmd_update` should obtain the path via `resolve_path(issues_dir, args.number)` (per Step 9), but Step 9 lists `cmd_get`, `cmd_comment`, `cmd_close` — **not** `cmd_update`. An implementer following the plan literally hits `NameError: name 'src' is not defined`.

**Evidence.** Plan §Task 1 Step 7 code block; Step 9's explicit list of `resolve_path` consumers; the absence of `src = ...` anywhere in Step 7's code.

**Proposed fix.** Either:
- Add `cmd_update` to Step 9's "use `resolve_path(issues_dir, args.number)`" list and replace `src` in Step 7 with `path` (or whatever variable Step 9's update structure names the resolved path), OR
- Make Step 7's code block self-contained by prefacing it with `bucket, src = resolve_path(issues_dir, args.number)` and showing the surrounding `with open(src, "r+") as f:` structure inline.

The second is clearer for a one-task review surface. Either way, Step 9's enumeration must include `cmd_update`.

---

### 2.2 Banning `update --add-label working` on `open/` breaks existing callers the plan didn't enumerate

**Description.** Task 1 Step 7 instructs: *"Add an explicit error if `--add-label working` is called on an `open/` issue — that path is gone; use `claim` instead. Exit 2 (usage error)."* This is presented as if `fix-loop-gate.sh:159` (which the plan migrates in Task 5) is the only caller. It isn't:

- `plugins/autocoder/scripts/fix-loop-gate.sh:166` — `issue_update "$ISSUE_NUM" --add-label working 2>/dev/null || true` (the post-claim re-assert that keeps the label set even if the primary claim path varies between backends)
- `plugins/autocoder/commands/fix.md:553` — `issue_update "$ISSUE_NUM" --add-label "working" 2>/dev/null || true`
- `plugins/autocoder/commands/fix.md:1506` — `issue_update "$ENHANCE_NUM" --add-label "working" 2>/dev/null || true`
- `.agent/workflows/fix.md:553`, `:1506` — the mirrored copies
- Internal: `plugins/autocoder/scripts/issue-fns.sh:49` (inside `_ifns_gh_update`'s `working) gh issue edit "$number" --add-label "working" ;;` branch — this moves into `issues-gh.sh` in Task 2 but the semantic equivalent persists)

When Step 7 lands and Task 6 doesn't migrate these callsites, every successful `/fix` iteration would hit `exit 2` from one of fix.md:553 or fix.md:1506, and `fix-loop-gate.sh:166` would also error. The spec's outcome (autonomous fix loop processes issues end-to-end) fails on the first iteration.

**Evidence.** `grep -rn "add-label working\|add-label \"working\"" plugins/ .agent/` returns the citations above; Task 1 Step 7 declares the new behavior; Task 6 doesn't list `fix.md` or these specific callsites among the files to migrate.

**Proposed fix.** Pick one:
- (a) Drop the "exit 2 on `--add-label working` in `open/`" rule from Step 7. `update --add-label working` remains supported on any bucket as a legacy/idempotent label-set; `claim` is the *atomic* path. The two coexist. (Simplest. Recommended.)
- (b) Keep the rule and extend Task 6 to migrate `fix.md:553,1506` and `fix-loop-gate.sh:166` (plus `.agent/workflows/fix.md` mirrors) to use `issue_claim` (or to drop the redundant re-label since claim already sets the label).

(a) is smaller and avoids touching fix.md beyond Task 3. (b) is internally tidier but expands Task 6.

---

### 2.3 Task 6 Step 2's monitor-workers simplification under-specifies — only one of three lines is shown, and applying the shown form to all three produces wrong output

**Description.** Task 6 Step 2 instructs to simplify the blocking-label jq filter on monitor-workers.md lines 79, 130, 262, and gives one example:

```bash
issue_list --state open | jq -r 'sort_by(.labels | map(select(.name | test("^P[0-3]$"))) | .[0].name // "P9") | .[].number'
```

This is correct for line 130 (which returns priority-sorted numbers). It is **not** correct for the other two:

- **Line 79** (`# Open unblocked issues`): the current query produces `"#42: Title"` per-issue display strings — no priority sort, no number-only output. Applying the shown simplification would change the displayed format from `#N: Title` to bare numbers and add a sort.
- **Line 262** (`UNBLOCKED=$(... | jq '[...] | length')`): the current query returns a *count*. Applying the shown simplification would assign a JSON array of numbers to `UNBLOCKED`, then `[ "$UNBLOCKED" -gt 0 ]` later in the monitor loop would error with a syntax message.

An implementer reading the single example and applying it to all three sites breaks both line 79's display and line 262's count semantics.

**Evidence.** `sed -n '78,80p' plugins/autocoder/commands/monitor-workers.md` and `sed -n '260,263p' plugins/autocoder/commands/monitor-workers.md` show the actual queries — distinctly shaped (display vs. sort vs. count).

**Proposed fix.** Task 6 Step 2 should show three explicit replacements, one per line. Specifically:

- Line 79 (display):
  ```bash
  issue_list --state open | jq -r '.[] | "#\(.number): \(.title)"'
  ```
- Line 130 (priority-sorted numbers — keep the shown form):
  ```bash
  issue_list --state open | jq -r 'sort_by(.labels | map(select(.name | test("^P[0-3]$"))) | .[0].name // "P9") | .[].number'
  ```
- Line 262 (count):
  ```bash
  UNBLOCKED=$(issue_list --state open | jq 'length')
  ```

Mirror to `.agent/workflows/monitor-workers.md` in Task 8.

---

### 2.4 Plan testing coverage omits two tests the source spec's Testing plan calls for

**Description.** Spec §Testing plan enumerates six test cases. The plan picks up four explicitly (round-trip, label ops, claim semantics, comment append, empty-case, non-empty-case — Section E; plus migration, race-3, blocking-transitions, parallel-claim in Task 1 Step 10). The two omitted are:

- **End-to-end fix-loop over empty `open/` for 30 s** asserting no LLM invocations occurred (spec §Testing plan, last bullet). Not in any task.
- **Cross-worktree end-to-end** — secondary worktree invoking `issue_list`, `issue_claim`, `issue_release`, `issue_close` and asserting all operations affect the main worktree's `.issues/` directory (spec §Testing plan, second-to-last bullet). Not in any task.

Without these, the plan ships without verifying Goal #2 (zero-cost idle preflight actually skips LLM) and Goal #5 (cross-worktree coordination actually works). The spec's outcome (functioning fix-loop in a parallel-worktree environment with no LLM cost on idle) is asked-for but not verified by this plan.

**Evidence.** Spec at `docs/superpowers/specs/2026-05-22-issue-storage-and-backend-abstraction-design.md` lines 400–401 (testing-plan section); plan Task 1 Step 10 and Task 8 omit them.

**Proposed fix.** Add two test items to Task 1 Step 10 (or a dedicated test task), with the existing `tests/` directory convention:

- `tests/test_issues_file_cross_worktree.sh` (or `.py`) — creates a temp git repo, adds a secondary worktree via `git worktree add`, runs `issue_*` commands from inside the secondary worktree, asserts files appear in the main worktree's `.issues/` directory and `ISSUE_DIR_PATH` resolves identically from both.
- `tests/test_fix_loop_idle.sh` — starts `fix-loop` against a temp `.issues/` with empty `open/`, runs for ~30 s with a tight `INTERVAL`, asserts the `/fix` sub-process was never spawned (e.g., counts a marker file `/fix` would touch).

These should be added as steps in Task 1 (or a new step in Task 3, since fix-loop is the consumer) before each task's "Commit" step.

---

### 2.5 Task 3 Step 1's reference to "the first executable bash block (currently around line 350)" is wrong; the first block is at line 276 — risks insertion at the wrong place

**Description.** Task 3 Step 1 says: *"Identify the first executable bash block in `fix.md` (currently the CLAUDE.md-reading block at around line 350). Insert this block above it, right after the SCRIPT_DIR resolution."* The actual first executable bash block is at `fix.md:276` (SCRIPT_DIR setup), and `source "${SCRIPT_DIR}/issue-fns.sh"` is at line 282 — both well above the CLAUDE.md-reading block at ~line 350. The instruction "right after the SCRIPT_DIR resolution" is correct (the preflight goes between line 282 and line 350); the "line 350" reference is a red herring that may lead an implementer to insert below the CLAUDE.md block, which is *after* the GitHub-only setup blocks the plan wants the preflight to precede.

Additionally, the proposed preflight block re-sources `issue-fns.sh` despite line 282 having done so. That's idempotent at runtime (`issue-config.sh` guards on `$ISSUE_SOURCE`), but the duplication is confusing in the diff.

**Evidence.** `grep -n "SCRIPT_DIR\|source.*issue-fns" plugins/autocoder/commands/fix.md` shows lines 276 (SCRIPT_DIR), 282 (source). Plan Task 3 Step 1 prose.

**Proposed fix.** Rephrase Step 1: *"Insert the preflight block immediately after `source "${SCRIPT_DIR}/issue-fns.sh"` (currently `fix.md:282`) and before the CLAUDE.md-reading block (currently `fix.md:~286`). Do not duplicate the `source` line; the preflight starts with `issue_any_claimable`."* Remove the `source` line from the inserted block. (The GitHub-only setup blocks at lines 368–419 still move below the preflight — that part is correct.)

## 3. Forced decisions

No forced decisions found.

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes**

§1 has one partial failure (assumption #13's commit-convention text, no behavioral impact). §2 has five findings, all spec-execution-time bugs the plan introduces or omits. §3 is empty. After 2.1–2.5 are addressed (recommend handling 2.2 via Option (a) for smallest blast radius), the plan is ready for `subagent-driven-development` via `update-implementation-plan` or direct edits.
