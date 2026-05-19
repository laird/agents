# Critical Design Review: 2026-05-19-pluggable-issue-source-design (Round 8)

**Spec:** `docs/superpowers/specs/2026-05-19-pluggable-issue-source-design.md`
**Verified Assumptions section:** MISSING

> ⚠️ This spec lacks a `Verified assumptions` section. Reviewer cannot distinguish verified facts from unverified assumptions; treat findings accordingly.

---

## 1. Verified-assumptions cross-check

Section omitted — spec has no `Verified assumptions` section.

---

## 2. Literal-wrongness findings

No literal-wrongness findings.

---

## 3. Forced decisions

No forced decisions found.

---

## 4. Previously addressed

- **CDR-7 2.1 (backend contract `update` pipe syntax)** — Fully resolved. Section 4 `update` row now uses bracket notation `[--add-label L] [--remove-label L] [--status S]`, matching `issues-file.py` and `issue_update` function signature.
- **CDR-7 2.2 (`--assignee A` has no GitHub backend translation)** — Fully resolved. `--assignee` is now declared file-backend-only in Section 3; `issue-fns.sh` strips it for the GitHub backend; removed from Section 4 backend contract.

---

## 5. Recommendation

✅ **Approve as-is** — §2 and §3 are both empty. Spec is ready for implementation planning.
