# Critical Design Review: 2026-05-19-pluggable-issue-source-design (Round 6)

**Spec:** `docs/superpowers/specs/2026-05-19-pluggable-issue-source-design.md`
**Verified Assumptions section:** MISSING

> ⚠️ This spec lacks a `Verified assumptions` section. Reviewer cannot distinguish verified facts from unverified assumptions; treat findings accordingly.

---

## 1. Verified-assumptions cross-check

Section omitted — spec has no `Verified assumptions` section.

---

## 2. Literal-wrongness findings

### 2.1 `issues-file.py list` is missing `[--limit N]` — inconsistent with backend contract and `issue_list` signature

**Description:** The backend contract (Section 4) specifies:

```
list   [--label L] [--state open|closed] [--limit N]  → JSON array
```

The `issue_list` function signature (Section 3 `issue-fns.sh` table) is:

```
issue_list [--label L] [--state S] [--limit N] [--priority P]
```

`issue-fns.sh` forwards these args to the configured backend. But the `issues-file.py` subcommand table (Section 3) shows:

```
list [--label L] [--state open|closed]
```

No `--limit N`. When an agent calls `issue_list --limit 10` with the file backend, `issues-file.py` receives `list --limit 10` and either exits with an unrecognized-argument error (breaking the caller) or silently ignores `--limit` and returns all issues (breaking callers that rely on the limit for batch-size control — `fix.md` uses `--limit` to bound the set of issues it processes per run).

**Evidence:** Section 3 `issues-file.py` subcommand table (`list [--label L] [--state open|closed]`) vs. Section 4 backend contract (`list [--label L] [--state open|closed] [--limit N]`) vs. Section 3 `issue-fns.sh` table (`issue_list [--label L] [--state S] [--limit N] [--priority P]`).

**Proposed fix:** Add `[--limit N]` to the `issues-file.py list` row in Section 3, matching the backend contract and `issue_list` signature.

---

## 3. Forced decisions

No forced decisions found.

---

## 4. Previously addressed

- **CDR-4 2.1 (`issue_update --status S` has no valid dispatch path for the GitHub backend)** — Fully resolved. Section 3 now contains an explicit `--status` translation table for the GitHub backend: `closed` → `gh issue close`, `open` → `gh issue reopen`, `working` → `gh issue edit --add-label working`.
- **CDR-5 2.1 (`/list-issues --priority P0` fails — `issue_list` has no `--priority` parameter)** — Fully resolved. `[--priority P]` is now in the `issue_list` signature in the `issue-fns.sh` table (Section 3), and the `--priority` translation note explicitly covers both `issue_list` and `issue_create`.

---

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes** — §3 is empty. One fix needed: add `[--limit N]` to the `issues-file.py list` subcommand row in Section 3. This is a one-word addition. Spec is ready for implementation planning once addressed.
