# Critical Design Review: 2026-05-19-pluggable-issue-source-design (Round 3)

**Spec:** `docs/superpowers/specs/2026-05-19-pluggable-issue-source-design.md`
**Verified Assumptions section:** MISSING

> ⚠️ This spec lacks a `Verified assumptions` section. Reviewer cannot distinguish verified facts from unverified assumptions; treat findings accordingly.

---

## 1. Verified-assumptions cross-check

Section omitted — spec has no `Verified assumptions` section.

---

## 2. Literal-wrongness findings

### 2.1 File backend distributed lock breaks when callers use `--add-label working`

**Description:** The distributed locking guarantee in Section 2 states: "Setting `status: working` + `assignee: <worktree-name>` is done atomically under the lock, claiming an issue for one agent at a time." Agents skip issues where `status != open`.

The migration (Section 3) translates existing `gh issue edit "$ISSUE_NUM" --add-label "working"` calls (confirmed in `fix.md` lines 539 and 1480) to `issue_update N --add-label working`. The file backend's `update` subcommand accepts `[--add-label L]` — it adds a label to the `labels:` YAML list. It does not set `status: working` in the YAML frontmatter. These are two separate fields.

After migration, an agent claiming an issue calls `issue_update N --add-label working`. On the file backend, this adds `working` to `labels:` but leaves `status: open`. Other agents calling `issue_list` see `status: open` and attempt to claim the same issue. The distributed lock is broken.

**Evidence:** `fix.md:539` and `:1480` show `gh issue edit "$ISSUE_NUM" --add-label "working"` as the claim operation. Section 2 Field Reference defines `status: open | working | closed` as the distributed lock field. The `update` subcommand spec does not describe any coupling between `--add-label working` and `status: working`.

**Proposed fix:** Specify that the file backend treats the `working` label specially: `--add-label working` atomically sets both `labels: [working]` and `status: working`; `--remove-label working` sets `status: open`. Add this coupling explicitly to the `issues-file.py` subcommand description in Section 3 and to the ISSUES.md format in Section 2.

---

## 3. Forced decisions

No forced decisions found.

---

## 4. Previously addressed

From CDR-1:
- **2.1 `flock` not available on macOS** — Fully resolved. Section 3 now specifies `fcntl.flock(fd, fcntl.LOCK_EX)` from Python's standard library. Both Sections 2 and 3 use consistent language.
- **2.2 ISSUES.md separator `---` ambiguity** — Fully resolved. Format now uses `<!-- issue -->` / `<!-- /issue -->` tags as unambiguous issue boundaries.
- **2.3 Migration scope understated** — Fully resolved. Section 3 now lists all 13 in-scope files with a rule covering all current and future additions.
- **2.4 Inconsistent worktree command** — Fully resolved. All occurrences now use `git worktree list --porcelain | grep -m1 "^worktree" | cut -d' ' -f2`.
- **2.5 `--priority` unhandled by GitHub backend** — Fully resolved. Section 4 backend contract accepts only `--label`; `issue-fns.sh` translates `--priority` before dispatch; `issues-file.py` subcommand table also updated.
- **3.1 Non-interactive detection hang** — Fully resolved. Fail-fast with clear error when no TTY and no cached config.

From CDR-2:
- **2.1 `issues-file.py create` still listed `[--priority P]`** — Fully resolved. Subcommand table now shows `--label L` only with a note that priority arrives pre-translated.
- **2.2 Section 3 `issues-file.py` description said "Uses `flock`"** — Fully resolved. Now reads "Uses Python's `fcntl.flock(fd, fcntl.LOCK_EX)`."

---

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes** — §3 is empty. One targeted fix is needed: specify in Section 2 and Section 3 that the file backend treats `--add-label working` as atomically setting `status: working`, and `--remove-label working` as setting `status: open`. This is a one-paragraph addition. Spec is ready for implementation planning once addressed.
