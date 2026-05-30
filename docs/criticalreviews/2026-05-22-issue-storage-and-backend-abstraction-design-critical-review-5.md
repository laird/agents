# Critical Design Review: 2026-05-22-issue-storage-and-backend-abstraction-design (Round 5)

**Spec:** `/Users/Laird.Popkin/src/agents/docs/superpowers/specs/2026-05-22-issue-storage-and-backend-abstraction-design.md`
**Verified Assumptions section:** present

## 1. Verified-assumptions cross-check

Sanity-checked each item against cited evidence in commit `c0b3df6`:

| # | Result |
|---|---|
| 1 | Still holds. `plugins/autocoder/scripts/issue-config.sh` exists; main-worktree resolution intact. |
| 2 | Still holds. `issue-fns.sh` exposes the listed `issue_*` functions. |
| 3 | Still holds. `issues-file.py` is the file backend. |
| 4 | Still holds. `.agent/scripts/` and `.agent/workflows/` mirror the plugin paths. |
| 5 | Still holds. `parse_issue_file:54-56` and `write_issue_file:87-100` re-open by path. |
| 6 | Still holds. `--if-unset` + `sys.exit(9)` confirmed at the cited lines. |
| 7 | Still holds. `cmd_create` globs `*.md` for max; `.seq` is a lock sentinel only. |
| 8 | Still holds. `_ifns_gh_list/update/close/create` declared at the cited lines. |
| 9 | Still holds. `monitor-workers.md` queries at the cited lines. |
| 10 | Still holds. `list-needs-design/feedback/proposals` use `--state open --label`. |
| 11 | Still holds. `monitor-workers.md:130` omits `needs-feedback`. |
| 12 | Still holds. `fix-loop-gate.sh` exists. |
| 13 | Still holds. `fix.md`, `fix-loop.md`, `set-issue-source.md` exist. |
| 14 | Still holds. `gh` 2.92.0 present. |
| 15 | Still holds. `git worktree list --porcelain` lists main first in this repo. |
| 16 | Still holds. `working` is both label and status in the schema. |
| 17 | Still holds. `proposal` is in the existing blocking-label filter. |
| 18 | Still holds. POSIX guarantee; same-filesystem invariant intact. |
| 19 | Still holds. `fcntl.flock` works on the target platforms; already in use. |
| 20 | Still holds. GitHub label-add idempotency is documented. |
| 21 | Still holds. `find -maxdepth 1 -name -print -quit` is in the POSIX/BSD/GNU shared subset. |

All 21 reconfirmed.

## 2. Literal-wrongness findings

No literal-wrongness findings.

## 3. Forced decisions

No forced decisions found.

## 4. Previously addressed

- **Round 1 findings 2.1, 2.2, 2.3, 2.4** resolved in commit `3dbe749` (recorded in round 2's §4).
- **Round 2 findings 2.1–2.5** resolved in commit `a6a2551` (recorded in round 3's §4).
- **Round 3 finding 3.1** resolved in commit `0f38f04` (recorded in round 4's §4).
- **Verified-assumptions section absence** (warned-on in rounds 1–4) resolved in commit `c0b3df6` by adding the section with 21 verified items.

## 5. Recommendation

✅ **Approve as-is**

§2 and §3 are both empty; all 21 verified assumptions reconfirm. Spec is ready for implementation planning via `thorough-writing-plans`.
