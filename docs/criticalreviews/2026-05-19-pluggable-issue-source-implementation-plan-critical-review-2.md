# Critical Implementation Review: 2026-05-19-pluggable-issue-source-implementation-plan (Round 2)

**Plan:** `docs/plans/2026-05-19-pluggable-issue-source-implementation-plan.md`
**Verified plan-level assumptions section:** present

⚠️ 5 commits since plan-write time (SHA de4e39c); §1 assumptions re-checked under fresh reads.

---

## 1. Verified-plan-assumptions cross-check

| # | Assumption | Status |
|---|-----------|--------|
| 1 | All 13 migration target files exist at their stated paths | ✅ Still holds |
| 2 | All 13 files contain functional `gh issue` calls (counts as listed) | ✅ Still holds |
| 3 | Python 3.8+ available as `python3` | ✅ Still holds — Python 3.13.7 |
| 4 | `fcntl` module available in stdlib | ✅ Still holds |
| 5 | `argparse` supports `required=True` on subparsers | ✅ Still holds |
| 6 | All four directories exist | ✅ Still holds |
| 7 | `gh issue list` accepts `--state {open\|closed\|all}` | ✅ Still holds |
| 8 | `.agent/` mirror convention applies | ✅ Still holds |
| 9 | `"003".isdigit()` returns `True` | ✅ Still holds |
| 10 | `tests/` directory does NOT exist in the repo | ✅ Still holds |
| 11 | `pytest 9.0.2` available | ✅ Still holds |
| 12 | `fcntl.LOCK_EX=2`, `LOCK_SH=1`, `LOCK_UN=8` | ✅ Still holds |
| 13 | `argparse choices=["open","closed","all"]` accepts "all" | ✅ Still holds |
| 14 | `glob("*.md")` does NOT match `.seq` | ✅ Still holds |
| 15 | `full-regression-test.md` uses `gh issue list --state all` at line 287 | ✅ Still holds |
| 16 | `docs/plans/` directory exists | ✅ Still holds |

All verified plan-level assumptions reconfirmed.

---

## 2. Literal-wrongness findings

No literal-wrongness findings.

---

## 3. Forced decisions

No forced decisions found.

---

## 4. Previously addressed

- **CIR-1 §2.1 — Task 4 Step 1 test assertion fires non-interactive fail-fast**: Fixed. Task 4 Step 1 test now uses `ISSUE_SOURCE=github bash -c "source $SCRIPT; echo 0"`, which triggers the early-return at the top of `issue-config.sh` before the non-TTY fail-fast fires.
- **CIR-1 §2.2 — `issue_create --priority` rejected by file backend**: Fixed. `issue_create()` in Task 5 now strips `--priority` and converts to `--label` before dispatch (matching `issue_list()`'s pattern), so `record-issue.md` works correctly on the file backend.

---

## 5. Recommendation

✅ **Approve as-is** — §1 has no failed assumptions; §2 and §3 are both empty. Plan is ready for `subagent-driven-development`.
