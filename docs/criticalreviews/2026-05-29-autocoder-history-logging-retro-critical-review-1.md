# Critical Implementation Review: 2026-05-29-autocoder-history-logging-retro (Round 1)

**Plan:** `docs/superpowers/plans/2026-05-29-autocoder-history-logging-retro.md`
**Verified plan-level assumptions section:** MISSING

> ⚠️ This plan was produced by `superpowers:writing-plans`, not `thorough-writing-plans`. The `Verified plan-level assumptions` section is absent; the skill's input contract requires rejection for this case. Review proceeds on the user's explicit request — treat all plan-level assumptions as unverified.

No prior plan reviews exist (first round). No `**Source spec:**` header present; drift detection skipped.

---

## 1. Verified-plan-assumptions cross-check

Section missing — skipped.

---

## 2. Literal-wrongness findings

### Finding 1: Tasks 5 & 6 Steps 2 — old_string for PR-path logging insertions is not unique in fix.md

**Description:**  
Both Steps instruct the Edit tool to find `echo "✅ PR created for issue #$ISSUE_NUM — awaiting review"` followed by `else  # Auto-merge: switch back to parent branch`. This string appears **twice** in `fix.md` — once in the simple fix block (Step 2A, line 740) and once in the complex fix block (Step 3, line 930). Both surrounding blocks are structurally identical at that point. The Edit tool requires `old_string` to be unique; with a non-unique string it fails with an error, and neither logging call gets inserted.

**Evidence:**

```bash
grep -c 'echo "✅ PR created for issue #\$ISSUE_NUM — awaiting review"' \
  plugins/autocoder/commands/fix.md
# → 2
```

The plan acknowledges the duplication for the merge-path (Task 5 Step 4: "Important: there are two similar fi blocks…") but does not provide unique context for either insertion point in Steps 2 of Tasks 5 or 6.

**Proposed fix:**  
Include the PR `--body` content that differs between the two paths in the old_string anchor:
- Simple path is uniquely identified by `[Detailed explanation of fix]` in the PR body (line ~734)
- Complex path is uniquely identified by `## Root Cause` in the PR body (line ~914)

---

### Finding 2: Tasks 5 & 6 Steps 4 — old_string for merge-path logging insertions is not unique in fix.md

**Description:**  
The `# Write completion status file for agents-ui TUI monitoring` comment + `SESSION_NAME=…` + the `echo {…status…}` line appears **twice** in `fix.md` (lines 763–765 and 963–966). The plan's Step 4 in Task 5 states "use enough surrounding context to be unambiguous" but then provides only the status-file write line and `fi` as the old_string — context that is identical in both occurrences. The Edit tool will fail.

**Evidence:**

```bash
grep -c 'status.*idle.*ISSUE_NUM.*agents-ui' \
  plugins/autocoder/commands/fix.md
# → 2
```

**Proposed fix:**  
Use the `issue_close` comment text immediately preceding each status-file write as the uniqueness anchor — the two calls differ in their closing comment:
- Simple path ends with `🤖 Auto-resolved by autonomous fix workflow"` (line ~761, no "with superpowers")
- Complex path ends with `🤖 Auto-resolved by autonomous fix workflow with superpowers"` (line ~962)

Include enough of the `issue_close` block in each old_string so the Edit tool can uniquely identify the location. The same problem applies when Task 7 mirrors these edits to `.agent/workflows/fix.md`.

---

### Finding 3: Task 8 Step 2 — placeholder text in retro.md Write content will land verbatim if Step 1 output is not manually substituted

**Description:**  
Task 8 Step 2's Write instruction contains the literal string `[paste exact block from fix.md here]` inside the file content to write. Step 1 reads the optional-skills-prelude block from `fix.md` and says "Copy … for use in Step 2," but the integration between Steps 1 and 2 is implicit: the plan never says "substitute the Step 1 output at the `[paste…]` marker in Step 2." An agentic executor using the Write tool directly from the Step 2 code block — without interpreting the cross-step dependency — will write the placeholder text verbatim into `retro.md`, producing a malformed command file that references a non-existent skills block.

**Evidence:**  
`docs/superpowers/plans/2026-05-29-autocoder-history-logging-retro.md` line 735:
```
[paste exact block from fix.md here]
```

The writing-plans skill's "No Placeholders" rule explicitly lists this pattern as a plan failure.

**Proposed fix:**  
Read the actual content of the optional-skills-prelude block (lines 7–23 of `fix.md`) during plan authoring and embed it directly as literal text in the Task 8 Step 2 Write content, removing the placeholder entirely.

---

## 3. Forced decisions

No forced decisions found.

---

## 5. Recommendation

⚠️ **Approve with literal-wrongness fixes** — address the three §2 items before execution. Findings 1 and 2 will cause Edit tool failures in Tasks 5, 6, and 7 (which inherits the same old_strings). Finding 3 will produce a broken `retro.md` if the agentic executor doesn't catch the implicit cross-step dependency.
