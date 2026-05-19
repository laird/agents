# Critical Design Review: 2026-05-19-pluggable-issue-source-design (Round 5)

**Spec:** `docs/superpowers/specs/2026-05-19-pluggable-issue-source-design.md`
**Verified Assumptions section:** MISSING

> ⚠️ This spec lacks a `Verified assumptions` section. Reviewer cannot distinguish verified facts from unverified assumptions; treat findings accordingly.

**Note:** CDR-4 finding 2.1 (`issue_update --status S` has no valid dispatch path for the GitHub backend) remains open — the spec has not been updated since CDR-4. That finding is not re-raised here per iterative review rules, but it is not resolved.

---

## 1. Verified-assumptions cross-check

Section omitted — spec has no `Verified assumptions` section.

---

## 2. Literal-wrongness findings

### 2.1 `/list-issues --priority P0` fails — `issue_list` has no `--priority` parameter

**Description:** The `/list-issues` command (Section 3) documents this as valid usage:

```
/list-issues --priority P0
```

The command "calls `issue_list`." But `issue_list`'s signature (Section 3 `issue-fns.sh` table) is:

```
issue_list [--label L] [--state S] [--limit N]
```

No `--priority` parameter. The spec describes `--priority` → `--label` translation only for `issue_create`, not for `issue_list`. If `--priority P0` is passed to `issue_list` and forwarded to `gh issue list`, the command fails — `gh issue list` has no `--priority` flag (verified: `gh issue list --help` shows only `--label`). If forwarded to `issues-file.py list`, that subcommand also only accepts `[--label L] [--state open|closed]`.

**Evidence:** Spec Section 3 `/list-issues` usage example shows `--priority P0`. Spec Section 3 `issue_list` signature shows `[--label L] [--state S] [--limit N]` — no `--priority`. `gh issue list --help` confirms no `--priority` flag exists.

**Proposed fix:** Extend the `--priority` → `--label` translation in `issue-fns.sh` to cover `issue_list` as well as `issue_create`. Add `[--priority P]` to the `issue_list` function signature and note that `issue-fns.sh` translates it to `--label P` before dispatch. This is the same pattern already specified for `issue_create`.

---

## 3. Forced decisions

No forced decisions found.

---

## 4. Previously addressed

Nothing newly resolved since CDR-4.

---

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes** — §3 is empty. Two fixes are now open: CDR-4 2.1 (`--status S` dispatch for GitHub backend) and CDR-5 2.1 (`--priority` not handled by `issue_list`). Both are one-line additions to `issue-fns.sh`'s description in Section 3. Spec is ready for implementation planning once both are addressed.
