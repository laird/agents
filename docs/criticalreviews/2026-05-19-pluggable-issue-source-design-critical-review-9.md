# Critical Design Review: 2026-05-19-pluggable-issue-source-design (Round 9)

**Spec:** `docs/superpowers/specs/2026-05-19-pluggable-issue-source-design.md`
**Verified Assumptions section:** present

---

## 1. Verified-assumptions cross-check

Each assumption cross-checked against the cited evidence:

| Assumption | Status |
|-----------|--------|
| `gh issue list` accepts `--label`, `--limit`, `--state` | ✅ Reconfirmed — all three flags present in `gh issue list --help` output from this session |
| `gh issue list` does NOT accept `--priority` or `--status` | ✅ Reconfirmed — neither flag appeared in help output |
| `gh issue create` accepts `--label` but NOT `--priority` | ✅ Reconfirmed — confirmed this session |
| `gh issue edit` accepts `--add-label` and `--remove-label` | ✅ Reconfirmed — confirmed this session |
| `gh issue edit` does NOT accept `--status` or `--assignee` | ✅ Reconfirmed — neither flag in help output; `--add-assignee`/`--remove-assignee` take GitHub logins |
| `gh issue close` accepts `--comment` | ✅ Reconfirmed — `-c, --comment string` in help output |
| `gh issue reopen` exists | ✅ Reconfirmed — help succeeds |
| `gh issue list --json` supports `number, title, body, labels, state` | ✅ Reconfirmed — all listed in help JSON fields |
| Python `fcntl.flock` available on macOS | ✅ Reconfirmed — `import fcntl` succeeds on darwin |
| Shell `flock` NOT available on macOS | ✅ Reconfirmed — `which flock` returns nothing |
| `git worktree list --porcelain \| grep -m1 "^worktree" \| cut -d' ' -f2` returns main worktree path | ✅ Reconfirmed — returned `/Users/Laird.Popkin/src/agents` |
| 13 files with functional `gh issue` calls in migration scope | ✅ Reconfirmed — grep returns 14 files; `autocoder-help.md` correctly excluded (documentation example, not executed code) |

All verified assumptions reconfirmed.

---

## 2. Literal-wrongness findings

No literal-wrongness findings.

---

## 3. Forced decisions

No forced decisions found.

---

## 4. Previously addressed

- **CDR-1 through CDR-8 recurring ⚠️ (missing `Verified Assumptions` section)** — Resolved. The section is now present with empirical evidence for all load-bearing claims.

---

## 5. Recommendation

✅ **Approve as-is** — §2 and §3 are both empty, all verified assumptions hold. Spec is ready for implementation planning.
