# Autocoder History Logging + Retro Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add history logging to autocoder's fix workflow (shared with modernize), and add a `/retro` command that reads that history to produce evidence-based workflow improvements.

**Architecture:** A shared `append-to-history.sh` script (canonical in `scripts/`, copied to each plugin's `scripts/` dir) gains `--backend` and `--history-file` flags. Autocoder's `fix.md` calls it at each issue-resolution point; `full-regression-test.md` calls it after each run. The new `retro.md` command reads this accumulated history plus git log and issue-tracker data to write `IMPROVEMENTS.md`. The script auto-resolves bare filenames to the main git worktree so parallel fix-loop workers all write to one file.

**Tech Stack:** Bash, GitHub CLI (`gh`), Python 3 (inline), Markdown protocol files

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `scripts/append-to-history.sh` | Rewrite | Canonical source with `--backend`/`--history-file` flags + GitHub backend |
| `plugins/autocoder/scripts/append-to-history.sh` | Create | Copy of canonical script (SYNC NOTE header) |
| `plugins/modernize/scripts/append-to-history.sh` | Create | Copy of canonical script (SYNC NOTE header) |
| `.agent/scripts/append-to-history.sh` | Rewrite | Antigravity mirror of canonical script |
| `plugins/modernize/protocols/protocols-overview.md` | Modify | Add SYNC NOTE to inline heredoc |
| `plugins/autocoder/commands/full-regression-test.md` | Modify | Add SCRIPT_DIR enforcement + logging call |
| `plugins/autocoder/commands/fix.md` | Modify | Add logging at 5 resolution points |
| `.agent/workflows/fix.md` | Modify | Mirror fix.md logging changes |
| `.agent/workflows/full-regression-test.md` | Modify | Mirror full-regression-test.md changes |
| `plugins/autocoder/commands/retro.md` | Create | New `/retro` command protocol |
| `.agent/workflows/retro.md` | Create | Antigravity mirror of retro.md |
| `.claude-plugin/marketplace.json` | Modify | Register `retro` command, bump versions |
| `CLAUDE.md` | Modify | Document `/retro` command |

---

### Task 1: Rewrite `scripts/append-to-history.sh`

**Files:**
- Modify: `scripts/append-to-history.sh`

- [ ] **Step 1: Read the current file to understand what will change**

```bash
cat scripts/append-to-history.sh
```

Expected: 39-line script, hardcoded `docs/HISTORY.md`, no flags.

- [ ] **Step 2: Write the extended script**

Replace the entire contents of `scripts/append-to-history.sh` with:

```bash
#!/bin/bash
# append-to-history.sh - Universal history logging
# Shared between modernize and autocoder plugins.
#
# SYNC NOTE: This file is the canonical source. Keep all copies in sync:
#   plugins/autocoder/scripts/append-to-history.sh
#   plugins/modernize/scripts/append-to-history.sh
#   .agent/scripts/append-to-history.sh
#   plugins/modernize/protocols/protocols-overview.md (inline heredoc)
# When updating this file, update ALL copies above.

# Parse flags
BACKEND="auto"
HISTORY_FILE="docs/HISTORY.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      BACKEND="$2"
      shift 2
      ;;
    --history-file)
      HISTORY_FILE="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

# Validate positional parameters
if [ $# -ne 4 ]; then
    echo "Error: Requires exactly 4 positional parameters"
    echo "Usage: $0 [--backend file|github|auto] [--history-file PATH] \"TITLE\" \"WHAT_CHANGED\" \"WHY_CHANGED\" \"IMPACT\""
    exit 1
fi

TITLE="$1"
WHAT_CHANGED="$2"
WHY_CHANGED="$3"
IMPACT="$4"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Resolve backend from $ISSUE_SOURCE if auto
if [ "$BACKEND" = "auto" ]; then
  if [ "${ISSUE_SOURCE:-}" = "github" ]; then
    BACKEND="github"
  else
    BACKEND="file"
  fi
fi

if [ "$BACKEND" = "github" ]; then
  # Ensure the history-log label exists (idempotent — safe to call repeatedly)
  gh label create "history-log" --description "Autocoder history log" --color "0075ca" 2>/dev/null || true

  # Find or create the history-log issue
  HISTORY_ISSUE=$(gh issue list --label "history-log" --state open --limit 1 --json number --jq '.[0].number' 2>/dev/null)

  if [ -z "$HISTORY_ISSUE" ] || [ "$HISTORY_ISSUE" = "null" ]; then
    HISTORY_ISSUE=$(gh issue create \
      --label "history-log" \
      --title "Autocoder History Log" \
      --body "Auto-created by autocoder to track agent activity. Each comment is one history entry." \
      --json number --jq '.number' 2>/dev/null)
    echo "✅ Created history-log issue #${HISTORY_ISSUE}"
  fi

  # Post history entry as a comment
  gh issue comment "$HISTORY_ISSUE" --body "## ${TIMESTAMP} — ${TITLE}

**What Changed**: ${WHAT_CHANGED}

**Why Changed**: ${WHY_CHANGED}

**Impact**: ${IMPACT}"
  echo "✅ History entry posted to issue #${HISTORY_ISSUE}"

else
  # File backend
  # If given a bare filename (no directory component, e.g. "HISTORY.md"), resolve
  # to the main git worktree root so parallel fix-loop workers all write to one file.
  if [[ "$HISTORY_FILE" != */* ]]; then
    MAIN_WT=$(git worktree list --porcelain 2>/dev/null | grep -m1 '^worktree' | cut -d' ' -f2)
    if [ -n "$MAIN_WT" ] && [ "$MAIN_WT" != "$(pwd)" ]; then
      HISTORY_FILE="${MAIN_WT}/${HISTORY_FILE}"
    fi
  fi

  # Create file if it doesn't exist
  if [ ! -f "$HISTORY_FILE" ]; then
    HISTORY_DIR=$(dirname "$HISTORY_FILE")
    [ "$HISTORY_DIR" != "." ] && mkdir -p "$HISTORY_DIR"
    echo "# Project History" > "$HISTORY_FILE"
    echo "" >> "$HISTORY_FILE"
    echo "This file tracks all significant changes, migrations, and decisions." >> "$HISTORY_FILE"
    echo "" >> "$HISTORY_FILE"
  fi

  # Append entry
  cat >> "$HISTORY_FILE" << EOF

---

## $TIMESTAMP - $TITLE

**What Changed**: $WHAT_CHANGED

**Why Changed**: $WHY_CHANGED

**Impact**: $IMPACT

EOF
  echo "✅ Entry added to $HISTORY_FILE"
fi
```

- [ ] **Step 3: Make executable and verify the file backend works**

```bash
chmod +x scripts/append-to-history.sh
scripts/append-to-history.sh --backend file --history-file /tmp/test-history.md \
  "Test Entry" "Script updated to support backends" "Testing" "Script works"
cat /tmp/test-history.md
```

Expected: file exists containing `## ... - Test Entry` with the four fields.

- [ ] **Step 4: Verify backward-compat (no flags = writes to docs/HISTORY.md)**

```bash
mkdir -p /tmp/testdocs/docs
cd /tmp/testdocs
bash /Users/Laird.Popkin/src/agents/scripts/append-to-history.sh \
  "Compat Test" "Old-style call" "Testing" "Backward compat"
cat docs/HISTORY.md
cd /Users/Laird.Popkin/src/agents
rm -rf /tmp/testdocs
```

Expected: `docs/HISTORY.md` created with entry; no error output.

- [ ] **Step 5: Verify --backend auto uses ISSUE_SOURCE**

```bash
ISSUE_SOURCE=file scripts/append-to-history.sh \
  --backend auto --history-file /tmp/auto-test.md \
  "Auto Test" "Backend auto-detected" "Testing" "File backend selected"
cat /tmp/auto-test.md
rm /tmp/auto-test.md
```

Expected: file written; no GitHub calls attempted.

- [ ] **Step 6: Commit**

```bash
git add scripts/append-to-history.sh
git commit -m "feat: extend append-to-history.sh with --backend and --history-file flags

Adds GitHub backend (history-log issue), worktree-aware path resolution,
and backward-compatible default behavior for modernize.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Copy script to all plugin locations

**Files:**
- Create: `plugins/autocoder/scripts/append-to-history.sh`
- Create: `plugins/modernize/scripts/append-to-history.sh`
- Rewrite: `.agent/scripts/append-to-history.sh`

- [ ] **Step 1: Copy to autocoder scripts directory**

```bash
cp scripts/append-to-history.sh plugins/autocoder/scripts/append-to-history.sh
```

- [ ] **Step 2: Copy to modernize scripts directory (create dir if needed)**

```bash
mkdir -p plugins/modernize/scripts
cp scripts/append-to-history.sh plugins/modernize/scripts/append-to-history.sh
```

- [ ] **Step 3: Copy to .agent/scripts mirror**

```bash
cp scripts/append-to-history.sh .agent/scripts/append-to-history.sh
```

- [ ] **Step 4: Verify all four copies are identical**

```bash
md5sum scripts/append-to-history.sh \
       plugins/autocoder/scripts/append-to-history.sh \
       plugins/modernize/scripts/append-to-history.sh \
       .agent/scripts/append-to-history.sh
```

Expected: all four hashes identical.

- [ ] **Step 5: Commit**

```bash
git add plugins/autocoder/scripts/append-to-history.sh \
        plugins/modernize/scripts/append-to-history.sh \
        .agent/scripts/append-to-history.sh
git commit -m "feat: distribute append-to-history.sh to plugin script directories

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Add SYNC NOTE to modernize's inline heredoc in protocols-overview.md

**Files:**
- Modify: `plugins/modernize/protocols/protocols-overview.md`

- [ ] **Step 1: Find the heredoc in protocols-overview.md**

```bash
grep -n "append-to-history\|HISTORY_FILE\|#!/bin/bash" \
  plugins/modernize/protocols/protocols-overview.md | head -20
```

Note the line number where the heredoc for `append-to-history.sh` begins.

- [ ] **Step 2: Read that section**

Read from the line returned above through about 50 lines to see the full heredoc.

- [ ] **Step 3: Add SYNC NOTE comment as the second line of the heredoc**

Find the line `#!/bin/bash` inside the heredoc and add the SYNC NOTE immediately after it. The result should look like:

```bash
#!/bin/bash
# append-to-history.sh - Universal history logging
#
# SYNC NOTE: This inline copy must match plugins/modernize/scripts/append-to-history.sh
# and scripts/append-to-history.sh (canonical source). When either changes, update here.
```

Use the Edit tool with the exact old_string from Step 2 to make a targeted replacement.

- [ ] **Step 4: Verify the edit looks correct**

```bash
grep -A 8 "append-to-history.sh - Universal" \
  plugins/modernize/protocols/protocols-overview.md
```

Expected: SYNC NOTE comment appears after the shebang.

- [ ] **Step 5: Commit**

```bash
git add plugins/modernize/protocols/protocols-overview.md
git commit -m "docs: add SYNC NOTE to modernize protocols-overview heredoc

Points maintainers to the canonical script in plugins/modernize/scripts/.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 4: Add SCRIPT_DIR enforcement + logging to `full-regression-test.md`

**Files:**
- Modify: `plugins/autocoder/commands/full-regression-test.md`
- Modify: `.agent/workflows/full-regression-test.md`

- [ ] **Step 1: Read the Instructions section start**

```bash
sed -n '59,75p' plugins/autocoder/commands/full-regression-test.md
```

Expected: `## Instructions` header followed by the opening bash block starting with `TIMESTAMP=`.

- [ ] **Step 2: Insert SCRIPT_DIR + source block before TIMESTAMP**

Find the exact string:

```
```bash
# Timestamp for this test run
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
```

Replace with:

```
```bash
# Source issue config — exits with clear error if not configured
SCRIPT_DIR=$(
  if [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
source "${SCRIPT_DIR}/issue-fns.sh"
# ISSUE_SOURCE is now exported (or command has exited with error)

# Timestamp for this test run
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
```

- [ ] **Step 3: Read the end of the file**

```bash
tail -30 plugins/autocoder/commands/full-regression-test.md
```

Note the exact string containing `exit 0` at the end of the Instructions bash block.

- [ ] **Step 4: Add logging call before the final exit 0**

Find the exact string:

```bash
  echo "✅ All tests passed!"
  exit 0
fi
```

Replace with:

```bash
  echo "✅ All tests passed!"
  # Log successful run to history
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "Regression Test Run" \
    "Build: pass. Unit: ${UNIT_PASS:-?}/${UNIT_TOTAL:-?} passing. E2E: ${E2E_PASS:-?}/${E2E_TOTAL:-?} passing. New issues: ${NEW_ISSUES_COUNT:-0}." \
    "Scheduled regression run." \
    "All tests passing."
  exit 0
fi
```

And add a corresponding log before the `exit 1`:

Find:
```bash
  echo "⚠️  Some tests failed. Check GitHub issues for details."
  exit 1
```

Replace with:
```bash
  echo "⚠️  Some tests failed. Check GitHub issues for details."
  # Log failed run to history
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "Regression Test Run (failures)" \
    "Build: ${BUILD_EXIT:-?}. Unit: ${UNIT_PASS:-?}/${UNIT_TOTAL:-?} passing. E2E: ${E2E_PASS:-?}/${E2E_TOTAL:-?} passing. New issues: ${NEW_ISSUES_COUNT:-0}." \
    "Scheduled regression run." \
    "Test failures detected. Issues created for failures."
  exit 1
```

- [ ] **Step 5: Mirror both changes to .agent/workflows/full-regression-test.md**

Read `.agent/workflows/full-regression-test.md` first, then apply the same two edits (SCRIPT_DIR block + logging calls). The file should be structurally identical to the Claude version.

- [ ] **Step 6: Commit**

```bash
git add plugins/autocoder/commands/full-regression-test.md \
        .agent/workflows/full-regression-test.md
git commit -m "feat: add issue-source enforcement and history logging to full-regression-test

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 5: Add logging to `fix.md` — simple fix paths

**Files:**
- Modify: `plugins/autocoder/commands/fix.md`

The simple fix path has two resolution points: PR creation and auto-merge. Both are inside a bash block in "Step 2A: Simple Issue - Direct Fix".

- [ ] **Step 1: Read the simple fix PR path context (around line 738-742)**

```bash
sed -n '736,745p' plugins/autocoder/commands/fix.md
```

Expected: the `echo "✅ PR created for issue #$ISSUE_NUM — awaiting review"` line followed by `else`.

- [ ] **Step 2: Add logging after the simple PR creation**

Find this exact string:
```
  echo "✅ PR created for issue #$ISSUE_NUM — awaiting review"
else
  # Auto-merge: switch back to parent branch and merge
  git checkout "$PARENT_BRANCH"
  git merge --no-ff "feature/issue-${ISSUE_NUM}"
```

Replace with:
```
  echo "✅ PR created for issue #$ISSUE_NUM — awaiting review"
  # Log to history
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "PR #${ISSUE_NUM}: ${ISSUE_TITLE}" \
    "PR created on branch feature/issue-${ISSUE_NUM}." \
    "${ISSUE_BODY:0:150}" \
    "Awaiting code review."
else
  # Auto-merge: switch back to parent branch and merge
  git checkout "$PARENT_BRANCH"
  git merge --no-ff "feature/issue-${ISSUE_NUM}"
```

- [ ] **Step 3: Read the simple fix merge path context (around line 763-767)**

```bash
sed -n '760,770p' plugins/autocoder/commands/fix.md
```

Expected: the agents-ui status file write line followed by `fi`.

- [ ] **Step 4: Add logging after the simple merge completion**

Find this exact string (inside the simple fix block):
```
echo "{\"status\": \"idle\", \"issue\": ${ISSUE_NUM}, \"title\": \"${ISSUE_TITLE}\", \"completed\": \"$(date -Iseconds)\"}" > "/tmp/agents-ui/${SESSION_NAME}.json"
fi
```

**Important**: there are two similar `fi` blocks in fix.md (simple and complex). This is the first one, inside Step 2A. Use enough surrounding context in the old_string to be unambiguous. Add immediately before the `fi`:

```
echo "{\"status\": \"idle\", \"issue\": ${ISSUE_NUM}, \"title\": \"${ISSUE_TITLE}\", \"completed\": \"$(date -Iseconds)\"}" > "/tmp/agents-ui/${SESSION_NAME}.json"
  # Log to history
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "Fix #${ISSUE_NUM}: ${ISSUE_TITLE}" \
    "Resolved on feature/issue-${ISSUE_NUM}. Merged to ${PARENT_BRANCH}." \
    "${ISSUE_BODY:0:150}" \
    "All tests passing. Branch merged and deleted."
fi
```

- [ ] **Step 5: Verify both insertions look correct**

```bash
grep -n "append-to-history\|Log to history" plugins/autocoder/commands/fix.md
```

Expected: 2 matches so far, around lines 740 and 765.

- [ ] **Step 6: Commit progress**

```bash
git add plugins/autocoder/commands/fix.md
git commit -m "feat: add history logging to fix.md simple-fix resolution paths

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 6: Add logging to `fix.md` — complex fix paths and blocking path

**Files:**
- Modify: `plugins/autocoder/commands/fix.md`

- [ ] **Step 1: Read the complex fix PR path context (around line 928-932)**

```bash
sed -n '926,935p' plugins/autocoder/commands/fix.md
```

Expected: `echo "✅ PR created for issue #$ISSUE_NUM — awaiting review"` followed by `else` in the complex fix block.

- [ ] **Step 2: Add logging after the complex PR creation**

Find this exact string (use `# Remove 'working' label (PR is ready for review)` as anchor to distinguish from the simple path):
```
  # Remove 'working' label (PR is ready for review)
  issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
  echo "✅ PR created for issue #$ISSUE_NUM — awaiting review"
else
  # Auto-merge: switch back to parent branch and merge
  git checkout "$PARENT_BRANCH"
  git merge --no-ff "feature/issue-${ISSUE_NUM}"

  # Push parent branch
  git push

  # Clean up feature branch (local and remote)
  git branch -d "feature/issue-${ISSUE_NUM}"
  git push origin --delete "feature/issue-${ISSUE_NUM}" 2>/dev/null || true

  # Remove 'working' label and close issue with detailed explanation
```

Replace with the same content plus a logging call after `echo "✅ PR created..."`:
```
  # Remove 'working' label (PR is ready for review)
  issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
  echo "✅ PR created for issue #$ISSUE_NUM — awaiting review"
  # Log to history
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "PR #${ISSUE_NUM}: ${ISSUE_TITLE}" \
    "PR created on branch feature/issue-${ISSUE_NUM}." \
    "${ISSUE_BODY:0:150}" \
    "Awaiting code review."
else
  # Auto-merge: switch back to parent branch and merge
  git checkout "$PARENT_BRANCH"
  git merge --no-ff "feature/issue-${ISSUE_NUM}"

  # Push parent branch
  git push

  # Clean up feature branch (local and remote)
  git branch -d "feature/issue-${ISSUE_NUM}"
  git push origin --delete "feature/issue-${ISSUE_NUM}" 2>/dev/null || true

  # Remove 'working' label and close issue with detailed explanation
```

- [ ] **Step 3: Read the complex fix merge path context (around line 964-968)**

```bash
sed -n '962,970p' plugins/autocoder/commands/fix.md
```

Expected: the second agents-ui status file write followed by `fi` then the closing ` ``` `.

- [ ] **Step 4: Add logging after the complex merge completion**

Find this exact string (use `Auto-resolved by autonomous fix workflow with superpowers` as anchor):
```
🤖 Auto-resolved by autonomous fix workflow with superpowers"

# Write completion status file for agents-ui TUI monitoring
SESSION_NAME=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || echo "unknown")
echo "{\"status\": \"idle\", \"issue\": ${ISSUE_NUM}, \"title\": \"${ISSUE_TITLE}\", \"completed\": \"$(date -Iseconds)\"}" > "/tmp/agents-ui/${SESSION_NAME}.json"
fi
```

Replace with:
```
🤖 Auto-resolved by autonomous fix workflow with superpowers"

# Write completion status file for agents-ui TUI monitoring
SESSION_NAME=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || echo "unknown")
echo "{\"status\": \"idle\", \"issue\": ${ISSUE_NUM}, \"title\": \"${ISSUE_TITLE}\", \"completed\": \"$(date -Iseconds)\"}" > "/tmp/agents-ui/${SESSION_NAME}.json"
  # Log to history
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "Fix #${ISSUE_NUM}: ${ISSUE_TITLE}" \
    "Resolved on feature/issue-${ISSUE_NUM}. Merged to ${PARENT_BRANCH}." \
    "${ISSUE_BODY:0:150}" \
    "All tests passing. Branch merged and deleted."
fi
```

- [ ] **Step 5: Add logging to the blocking path (around line 1097)**

```bash
sed -n '1092,1104p' plugins/autocoder/commands/fix.md
```

Find this exact string:
```
  bash "$SCRIPT_DIR/add-blocking-label.sh" "$ISSUE_NUM" "$BLOCKING_LABEL" "$BLOCKING_REASON"

  echo "⏭️  Skipping to next issue..."
```

Replace with:
```
  bash "$SCRIPT_DIR/add-blocking-label.sh" "$ISSUE_NUM" "$BLOCKING_LABEL" "$BLOCKING_REASON"
  # Log to history
  "${SCRIPT_DIR}/append-to-history.sh" --history-file "HISTORY.md" --backend auto \
    "Blocked #${ISSUE_NUM}: ${ISSUE_TITLE}" \
    "Added label: ${BLOCKING_LABEL}." \
    "${BLOCKING_REASON:0:200}" \
    "Requires human review before proceeding."

  echo "⏭️  Skipping to next issue..."
```

- [ ] **Step 6: Verify all 5 logging insertions are present**

```bash
grep -n "append-to-history\|Log to history" plugins/autocoder/commands/fix.md
```

Expected: 5 matches at approximately lines 741, 766, 930, 966, 1098.

- [ ] **Step 7: Commit**

```bash
git add plugins/autocoder/commands/fix.md
git commit -m "feat: add history logging to fix.md complex-fix and blocking paths

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 7: Mirror fix.md changes to `.agent/workflows/fix.md`

**Files:**
- Modify: `.agent/workflows/fix.md`

- [ ] **Step 1: Read .agent/workflows/fix.md around the same regions**

```bash
grep -n "append-to-history\|PR created for issue\|Auto-resolved by autonomous\|add-blocking-label" \
  .agent/workflows/fix.md | head -20
```

This shows whether the Antigravity mirror has the same structure as the Claude version.

- [ ] **Step 2: Apply the same 5 logging insertions as Tasks 5 and 6**

Apply each of the 5 insertions from Tasks 5 and 6 to `.agent/workflows/fix.md`, using the same old_string/new_string pairs. The file structure should be identical to `plugins/autocoder/commands/fix.md`.

After each insertion, verify with:
```bash
grep -n "append-to-history\|Log to history" .agent/workflows/fix.md
```

- [ ] **Step 3: Apply full-regression-test.md changes to .agent/workflows/full-regression-test.md**

Apply the same two changes from Task 4 (SCRIPT_DIR block + two logging calls) to `.agent/workflows/full-regression-test.md`.

Verify:
```bash
grep -n "append-to-history\|issue-fns.sh\|SCRIPT_DIR" .agent/workflows/full-regression-test.md
```

Expected: SCRIPT_DIR block near the top, two append-to-history calls near the bottom.

- [ ] **Step 4: Commit**

```bash
git add .agent/workflows/fix.md .agent/workflows/full-regression-test.md
git commit -m "feat: mirror fix.md and full-regression-test.md history logging to .agent/workflows

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 8: Create `plugins/autocoder/commands/retro.md`

**Files:**
- Create: `plugins/autocoder/commands/retro.md`

- [ ] **Step 1: Read fix.md's optional-skills prelude block to copy it exactly**

```bash
sed -n '1,25p' plugins/autocoder/commands/fix.md
```

Copy the `<!-- BEGIN optional-skills-prelude v1 -->` block through `<!-- END optional-skills-prelude v1 -->` for use in Step 2.

- [ ] **Step 2: Create retro.md**

Write `plugins/autocoder/commands/retro.md` with the following content (substitute the exact optional-skills-prelude block from Step 1 in the indicated spot):

```markdown
# Autocoder Retrospective Analysis

Analyze accumulated project history to produce 3–5 specific, evidence-backed recommendations for improving the autocoder workflow. Output: `IMPROVEMENTS.md`.

## Optional skill enhancements

<!-- BEGIN optional-skills-prelude v1 — keep in sync across all command files; see plugins/shared/optional-skills-prelude.md -->
[paste exact block from fix.md here]
<!-- END optional-skills-prelude v1 -->

<!-- BEGIN optional-skills-mapping retro v1 — keep in sync between Claude/Antigravity mirrors of this command -->

`/retro` produces a **Document** deliverable (IMPROVEMENTS.md). Skill mapping:

| Step | Skill mapping |
|---|---|
| Synthesize findings into recommendations | `completion-review` (always) |

<!-- END optional-skills-mapping retro v1 -->

## Usage

```bash
# Analyze last 12 months of history
/retro

# Scope to a specific date range
/retro --since 2026-01-01
```

## What This Does

1. Sources issue configuration — exits immediately if not configured
2. Reads history log (`HISTORY.md` or `history-log` GitHub issue)
3. Analyzes git log for user corrections, reverts, repeated fix attempts
4. Queries issue tracker for blocking patterns and reopened issues
5. Identifies recurring test failures from history
6. Synthesizes 3–5 evidence-backed recommendations
7. Writes `IMPROVEMENTS.md` to the project root

## Data Sources

**History log** — primary source of what happened:
- File backend: `HISTORY.md` in project root (written by `/fix` and `/full-regression-test`)
- GitHub backend: comments on the `history-log` labeled issue

**Git log** — signals of agent behavior quality:
- Reverts and correction keywords in commit messages
- Feature branches attempted more than once for the same issue

**Issue tracker** — patterns across all work:
- Currently blocked issues, broken down by blocking label
- Proposal creation and approval rates

**Test failure patterns** — extracted from history log:
- Regression test entries showing repeated failures on the same area

## Instructions

```bash
# Parse arguments
SINCE_DATE=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case ${args[i]} in
    --since)
      SINCE_DATE="${args[i+1]}"
      ((i++))
      ;;
  esac
done

# Source issue config (exits with clear error if not configured)
SCRIPT_DIR=$(
  if [ -d "$(pwd)/plugins/autocoder/scripts" ]; then echo "$(pwd)/plugins/autocoder/scripts"
  elif [ -d "$(pwd)/.claude-plugin/plugins/autocoder/scripts" ]; then echo "$(pwd)/.claude-plugin/plugins/autocoder/scripts"
  else find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" 2>/dev/null | sort -V | tail -1
  fi
)
source "${SCRIPT_DIR}/issue-fns.sh"
# ISSUE_SOURCE is now exported (or command has exited with error)

echo "🔍 Autocoder Retrospective Analysis"
echo "======================================"
echo "Issue source: $ISSUE_SOURCE"
[ -n "$SINCE_DATE" ] && echo "Analyzing since: $SINCE_DATE" || echo "Analyzing: last 12 months"
echo ""
```

### Phase 1: Collect Data (~15 min)

**1.1 Read history log**

For file backend:
```bash
if [ -f "HISTORY.md" ]; then
  HISTORY_ENTRIES=$(grep -c "^## " HISTORY.md 2>/dev/null || echo "0")
  echo "📖 Found $HISTORY_ENTRIES history entries in HISTORY.md"
  cat HISTORY.md
else
  echo "⚠️  No HISTORY.md found — history is sparse."
  echo "    Run /fix or /full-regression-test to begin building history."
fi
```

For GitHub backend (`$ISSUE_SOURCE = "github"`):
```bash
HISTORY_ISSUE=$(gh issue list --label "history-log" --state open --limit 1 \
  --json number --jq '.[0].number' 2>/dev/null)
if [ -n "$HISTORY_ISSUE" ] && [ "$HISTORY_ISSUE" != "null" ]; then
  echo "📖 Reading history from issue #${HISTORY_ISSUE}..."
  gh issue view "$HISTORY_ISSUE" --comments --json comments \
    --jq '.comments[] | "---\n" + .body' 2>/dev/null
else
  echo "⚠️  No history-log issue found — history is empty."
fi
```

**1.2 Analyze git log**

```bash
SINCE_FLAG="--since=${SINCE_DATE:-1 year ago}"

echo ""
echo "📊 Git log analysis"
echo "==================="

COMMIT_COUNT=$(git log --oneline $SINCE_FLAG | wc -l | tr -d ' ')
echo "Commits in range: $COMMIT_COUNT"

echo ""
echo "--- Correction/revert commits ---"
git log --all --oneline $SINCE_FLAG \
  --grep="revert\|correct\|actually\|oops\|undo\|mistake" \
  --regexp-ignore-case | head -20

echo ""
echo "--- Issues with multiple fix attempts ---"
git log --all --format="%D" $SINCE_FLAG \
  | grep -oE "feature/issue-[0-9]+" \
  | sort | uniq -c | sort -rn \
  | awk '$1 > 1 {print}' | head -10
```

**1.3 Analyze issue tracker**

```bash
echo ""
echo "📊 Issue tracker analysis"
echo "========================="

issue_list --state open --limit 200 > /tmp/retro-open.json 2>/dev/null || echo "[]" > /tmp/retro-open.json

python3 << 'PYTHON'
import json

open_issues = json.load(open('/tmp/retro-open.json'))
blocking_labels = ['needs-design', 'too-complex', 'needs-clarification', 'needs-approval', 'future']

by_label = {}
for issue in open_issues:
    for lbl in issue.get('labels', []):
        if lbl['name'] in blocking_labels:
            by_label[lbl['name']] = by_label.get(lbl['name'], 0) + 1

proposals = sum(1 for i in open_issues if any(l['name'] == 'proposal' for l in i.get('labels', [])))

print("Open blocking issues:")
for k, v in sorted(by_label.items(), key=lambda x: -x[1]):
    print(f"  {k}: {v}")
print(f"\nOpen proposals awaiting approval: {proposals}")
PYTHON

# History-derived stats
if [ -f "HISTORY.md" ]; then
  FIXED=$(grep -c "^## .* - Fix #" HISTORY.md 2>/dev/null || echo "0")
  BLOCKED=$(grep -c "^## .* - Blocked #" HISTORY.md 2>/dev/null || echo "0")
  PRS=$(grep -c "^## .* - PR #" HISTORY.md 2>/dev/null || echo "0")
  REGRESSIONS=$(grep -c "^## .* - Regression Test Run" HISTORY.md 2>/dev/null || echo "0")
  echo ""
  echo "History stats: fixes=$FIXED, PRs=$PRS, blocked=$BLOCKED, regression-runs=$REGRESSIONS"
fi
```

**1.4 Test failure patterns from history**

```bash
echo ""
echo "📊 Test failure patterns"
echo "========================"
if [ -f "HISTORY.md" ]; then
  echo "--- Regression test run summaries ---"
  grep -A 5 "^## .* - Regression Test Run" HISTORY.md | head -60
fi
```

### Phase 2: Identify Patterns (~10 min)

Based on the collected data, cluster signals into categories and score each by frequency × impact (both 1–10):

- **Agent behavior**: Wrong approaches, skipped context, requirement misunderstandings, wasted effort
- **Protocol gaps**: Blocking detection misses, escalation failures, fix strategy weaknesses
- **Recurring failures**: Tests or issue types that re-appear after being "fixed"
- **Automation opportunities**: Repeated manual patterns that could be scripted

Select the top 3–5 highest-scoring patterns.

### Phase 3: Develop Recommendations (~15 min)

For each top pattern:

```
**Problem**: [What goes wrong and how often — include a count if data supports it]

**Evidence**:
- [Specific example 1: issue number, git commit, or HISTORY.md entry]
- [Specific example 2]

**Proposed Change**: [Exact change — name the file and section to modify]

**Change Type**: Protocol Update | Agent Behavior | Automation | New Script

**Expected Impact**: [Quantified: e.g., "Reduce needs-clarification blocks by ~30%"]

**Affected Components**:
- `plugins/autocoder/commands/fix.md` — [which section]
```

### Phase 4: Write IMPROVEMENTS.md (~5 min)

Write `IMPROVEMENTS.md` to the project root:

```markdown
# Autocoder Process Improvement Recommendations

**Date**: YYYY-MM-DD
**Status**: Proposed
**Retrospective Period**: [start date] – [end date or "present"]
**Issue Source**: [file|github]

---

## Context

Following [N] fixes, [N] PRs, [N] blocked issues, and [N] regression test runs,
the autocoder agent analyzed its history to identify process improvements.

**Analysis Sources**:
- History log: [N] entries reviewed
- Git log: [N] commits from [period]
- Issue tracker: [N] open issues ([N] blocked), [N] proposals pending

**Key Metrics**:
- Autonomous fix rate: [N / (N+N+N)] = [X]%
- Block rate: needs-design=[N], too-complex=[N], needs-clarification=[N]
- Issues requiring multiple attempts: [N]

---

## Recommendations

### Recommendation 1: [Title]

[Body per Phase 3 template]

---

[Repeat for each recommendation, separated by `---`]

---

## Summary

| # | Recommendation | Impact | Effort | Priority |
|---|---|---|---|---|
| 1 | [title] | High | Low | P0 |
| 2 | [title] | Medium | Low | P1 |
| 3 | [title] | Medium | Medium | P1 |

---

## Next Steps

1. Review each recommendation above
2. Apply approved changes to `plugins/autocoder/commands/` manually
3. Run `/retro` again after 20+ more issues to measure improvement

---
*Generated by `/retro` — autocoder retrospective analysis*
```

After writing the file, print:

```
✅ IMPROVEMENTS.md written to project root.

Review the recommendations, apply the approved changes to plugins/autocoder/commands/,
then run /retro again in a few weeks to measure improvement.
```
```

- [ ] **Step 3: Verify the file was created**

```bash
wc -l plugins/autocoder/commands/retro.md
head -5 plugins/autocoder/commands/retro.md
```

Expected: file exists, first line is `# Autocoder Retrospective Analysis`.

- [ ] **Step 4: Commit**

```bash
git add plugins/autocoder/commands/retro.md
git commit -m "feat: add /retro command to autocoder plugin

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 9: Create `.agent/workflows/retro.md`

**Files:**
- Create: `.agent/workflows/retro.md`

- [ ] **Step 1: Check an existing .agent workflow for any structural differences**

```bash
head -10 .agent/workflows/fix.md
```

Note any differences from `plugins/autocoder/commands/fix.md` (typically none beyond minor wording).

- [ ] **Step 2: Copy retro.md to the .agent mirror**

```bash
cp plugins/autocoder/commands/retro.md .agent/workflows/retro.md
```

- [ ] **Step 3: Verify the copy**

```bash
diff plugins/autocoder/commands/retro.md .agent/workflows/retro.md
```

Expected: no diff.

- [ ] **Step 4: Commit**

```bash
git add .agent/workflows/retro.md
git commit -m "feat: add .agent/workflows/retro.md (Antigravity mirror)

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 10: Register `/retro` in marketplace.json and document in CLAUDE.md

**Files:**
- Modify: `.claude-plugin/marketplace.json`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Read current marketplace.json**

```bash
python3 -c "
import json
d = json.load(open('.claude-plugin/marketplace.json'))
print('marketplace:', d['version'])
for p in d['plugins']:
    print(p['name'], p['version'], '→ commands:', p.get('commands', []))
"
```

Expected output shows `marketplace: 3.19.0`, `autocoder 4.0.0`.

- [ ] **Step 2: Add `retro` to autocoder's commands list and bump both versions**

```bash
python3 << 'PYTHON'
import json

path = '.claude-plugin/marketplace.json'
d = json.load(open(path))

# Bump marketplace root version: 3.19.0 → 3.20.0
d['version'] = '3.20.0'

# Find autocoder plugin and update it
for p in d['plugins']:
    if p['name'] == 'autocoder':
        # Bump plugin version: 4.0.0 → 4.1.0
        p['version'] = '4.1.0'
        # Add retro to commands list if not already present
        cmds = p.get('commands', [])
        if 'retro' not in cmds:
            cmds.append('retro')
        p['commands'] = cmds
        break

json.dump(d, open(path, 'w'), indent=2)
print('Updated marketplace.json')
PYTHON
```

- [ ] **Step 3: Verify the changes**

```bash
python3 -c "
import json
d = json.load(open('.claude-plugin/marketplace.json'))
print('marketplace:', d['version'])
for p in d['plugins']:
    print(p['name'], p['version'], '→ commands:', p.get('commands', []))
"
```

Expected: `marketplace: 3.20.0`, `autocoder 4.1.0`, `retro` in autocoder's commands list.

- [ ] **Step 4: Add `/retro` documentation to CLAUDE.md**

Read the Commands section in CLAUDE.md to find where the other autocoder commands are listed.

Find this exact string (or the equivalent section heading for autocoder commands):
```
### Primary Workflow Commands
```

After the existing command list under that section (or wherever the other autocoder commands like `/fix` and `/fix-loop` are documented), add:

```markdown
### Retrospective

```bash
# Analyze accumulated history and produce workflow improvement recommendations
/retro

# Scope to a specific date range
/retro --since 2026-01-01
# Output: IMPROVEMENTS.md with 3-5 evidence-backed recommendations
```

**Recommended cadence**: Run after every 20–30 issues processed. Apply approved recommendations to `plugins/autocoder/commands/` manually.
```

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/marketplace.json CLAUDE.md
git commit -m "feat: register /retro command; bump autocoder 4.1.0, marketplace 3.20.0

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| Extend `append-to-history.sh` with `--backend`/`--history-file` flags | Task 1 |
| GitHub backend: create label + issue + comment | Task 1 |
| Worktree-aware path resolution (bare filename → main worktree) | Task 1 |
| Backward compat (no flags = `docs/HISTORY.md`) | Task 1 (verified) |
| Distribute to plugin locations + `.agent/scripts/` | Task 2 |
| SYNC NOTE in modernize's `protocols-overview.md` heredoc | Task 3 |
| Issue-source enforcement in `full-regression-test.md` | Task 4 |
| Logging in `full-regression-test.md` (pass + fail) | Task 4 |
| Logging in `fix.md` — simple PR path | Task 5 |
| Logging in `fix.md` — simple merge path | Task 5 |
| Logging in `fix.md` — complex PR path | Task 6 |
| Logging in `fix.md` — complex merge path | Task 6 |
| Logging in `fix.md` — blocking path | Task 6 |
| Mirror `fix.md` + `full-regression-test.md` to `.agent/workflows/` | Task 7 |
| Create `plugins/autocoder/commands/retro.md` | Task 8 |
| Create `.agent/workflows/retro.md` | Task 9 |
| Register retro command in `marketplace.json` | Task 10 |
| Bump plugin + marketplace versions | Task 10 |
| Document in `CLAUDE.md` | Task 10 |

All spec requirements covered. No gaps found.

**Placeholder scan:** No TBDs, TODOs, or "similar to Task N" references. All code blocks are complete.

**Type consistency:** `SCRIPT_DIR`, `ISSUE_SOURCE`, `ISSUE_NUM`, `ISSUE_TITLE`, `ISSUE_BODY`, `PARENT_BRANCH` are all variables already in scope in `fix.md` at the insertion points. `BLOCKING_LABEL` and `BLOCKING_REASON` are in scope at the blocking insertion point. The `append-to-history.sh` call signature (4 positional args after flags) is consistent across all call sites.
