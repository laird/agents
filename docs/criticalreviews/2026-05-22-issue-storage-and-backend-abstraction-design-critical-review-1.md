# Critical Design Review: 2026-05-22-issue-storage-and-backend-abstraction-design (Round 1)

**Spec:** `/Users/Laird.Popkin/src/agents/docs/superpowers/specs/2026-05-22-issue-storage-and-backend-abstraction-design.md`
**Verified Assumptions section:** MISSING

> ⚠️ This spec lacks a `Verified assumptions` section. Reviewer cannot distinguish verified facts from unverified assumptions; treat findings accordingly.

## 2. Literal-wrongness findings

### 2.1 `any-claimable` is decoupled from what "claimable" means in the codebase

**Description.** Goal #2 of the spec is "Make the 'no work to do' path near-zero LLM token cost." The mechanism is `issue_any_claimable` as a `fix-loop` preflight. But the spec defines `any-claimable` as "is there any non-working open issue?" — not "is there any *claimable* open issue."

The existing definition of claimable, as encoded in `monitor-workers.md:130` and `fix.md`, excludes issues with blocking labels: `needs-design`, `needs-clarification`, `needs-feedback`, `needs-approval`, `too-complex`, `future`, `proposal`. Under the spec's `any-claimable`, a repo whose `open/` contains only blocked issues will:

1. `any-claimable` returns true (directory is non-empty).
2. `fix-loop` invokes `/fix`.
3. `/fix` loads, scans, filters out all blocked issues, finds nothing claimable, exits.
4. The full LLM token cost has been paid for a no-op.

This contradicts the asked-for behavior of Goal #2.

**Evidence.**
- Spec §5: "`any-claimable` is implemented as `find ${ISSUE_DIR_PATH}/open -maxdepth 1 -name '*.md' -print -quit`." Reads no frontmatter, ignores labels.
- Spec §4 github row: `gh issue list --state open --search 'no:label "working"' -L 1` — excludes only the `working` label, not the blocking-label set.
- `plugins/autocoder/commands/monitor-workers.md:130` (current codebase): claimable definition explicitly excludes `needs-design`, `needs-clarification`, `future`, `proposal`, `needs-approval`, `too-complex`, `working`.

**Proposed fix.** Pick one of these and write it into the spec:
- **Option A** — Promote blocking statuses to a fourth bucket, `.issues/blocked/`. `any-claimable` stays cheap (`open/` non-empty). State transitions: blocking-label add ⇒ `open/N.md → blocked/N.md`; clearing the last blocking label ⇒ `blocked/N.md → open/N.md`. This keeps the rename-based discipline and the O(claimable) preflight.
- **Option B** — Accept that `any-claimable` must parse frontmatter to filter blocked issues. Document that the file-backend cost is O(open), not O(1). The github backend can incorporate `no:label "needs-design" no:label "needs-clarification" …` into the search. Goal #2 still holds for the closed-issue-heavy case but not for the blocked-issue-heavy case.
- **Option C** — Redefine "claimable" at the slash-command layer so that any issue in `open/` is fair game, and `/fix` decides per-issue whether to defer (which already happens via the blocking-label workflow). This is a behavior change but eliminates the gap entirely.

The spec must pick one; the current text is internally inconsistent with the codebase's claimable definition.

---

### 2.2 Exit-code ambiguity in `any-claimable` causes silent work loss on transient errors

**Description.** Spec §4 defines exit codes as: `0` = success / work exists; `1` = generic failure *and* "no claimable issues"; `2` = usage error. `fix-loop`'s preflight (§5) is `if ! issue_any_claimable; then echo "No claimable issues…"; exit 0; fi`. Under this contract, *any* exit-1 from the backend — a transient `gh` API failure, a temporary filesystem error, an auth issue — is interpreted as "no work." `fix-loop` reports idle and skips an iteration; work that exists is silently dropped.

For `fix-loop` (a daemon that's supposed to keep processing while there's work), this is a correctness regression versus today's behavior, where `issue_list` failures surface as visible errors.

**Evidence.**
- Spec §4 exit-code contract: "1 — generic failure (issue not found, claim lost, etc.). For `any-claimable`: no claimable issues."
- Spec §5 preflight: treats any non-zero as "no work."

**Proposed fix.** Split the codes:
- `0` — work exists.
- `1` — no work (clean negative answer).
- `2` — usage error.
- `3+` — backend error (e.g., `gh` failure, fs error). `fix-loop` must surface the error rather than treat it as "no work."

The bash preflight in §5 then becomes:
```bash
issue_any_claimable
case $? in
  0) ;;  # work exists, fall through
  1) echo "No claimable issues. Nothing to do."; exit 0 ;;
  *) echo "Backend error checking for work"; exit 1 ;;
esac
```

---

### 2.3 Comment-during-rename race produces duplicate files; "directory is authoritative" invariant breaks

**Description.** §2 of the spec asserts that concurrent `comment` and `rename` compose safely because "A's file descriptor still points to the inode (now at the new path); A's writes land at the new location." This is true *if* the implementation uses fd-based io (read and write through the locked fd). The existing `issues-file.py` implementation re-opens the file by path inside the lock (`parse_issue_file(p)` calls `path.read_text()`; `write_issue_file(path, data)` calls `path.write_text(...)`). With the new rename-based claim:

1. A: `open(open/042.md, "r+")` succeeds. A holds flock on inode I.
2. B: `os.rename(open/042.md → working/042.md)`. Directory entry for `open/042.md` is removed.
3. A: `parse_issue_file(p)` calls `path.read_text()`, which opens `open/042.md` *by path* — fails with `FileNotFoundError`, or A is in the read-then-write path and `write_text` is the first re-open, which **creates** `open/042.md` (mode `"w"` truncates-or-creates) and writes A's bytes there.

After A unlocks, the repo has two files with number 042: one at `working/042.md` (B's rename target) and one at `open/042.md` (A's recreated path). The "directory location is authoritative" invariant (§1) breaks: which bucket is the issue in?

This is introduced by the new design — under today's flat layout, no renames occur during normal operations, so the race doesn't manifest. Spec §1 says "All read-modify-write paths continue to take `flock` on the file. `flock` covers contents; `rename` covers location. They compose safely (see §2)." The composition claim only holds if rmw operations use the locked fd, but the spec does not require this and the existing code does not do it.

**Evidence.**
- Spec §1: "All read-modify-write paths continue to take `flock` on the file. `flock` covers contents; `rename` covers location. They compose safely (see §2)."
- Spec §2: race-2 analysis assumes fd-based io ("A's writes land at the new location").
- `plugins/autocoder/scripts/issues-file.py:189–223` (`cmd_update`): `with open(p, "r+") as f: lock_ex(...); data = parse_issue_file(p); ...; write_issue_file(p, data)`. Both helpers re-open by path.
- `plugins/autocoder/scripts/issues-file.py:54–56` (`parse_issue_file`): `content = path.read_text()` (opens by path).
- `plugins/autocoder/scripts/issues-file.py:100` (`write_issue_file`): `path.write_text(...)` (opens by path with mode `"w"`).

**Proposed fix.** The spec must add an explicit requirement: read and write operations under flock MUST use the locked fd (e.g., `f.seek(0); f.read()`, `f.seek(0); f.truncate(); f.write(...)`), not re-open by path. Refactoring `parse_issue_file` and `write_issue_file` to take a file object (or to be inlined into the locked block) is part of the implementation work for this design. Without this, the race in §2 produces duplicate files, not the claimed "safe" outcome.

---

### 2.4 github `any-claimable` as written never reports "no work"

**Description.** Spec §4 shows the github implementation as:
```
gh issue list --state open --search 'no:label "working"' -L 1 --json number --jq 'length | . > 0'
```

This produces `true` or `false` on **stdout**. The exit code is whatever `gh` returns — `0` on success regardless of the count. The dispatcher `issue_any_claimable() { "$_ifns_BACKEND_BIN" any-claimable; }` (§4) returns the backend's exit code, not stdout. So `fix-loop`'s preflight `if ! issue_any_claimable` evaluates the exit code: always `0` for a successful `gh` call. The "no work" branch is unreachable on the github backend.

**Evidence.**
- Spec §4 github row, `any-claimable` column.
- Spec §4 dispatcher: `issue_any_claimable() { "$_ifns_BACKEND_BIN" any-claimable; }` — exit-code passthrough.
- Spec §5 preflight: `if ! issue_any_claimable` — boolean test on exit code.

**Proposed fix.** Specify the github implementation as an exit-code-producing pipeline, not a stdout-producing one. For example:
```bash
count=$(gh issue list --state open --search 'no:label "working"' -L 1 --json number --jq 'length')
[ "$count" -gt 0 ]
```

The trailing `[ ... ]` produces the exit code the caller expects. Or, if 2.2's three-code scheme is adopted, an explicit `case`:
```bash
if ! count=$(gh issue list ... --jq 'length' 2>/dev/null); then
  exit 3   # backend error
fi
[ "$count" -gt 0 ]
```

The file-backend command in the same table row (`find ... -print -quit`) already produces exit codes correctly — only the github row needs this fix.

## 3. Forced decisions

No forced decisions found.

(The "blocked issues" choice raised under §2.1 is not a separate forced decision — it's the proposed-fix dimension of the literal-wrongness finding itself. The other "Open questions" the spec lists at the end are either already decided in spec prose or are deferrable per the spec's own text.)

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes**

§2 has four findings, all addressable in spec edits without re-architecture. §3 is empty. After 2.1–2.4 are resolved in the spec, the design is ready for implementation planning.
