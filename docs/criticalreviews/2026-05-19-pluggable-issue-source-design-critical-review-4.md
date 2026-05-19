# Critical Design Review: 2026-05-19-pluggable-issue-source-design (Round 4)

**Spec:** `docs/superpowers/specs/2026-05-19-pluggable-issue-source-design.md`
**Verified Assumptions section:** MISSING

> ⚠️ This spec lacks a `Verified assumptions` section. Reviewer cannot distinguish verified facts from unverified assumptions; treat findings accordingly.

---

## 1. Verified-assumptions cross-check

Section omitted — spec has no `Verified assumptions` section.

---

## 2. Literal-wrongness findings

### 2.1 `issue_update --status S` has no valid dispatch path for the GitHub backend

**Description:** The `issue-fns.sh` table (Section 3) maps `issue_update` to `gh issue edit` for the GitHub backend. The `issue_update` function signature accepts `[--status S]`. `gh issue edit` has no `--status` flag (verified: `gh issue edit --help` shows no `--status` option). If `issue-fns.sh` passes `--status` through to `gh issue edit`, the command fails.

The coupling table (Section 2) describes `--status working` / `--status open` as file-backend effects, but this is only the *file backend* behavior. The spec does not describe what `issue-fns.sh` does with `--status S` when the GitHub backend is active — the only stated mapping is "equivalent `gh` call: `gh issue edit`," which does not accept `--status`.

The correct GitHub equivalents exist but are not mapped: `--status closed` → `gh issue close`, `--status open` → `gh issue reopen`.

**Evidence:** `gh issue edit --help` produces no `--status` flag. `gh issue reopen` exists and accepts an issue number. Spec Section 3 `issue-fns.sh` table row for `issue_update` states equivalent call is `gh issue edit` with no qualification on `--status`.

**Proposed fix:** Specify the `--status` translation in `issue-fns.sh` for the GitHub backend:
- `--status closed` → `gh issue close <number>`
- `--status open` → `gh issue reopen <number>`
- `--status working` → `gh issue edit <number> --add-label working` (already handled by coupling, but make explicit)

Alternatively, declare `--status` as a file-backend-only parameter that `issue-fns.sh` strips for the GitHub backend (with a note that callers should use `issue_close` for closing and `--add-label working` for claiming). Either choice closes the gap; the spec must pick one.

---

## 3. Forced decisions

No forced decisions found.

---

## 4. Previously addressed

From CDR-3:
- **2.1 File backend distributed lock breaks when callers use `--add-label working`** — Fully resolved. Section 2 now has an explicit `working` Label / `status` Coupling table specifying that `--add-label working` atomically sets `status: working` and `--remove-label working` sets `status: open`. The `issues-file.py` `update` subcommand row in Section 3 cross-references this coupling.

---

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes** — §3 is empty. One fix needed: specify how `issue-fns.sh` handles `--status S` for the GitHub backend (either map to `gh issue close`/`gh issue reopen`, or declare it file-backend-only and strip it). Spec is ready for implementation planning once addressed.
