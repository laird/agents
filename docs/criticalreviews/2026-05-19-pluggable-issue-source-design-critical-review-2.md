# Critical Design Review: 2026-05-19-pluggable-issue-source-design (Round 2)

**Spec:** `docs/superpowers/specs/2026-05-19-pluggable-issue-source-design.md`
**Verified Assumptions section:** MISSING

> ⚠️ This spec lacks a `Verified assumptions` section. Reviewer cannot distinguish verified facts from unverified assumptions; treat findings accordingly.

---

## 1. Verified-assumptions cross-check

Section omitted — spec has no `Verified assumptions` section.

---

## 2. Literal-wrongness findings

### 2.1 `issues-file.py` subcommand table still lists `[--priority P]` on `create`

**Description:** Section 3's `issues-file.py` subcommand table (line 156) shows:

```
| `create --title "..." --body "..." [--label L] [--priority P]` | Append new issue, output `{"number": N}` |
```

But the fix applied in this round (Section 3 `issue-fns.sh` description and Section 4 backend contract) says `issue-fns.sh` translates `--priority P` to `--label P` *before dispatching to any backend*, and the backend contract (Section 4) now correctly shows only `[--label L]` for `create`. `issues-file.py` is a backend. An implementer following the Section 3 subcommand table would implement `issues-file.py create` to accept `--priority` — but it will never receive one (already translated). If the implementer acts on the flag, nothing breaks. If the implementer relies on it, the feature silently fails when called via `issue-fns.sh` (which strips it before dispatch). Either way, the table is wrong relative to the rest of the spec.

**Evidence:** Spec line 156 vs. Section 4 backend contract (line 308, now showing `--title "..." --body "..." [--label L]`) and the `issue-fns.sh` translation note (line 198).

**Proposed fix:** Remove `[--priority P]` from the `issues-file.py create` row in Section 3 to match the Section 4 backend contract. Add a comment: "Priority arrives pre-translated as `--label P1` by `issue-fns.sh`."

---

### 2.2 Section 3 `issues-file.py` description still says "Uses `flock`"

**Description:** Section 3's description of `issues-file.py` (line 145) reads:

> "Python script implementing all ISSUES.md read/write operations. Uses `flock` for safe concurrent access across worktrees."

The word `flock` here is ambiguous between the Linux shell command `flock` (which CDR-1 found does not exist on macOS) and Python's `fcntl.flock`. Section 2 (Worktree Coordination) correctly specifies `fcntl.flock(fd, fcntl.LOCK_EX)`, but Section 3's prose contradicts it. An implementer working from Section 3 alone could call the shell `flock` command, reproducing the macOS failure CDR-1 found.

**Evidence:** Spec line 145 (`Uses \`flock\``) vs. Section 2 line 125 (`fcntl.flock(fd, fcntl.LOCK_EX)`).

**Proposed fix:** Change line 145 to: "Uses Python's `fcntl.flock(fd, fcntl.LOCK_EX)` for safe concurrent access across worktrees — no external tools required."

---

## 3. Forced decisions

No forced decisions found.

---

## 4. Previously addressed

From CDR-1:

- **2.1 `flock` not available on macOS** — Section 2 (Worktree Coordination) now specifies `fcntl.flock(fd, fcntl.LOCK_EX)` from Python's standard library. Residual stale text in Section 3 captured as new finding 2.2 above.
- **2.2 ISSUES.md separator ambiguity** — Resolved. Format now uses `<!-- issue -->` / `<!-- /issue -->` tags as unambiguous boundaries. `---` appears only as YAML frontmatter delimiter inside a tag-bounded block.
- **2.3 Migration scope understated** — Resolved. Section 3 now lists all 13 files with `gh issue` calls, scoped by rule ("All files in `plugins/autocoder/commands/` and `plugins/autocoder/scripts/`").
- **2.4 Inconsistent worktree command** — Resolved. Both Section 1 and Section 2 now use `git worktree list --porcelain | grep -m1 "^worktree" | cut -d' ' -f2`.
- **2.5 `--priority` flag unhandled by GitHub backend** — Partially resolved. Section 4 backend contract and `issue-fns.sh` translation note are correct. Residual inconsistency in `issues-file.py` table captured as new finding 2.1 above.
- **3.1 Non-interactive detection hang** — Resolved. Spec now specifies fail-fast with a clear error when no TTY and no cached config.

---

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes** — §3 is empty. Two targeted edits are needed (both in Section 3): remove `[--priority P]` from the `issues-file.py create` row, and replace "Uses `flock`" with the correct Python `fcntl` language. Both are one-line fixes. Spec is ready for implementation planning once addressed.
