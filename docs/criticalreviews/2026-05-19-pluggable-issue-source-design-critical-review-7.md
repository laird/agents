# Critical Design Review: 2026-05-19-pluggable-issue-source-design (Round 7)

**Spec:** `docs/superpowers/specs/2026-05-19-pluggable-issue-source-design.md`
**Verified Assumptions section:** MISSING

> ⚠️ This spec lacks a `Verified assumptions` section. Reviewer cannot distinguish verified facts from unverified assumptions; treat findings accordingly.

---

## 1. Verified-assumptions cross-check

Section omitted — spec has no `Verified assumptions` section.

---

## 2. Literal-wrongness findings

### 2.1 Backend contract `update` uses pipe syntax implying mutually exclusive flags — but `/update-issue` requires combining two flags simultaneously

**Description:** The Section 4 backend contract shows:

```
update   <number> --add-label L | --remove-label L | --status S | --assignee A
```

The `|` notation reads as "exactly one of these options." But Section 3's `/update-issue` command explicitly demonstrates this valid usage:

```
/update-issue 42 --remove-label working --add-label needs-approval
```

That call maps to `issue_update 42 --remove-label working --add-label needs-approval` — two flags in one call. A custom backend implemented from the Section 4 contract alone would parse `update` as accepting one flag at a time and break on combined invocations. The `issues-file.py` subcommand table correctly uses bracket notation (`[--add-label L] [--remove-label L] [--status S] [--assignee A]`), showing all are composable, but this contradicts the Section 4 contract table.

**Evidence:** Section 4 backend contract `update` row uses `|` separators. Section 3 `/update-issue` examples show `--remove-label working --add-label needs-approval` as a single call. Section 3 `issues-file.py update` subcommand uses bracket notation for the same flags.

**Proposed fix:** Change the Section 4 backend contract `update` row to bracket notation matching `issues-file.py` and the function signature: `<number> [--add-label L] [--remove-label L] [--status S] [--assignee A]`.

---

### 2.2 `issue_update --assignee A` has no specified GitHub backend translation

**Description:** The `issue_update` function signature (Section 3) includes `[--assignee A]`. The Section 4 backend contract includes `--assignee A` in the `update` row. No translation is specified for `--assignee` when the GitHub backend is active — the `--status` translation table (added in CDR-4) covers only `--status` values.

`gh issue edit` has no `--assignee` flag. Its closest equivalents are `--add-assignee <login>` and `--remove-assignee <login>`, which take a GitHub username — not a worktree name (e.g., `feat-login`). If `issue-fns.sh` passes `--assignee feat-login` through to `gh issue edit`, the command fails with an unrecognized flag.

The `assignee` field is a file-backend concept — a worktree name used as a distributed-lock owner identifier. On GitHub, issue ownership is tracked via the `working` label (already specified). There is no meaningful GitHub equivalent for worktree-name-as-assignee.

**Evidence:** Section 3 `issue_update` signature includes `[--assignee A]`. Section 3 `--status` translation table covers `status` only — no `assignee` row. Section 4 backend contract `update` row includes `--assignee A`. `gh issue edit --help` shows `--add-assignee` / `--remove-assignee`, not `--assignee`; both take GitHub logins, not worktree names.

**Proposed fix:** Declare `--assignee` as file-backend-only: add a note to the `issue-fns.sh` description stating that `issue-fns.sh` strips `--assignee` when the GitHub backend is active (GitHub ownership is already tracked via the `working` label). Update the backend contract note to match, and remove `--assignee` from the Section 4 `update` row (since the GitHub backend, the reference implementation alongside `issues-file.py`, does not support it and custom backends would be confused by a flag that only one built-in backend uses).

---

## 3. Forced decisions

No forced decisions found.

---

## 4. Previously addressed

- **CDR-6 2.1 (`issues-file.py list` missing `[--limit N]`)** — Fully resolved. Section 3 `issues-file.py list` subcommand now includes `[--limit N]`, matching the backend contract and `issue_list` signature.

---

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes** — §3 is empty. Two fixes needed: (1) change the Section 4 backend contract `update` row from pipe to bracket notation; (2) declare `--assignee` file-backend-only and specify that `issue-fns.sh` strips it for the GitHub backend. Both are one-paragraph additions/edits. Spec is ready for implementation planning once addressed.
