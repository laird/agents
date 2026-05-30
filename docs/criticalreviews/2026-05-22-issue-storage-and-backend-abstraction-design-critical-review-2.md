# Critical Design Review: 2026-05-22-issue-storage-and-backend-abstraction-design (Round 2)

**Spec:** `/Users/Laird.Popkin/src/agents/docs/superpowers/specs/2026-05-22-issue-storage-and-backend-abstraction-design.md`
**Verified Assumptions section:** MISSING

> ⚠️ This spec lacks a `Verified assumptions` section. Reviewer cannot distinguish verified facts from unverified assumptions; treat findings accordingly.

## 2. Literal-wrongness findings

### 2.1 §2 and §4 specify opposite orderings for `claim` and `release`; §4's order breaks atomic single-winner

**Description.** The spec specifies the `claim` and `release` operations twice, and the two specifications disagree on the order of operations:

- §2 (Python snippets, lines 79–102): **rename first**, then flock the result and update frontmatter. The race analysis on line 110 explicitly says "Concurrent claim attempts. First rename succeeds, second fails. Cleanly resolved by exit code. **No flock involved.**"
- §4 (backend table, line 199): **flocked frontmatter update first**, then rename.

Under §4's order, two racers `B` and `C` calling `claim(N)` can interleave like this:
1. `B` flocks `open/N.md`, parses, sets `status=working` + `working` label, writes via fd, unflocks.
2. `C` flocks `open/N.md` (still there — `B` hasn't renamed yet), parses (now sees `status=working`), updates again, writes, unflocks.
3. `B` runs `os.rename(open/N.md → working/N.md)`. Succeeds.
4. `C` runs `os.rename(open/N.md → working/N.md)`. `open/N.md` is gone → `FileNotFoundError`, `C` exits 1.

Result *for this interleaving:* one winner. But:

5. Alternate interleaving: if `C` arrives between `B`'s `unflock` and `B`'s `rename`, both reach the rename step. POSIX `rename(src, dst)` overwrites `dst` if it exists. Both renames succeed, both backends report exit 0, both agents think they claimed the issue.

Goal #4 ("race-free concurrent claiming") fails under §4's order. §2's order ("rename first, then flock-update the relocated file") does not have this hole: the rename itself is the atomicity barrier, and the loser of the rename race cannot reach the flock step at all.

**Evidence.**
- Spec §2 lines 81–90 (`claim` Python): `os.rename(src, dst)` first, then "open the file under flock and update frontmatter."
- Spec §2 line 110: "First rename succeeds, second fails. Cleanly resolved by exit code. No flock involved."
- Spec §4 line 199, file row, `claim N` cell: "Flocked frontmatter update, then `rename open/NNN.md → working/NNN.md`."
- Same disagreement for `release` in line 199's `release N` cell vs §2 lines 94–102.

**Proposed fix.** §4's backend table is the wrong order. Rewrite the file row of §4 to match §2's order: rename first, then flock-update at the new path. Specifically:
- `claim N` cell: "Source must be `open/NNN.md`. `rename open/NNN.md → working/NNN.md` (atomic; on `FileNotFoundError`, exit 1). On success, flock the file at its new path and update frontmatter (set `status: working`, append `working` label) via fd-based I/O."
- `release N` cell: "`rename working/NNN.md → <target>/NNN.md` (target chosen below). On `FileNotFoundError`, exit 1. On success, flock the file at its new path and update frontmatter (clear `working` label and status) via fd-based I/O. Target bucket: `blocked/` if frontmatter contained any blocking label, else `open/` — read the labels *before* the rename (via a single flocked read at the source path) so the target choice is deterministic."

Note: §2's `release` Python snippet itself has a separate problem; see 2.4.

---

### 2.2 §4 CLI contract omits `--state blocked` from the listing surface

**Description.** §1's listing-semantics table (line 53) defines `--state blocked` as a valid filter that walks `blocked/*.md`. §4's uniform CLI contract (line 158) specifies the listing surface as:

```
<backend> list [--state open|working|closed|all] [--label L] [--limit N]
```

`blocked` is not in the enum. An implementer following §4 as the surface authority would build a backend that rejects `--state blocked` with exit `2` (usage error, per the contract). The behavior §1 specifies is then undeliverable through the backend script that §4 governs.

**Evidence.**
- Spec §1 line 53: `--state blocked` row in the listing-semantics table.
- Spec §4 line 158: `<backend> list [--state open|working|closed|all] ...` — no `blocked`.

**Proposed fix.** Update §4's CLI contract for `list` to `[--state open|working|blocked|closed|all]`.

---

### 2.3 §2's `release` Python snippet hardcodes `open/` as the target, contradicting §2's blocking-label transitions

**Description.** §2 contains the blocking-label transition rules (lines 126–132) which include:

> `release N` from `working/`: if frontmatter contains any blocking label, target is `blocked/`; otherwise `open/`. Either way it is a single `rename`.

But §2's `release` Python snippet earlier in the same section (lines 94–102) hardcodes `open/` as the destination:

```python
src = issues_dir / "working" / f"{n:03d}.md"
dst = issues_dir / "open"    / f"{n:03d}.md"   # always open/
```

An implementer copying the Python snippet builds a `release` that always lands in `open/`, never `blocked/`. A `working/` issue with `needs-design` set then releases into `open/`, where `any-claimable` immediately re-picks it. Goal #2 ("near-zero LLM cost when no work") fails — a blocked-but-recently-worked issue masquerades as claimable until someone clears the label.

**Evidence.**
- Spec §2 lines 94–102: `release` Python snippet hardcodes `dst = issues_dir / "open" / ...`.
- Spec §2 lines 130–131: blocking-label rule says `release` target depends on labels.

**Proposed fix.** Replace the `release` Python snippet's hardcoded destination with a label-aware target selection. Read the labels under flock at the source path, choose `blocked/` or `open/`, then `rename`. Concretely:

```python
src = issues_dir / "working" / f"{n:03d}.md"
with open(src, "r+") as f:
    lock_ex(f.fileno())
    try:
        data = parse_issue_file_fd(f)
        labels = data.get("labels") or []
        target_bucket = "blocked" if any(l in BLOCKING_LABELS for l in labels) else "open"
        # clear the working label/status BEFORE renaming, via fd-based I/O
        data["labels"] = [l for l in labels if l != "working"]
        data["status"] = "blocked" if target_bucket == "blocked" else "open"
        write_issue_file_fd(f, data)
    finally:
        unlock(f.fileno())
dst = issues_dir / target_bucket / f"{n:03d}.md"
try:
    os.rename(src, dst)
except FileNotFoundError:
    sys.exit(1)
```

(Note: this snippet's ordering — flock-update then rename — is correct for `release` because the destination always exists as one of two known buckets and there is no atomic-single-winner requirement for `release` as there is for `claim`. The race resolved here is "did some other agent already release?", which `FileNotFoundError` on `os.rename` correctly handles. Finding 2.1's argument against flock-then-rename applies only to `claim`.)

The spec must either pick the same ordering for both (rename-first everywhere, with the target known up front) or document the asymmetry explicitly. Recommended: keep `claim` as rename-first (per 2.1) and `release` as flock-update-then-rename (label inspection is required to pick the target, and there's no single-winner contention).

---

### 2.4 File-backend `any-claimable` does not emit exit 3 on backend errors

**Description.** Round 1 finding 2.2 introduced a 4-code contract for backend scripts, distinguishing `1` ("no claimable issues") from `3` ("backend error"). The contract is now in §4 lines 188–191. The file-backend `any-claimable` implementation in §4 line 199 is:

```
find open/ -maxdepth 1 -name '*.md' -print -quit
```

`find` exits `0` when it prints a hit and exits `1` in two distinct cases: (a) no `*.md` files in `open/`, and (b) `open/` doesn't exist or is unreadable. Case (b) is a backend error per the contract, but the implementation reports it as exit `1` ("no claimable issues"). `fix-loop`'s preflight (§5 lines 283–290) treats exit `1` as the clean-idle path and skips iterations indefinitely.

Realistic triggers for case (b): the user invoked `/fix-loop` before running `/migrate-issues-layout`; a filesystem permission error; an accidental `rm -rf .issues/open/`. In all of these, `fix-loop` silently reports idle forever rather than surfacing the configuration problem.

This is the same shape as round 1 finding 2.2 but applies to the file backend's implementation specifically — round 1's resolution updated the contract and the github backend's command, but left the file-backend command as a pure `find` invocation that cannot produce exit `3`.

**Evidence.**
- Spec §4 line 191: exit-code contract definition of `3` (backend error).
- Spec §4 line 199, file row, `any-claimable` cell: `find open/ -maxdepth 1 -name '*.md' -print -quit`.
- Spec §5 lines 283–290: `fix-loop` outer loop treats exit `1` as idle.

**Proposed fix.** Wrap the file-backend `any-claimable` in a guard that distinguishes "no work" from "error":

```bash
[ -d "${ISSUE_DIR_PATH}/open" ] || exit 3
if find "${ISSUE_DIR_PATH}/open" -maxdepth 1 -name '*.md' -print -quit | grep -q .; then
  exit 0
else
  exit 1
fi
```

The directory-exists check produces exit `3` if the file backend is uninitialized. The `find | grep -q .` form produces exit `0` if at least one file was printed and `1` otherwise, regardless of `find`'s own exit code. Update the spec's table cell to show this form (or an equivalent that satisfies the 4-code contract).

---

### 2.5 Section E's claim-race contract test is unsatisfiable by the github backend the spec explicitly specifies

**Description.** §6 Section E lists contract tests every backend must pass:

> Claim semantics: `claim` succeeds, second `claim` fails with exit 1, `release` succeeds.

This is the strict single-winner test from finding 2.1's claim semantics. But §4 line 216 explicitly states:

> The github backend's `claim` is **best-effort**: there is no atomic single-writer label edit in the gh API, so two agents racing to claim the same issue can both think they succeeded.

An implementer faithfully running Section E's contract test against `issues-gh.sh` will see the second `claim` succeed (label-add is idempotent) rather than fail with exit 1. The test the spec defines cannot be satisfied by the gh backend the spec specifies.

Goal #3 ("structurally parallel … drop-in") rests on every backend passing the same contract tests. If the contract test list contains a test that the gh backend cannot pass, "drop-in" is not delivered.

**Evidence.**
- Spec §6 Section E (line 359): "claim succeeds, second claim fails with exit 1, release succeeds."
- Spec §4 line 216: gh's claim is best-effort; "two agents racing to claim the same issue can both think they succeeded."

**Proposed fix.** Section E's claim test needs a backend-aware variant. Pick one:

- **(a)** Split the test: a strict variant (must hold on file, jira, etc.) and a relaxed variant (acceptable on gh — only verifies that `claim` returns success on a free issue and exit 1 on a claimed-by-the-same-process issue, not on a race-loser).
- **(b)** Mark the strict test as file-only and document that gh has a known limitation, with a separate gh-only test that just asserts `claim` and `release` round-trip the `working` label.
- **(c)** Build the strict gh claim out of scope today (per §4 line 216) but require Section E to declare which tests are mandatory for "structurally parallel" and which are aspirational.

Whichever path, Section E must stop asserting a test the spec elsewhere says is unimplementable on the named backend.

## 3. Forced decisions

No forced decisions found.

## 4. Previously addressed

All four round-1 findings are resolved by spec edits in commit `3dbe749`:

- **2.1 (any-claimable decoupled from claimable):** Resolved by adding the `blocked/` bucket and the blocking-label transition rules in §2. `any-claimable` semantics now align with "claimable" by directory.
- **2.2 (exit-code ambiguity):** Resolved by the 4-code contract in §4 and the `case`-statement preflight in §5. *(See 2.4 above for a residual file-backend gap.)*
- **2.3 (comment-during-rename duplicate-file race):** Resolved by the normative fd-based I/O requirement in §1 and the tightened race-2 analysis in §2.
- **2.4 (gh `any-claimable` never exits 1):** Resolved by the count-and-bracket form shown in §4 lines 205–209.

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes**

§2 has 5 findings, all addressable by spec edits without re-architecture. §3 is empty. Three of the findings (2.1, 2.3, 2.5) are internal contradictions introduced or sharpened by the round-1 fixes; one (2.2) is a contract-vs-CLI mismatch; one (2.4) is a residual gap from round 1's exit-code work.
