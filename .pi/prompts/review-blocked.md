---
description: Interactive planning session to review and unblock issues that fix-loop has labeled with blocking tags. This command is designed to run in parallel with `/fix-loop` in a separate terminal session
---
<!-- Generated from plugins/autocoder/commands/review-blocked.md by scripts/package-plugin-scripts.py. Edit the source. -->

# Review Blocked Issues

Interactive planning session to review and unblock issues that fix-loop has labeled with blocking tags. This command is designed to run in parallel with `/fix-loop` in a separate terminal session.

## Usage

```bash
# Review all blocked issues (priority-first)
/review-blocked

# Filter to specific blocking label
/review-blocked --label needs-design
/review-blocked --label needs-approval
/review-blocked --label needs-clarification
/review-blocked --label too-complex
/review-blocked --label future
/review-blocked --label proposal

# Filter to specific priority
/review-blocked --priority P0
/review-blocked --priority P1

# Jump directly to a specific issue
/review-blocked 123

# Prepare analyses for later review, asking nothing (combines with the filters above)
/review-blocked --prepare
/review-blocked --prepare --label needs-design
```

## What This Does

1. **Fetches blocked issues** - Finds all open issues with blocking labels (`needs-approval`, `needs-design`, `needs-clarification`, `too-complex`, `future`, `proposal`)
2. **Shows overview** - Groups by blocking type and priority, shows counts
3. **Proposes highest priority** - Starts with P0, then P1, then P2, then P3
4. **Analyzes the issue** - Reads full context, explains why it's blocked
5. **Presents recommendations** - Shows 2-3 approaches with pros/cons
6. **Gets your decision** - Approve, explore further, reject, or skip
7. **Updates labels** - Removes blocking label when approved, closes if rejected
8. **Continues** - Moves to next blocked issue or exits

## Prepare Mode (`--prepare`)

`--prepare` is the unattended half of the review (#312, part of #308): the agent
analyses every blocked issue now, and a human reviews later, in the review page
(`/review-blocked-gui`, which starts `review-blocked-server.py`) or in the interactive flow below. It asks **no**
question (never AskUserQuestion), changes no label and posts no comment. It only
writes the analysis cache (`blocked-analysis-cache.py`).

Each analysis is stored under the issue's **analysis key**, which
`review-blocked-server.py --key N` prints: the issue's `updatedAt` when the
backend reports one, otherwise a hash of its title, body, labels and comments.
The review page looks analyses up by the same key, so it shows them as fresh,
and any change to the issue (such as a new comment) makes the cached analysis stale.
An issue whose cached analysis is still fresh is skipped. A stale or missing one
is (re)generated.

Run the Instructions block below first; with `--prepare` it prints
`PREPARE_MODE=true` and saves the issue list, printing its path as `BLOCKED_FILE=...`.
Each block below runs in a fresh shell, so set `BLOCKED_FILE` to that path in this
block too, and set `SCRIPT_DIR` in every block to the directory the Instructions
block resolved (or re-run that block's `SCRIPT_DIR=$(...)` lines). The blocks stop
at their first line while either is unset; without that guard every call would
resolve to `/review-blocked-server.py` and report every issue as `KEY_FAILED`.
Then sort the issues into fresh (skipped) and to-analyse:

```bash
: "${SCRIPT_DIR:?set SCRIPT_DIR to the path the Instructions block resolved}"
: "${BLOCKED_FILE:?set BLOCKED_FILE to the path the fetch block printed}"
for ISSUE_NUM in $(python3 -c "import json, sys; print(' '.join(str(i['number']) for i in json.load(sys.stdin)['issues']))" < "$BLOCKED_FILE"); do
  if ! KEY=$(python3 "$SCRIPT_DIR/review-blocked-server.py" --key "$ISSUE_NUM"); then
    echo "KEY_FAILED #$ISSUE_NUM"
  elif python3 "$SCRIPT_DIR/blocked-analysis-cache.py" get "$ISSUE_NUM" --updated-at "$KEY" >/dev/null 2>&1; then
    echo "FRESH #$ISSUE_NUM"
  else
    echo "ANALYSE #$ISSUE_NUM $KEY"
  fi
done
rm -f "$BLOCKED_FILE"   # prepare mode is done with the list once it is sorted
```

For each `ANALYSE` line, do the analysis Step 2 describes (read the issue and its
comments, read the code it names, find 2-3 approaches, pick one), then write it
as JSON in the cache's schema and store it under that line's key (`KEY` below):

```bash
: "${SCRIPT_DIR:?set SCRIPT_DIR to the path the Instructions block resolved}"
ANALYSIS=$(mktemp "${TMPDIR:-/tmp}/review-blocked-analysis.XXXXXX")
cat > "$ANALYSIS" <<'JSON'
{"summary": "<one line: what the issue needs decided>",
 "options": [
   {"title": "<approach>", "pros": ["<benefit>"], "cons": ["<drawback>"], "effort": "<Small|Medium|Large>"},
   {"title": "<approach>", "pros": ["<benefit>"], "cons": ["<drawback>"], "effort": "<Small|Medium|Large>"}
 ],
 "recommended": 0}
JSON
python3 "$SCRIPT_DIR/blocked-analysis-cache.py" put "$ISSUE_NUM" --updated-at "$KEY" --file "$ANALYSIS"
rm -f "$ANALYSIS"
```

`options` holds 2 or 3 approaches and `recommended` is the index of the one you
recommend. `put` refuses a malformed analysis (exit 2) and names what is wrong;
fix the JSON and run `put` again. After the last issue, print how many analyses
were written, how many were skipped as fresh, and how many failed (`KEY_FAILED`,
or a `put` you could not fix), then stop.

## Blocking Labels

These labels indicate why fix-loop cannot autonomously work on an issue:

| Label | When Applied | Example Scenario |
|-------|--------------|------------------|
| `needs-approval` | Architectural decisions, major changes, security implications | "Should we migrate from REST to GraphQL?" |
| `needs-design` | Requirements unclear, multiple valid approaches, needs design phase | "Add user dashboard" (what features? layout?) |
| `needs-clarification` | Incomplete information, missing context, questions needed | "Fix the bug in checkout" (which bug? what's failing?) |
| `too-complex` | Beyond autonomous capability, requires deep expertise/judgment | "Refactor entire auth system for multi-tenancy" |
| `future` | Idea for future consideration, not ready for implementation | "Expose data via MCP server", research spikes |
| `proposal` | Proposed feature or change awaiting review | "Add dark mode support" (needs design review and approval) |

**Note**: Blocking labels are independent from priority labels. An issue can have both `P0` + `needs-design`.

## Interactive Review Flow

For each blocked issue, the command:

1. **Shows Context**
   - Issue title, number, priority, blocking label
   - Quote from fix-loop's comment explaining why it's blocked
   - Brief summary of what the issue is asking for

2. **Presents Analysis**
   - Why it's blocked (specific reason)
   - 2-3 recommended approaches with:
     - Description of what it involves
     - Pros (2-3 benefits)
     - Cons (1-2 drawbacks)
     - Effort estimation (Small/Medium/Large)
   - Recommendation with reasoning

3. **Asks for Decision**
   - **Approve Option [X]** - Remove blocking label, add comment with decision
   - **Explore further** - Use other skills like `/brainstorm`, `/q1-hypothesize`
   - **Reject** - Close issue with reason
   - **Skip** - Leave blocked, move to next

4. **Updates Issue**
   - If approved: Remove blocking label, add approval comment
   - If rejected: Close issue with rejection comment
   - If skipped: No changes, move to next

## Instructions

Start the interactive review session now:

```bash
# Resolve SCRIPT_DIR — see scripts/README.md#script-dir
SCRIPT_DIR=$(
  for d in "$(pwd)/.pi/scripts" \
           "$(pwd)/.agent/scripts" \
           "$(pwd)/plugins/autocoder/scripts" \
           "$(pwd)/.claude-plugin/plugins/autocoder/scripts"; do
    if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; exit 0; fi
  done
  # Fallback: the installed plugin. Only <ver>/scripts is a complete tree;
  # <ver>/skills/autocoder/scripts is a subset that sorts after it (#142).
  # Rank by the <ver> directory alone, not the whole path: with two marketplaces
  # in the cache, a whole-path sort lets the marketplace name decide (#201).
  find "$HOME/.claude/plugins/cache" -type d -name "scripts" -path "*/autocoder/*" -not -path "*/skills/*" 2>/dev/null \
    | while read -r d; do if [ -f "$d/issue-fns.sh" ] && [ -f "$d/fix-loop-gate.sh" ]; then echo "$d"; fi; done \
    | awk -F/ '{print $(NF-1) "\t" $0}' | sort -V -t$'\t' -k1,1 | tail -1 | cut -f2-
)
if [ ! -f "${SCRIPT_DIR}/issue-fns.sh" ]; then
  echo "autocoder: cannot locate issue-fns.sh (resolved SCRIPT_DIR='${SCRIPT_DIR}')" >&2
  exit 1
fi

echo "🏷️  Checking blocking labels..."
echo "🔍 Scanning for blocked issues..."
echo ""

# --prepare (see "Prepare Mode") is this command's flag, not a fetch filter.
PREPARE_MODE=false
FETCH_ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--prepare" ]; then PREPARE_MODE=true; else FETCH_ARGS+=("$arg"); fi
done
echo "PREPARE_MODE=$PREPARE_MODE"

# Fetch blocked issues using the script
BLOCKED_ISSUES=$(bash "$SCRIPT_DIR/fetch-blocked-issues.sh" "${FETCH_ARGS[@]}")

# Check if we found any issues
TOTAL_BLOCKED=$(echo "$BLOCKED_ISSUES" | python3 -c "import json,sys; print(json.load(sys.stdin)['total'])")

if [ "$TOTAL_BLOCKED" -eq 0 ]; then
  echo "✅ No blocked issues found!"
  echo ""
  echo "All issues are either:"
  echo "  - Ready for autonomous fix-loop to work on, or"
  echo "  - Already being worked on (have 'working' label)"
  echo ""
  exit 0
fi

# Show summary
echo "📊 Blocked Issues Overview"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

SUMMARY=$(echo "$BLOCKED_ISSUES" | python3 -c "
import json, sys
data = json.load(sys.stdin)
summary = data['summary']

for label, priorities in summary.items():
    if priorities:
        counts = [f'{count} {priority}' for priority, count in priorities.items()]
        print(f'{label}: {len(priorities)} priorities ({', '.join(counts)})')

print(f'\nTotal: {data[\"total\"]} blocked issues')
")

echo "$SUMMARY"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Save for use in review loop: a private file per session (#329), never a fixed
# /tmp path that another session on this host would overwrite. Each later block
# runs in a fresh shell: set BLOCKED_FILE there to the path printed here.
BLOCKED_FILE=$(mktemp "${TMPDIR:-/tmp}/autocoder-blocked-issues.XXXXXX") || exit 1
echo "$BLOCKED_ISSUES" > "$BLOCKED_FILE"
echo "BLOCKED_FILE=$BLOCKED_FILE"
```

With `PREPARE_MODE=true`, follow "Prepare Mode" above for every issue and stop; skip
the interactive loop below. Otherwise begin the interactive review loop. For each
blocked issue (starting with highest priority):

### Step 1: Present the Issue

Extract the highest priority blocked issue:

```bash
CURRENT_ISSUE=$(python3 -c "
import json, sys
data = json.load(sys.stdin)
if data['issues']:
    issue = data['issues'][0]
    print(json.dumps(issue))
" < "${BLOCKED_FILE:?set BLOCKED_FILE to the path the fetch block printed}")

if [ -z "$CURRENT_ISSUE" ]; then
  echo "✅ All blocked issues have been reviewed!"
  rm -f "$BLOCKED_FILE"
  exit 0
fi

ISSUE_NUM=$(echo "$CURRENT_ISSUE" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
ISSUE_TITLE=$(echo "$CURRENT_ISSUE" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
ISSUE_BODY=$(echo "$CURRENT_ISSUE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('body',''))")

BLOCKING_LABEL=$(echo "$CURRENT_ISSUE" | python3 -c "
import json, sys
issue = json.load(sys.stdin)
blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex', 'future', 'proposal']
labels = [l['name'] for l in issue.get('labels', [])]
for bl in blocking_labels:
    if bl in labels:
        print(bl)
        break
")

PRIORITY_LABEL=$(echo "$CURRENT_ISSUE" | python3 -c "
import json, sys
issue = json.load(sys.stdin)
priorities = ['P0', 'P1', 'P2', 'P3']
labels = [l['name'] for l in issue.get('labels', [])]
for p in priorities:
    if p in labels:
        print(p)
        break
")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Issue #${ISSUE_NUM}: ${ISSUE_TITLE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Priority: ${PRIORITY_LABEL}"
echo "Blocking: ${BLOCKING_LABEL}"
echo ""
```

### Step 2: Analyze the Issue

Read the issue context and look for fix-loop's explanation:

```bash
# Check if fix-loop left a comment explaining why it's blocked
FIXLOOP_COMMENT=$(echo "$CURRENT_ISSUE" | python3 -c "
import json, sys
issue = json.load(sys.stdin)
comments = issue.get('comments', [])
for comment in comments:
    body = comment.get('body', '')
    # Look for comments from automated systems or containing blocking keywords
    if any(keyword in body.lower() for keyword in ['blocked', 'cannot', 'requires human', 'needs approval', 'unclear']):
        print(body[:300])  # First 300 chars
        break
")

if [ -n "$FIXLOOP_COMMENT" ]; then
  echo "🤖 Fix-loop's Note:"
  echo "$FIXLOOP_COMMENT"
  echo ""
fi
```

Reuse a prepared analysis when there is a fresh one (see "Prepare Mode"):

```bash
: "${SCRIPT_DIR:?set SCRIPT_DIR to the path the Instructions block resolved}"
ANALYSIS_KEY=$(python3 "$SCRIPT_DIR/review-blocked-server.py" --key "$ISSUE_NUM" 2>/dev/null) || ANALYSIS_KEY=""
CACHED_ANALYSIS=""
if [ -n "$ANALYSIS_KEY" ]; then
  CACHED_ANALYSIS=$(python3 "$SCRIPT_DIR/blocked-analysis-cache.py" get "$ISSUE_NUM" --updated-at "$ANALYSIS_KEY" 2>/dev/null) || CACHED_ANALYSIS=""
fi
[ -n "$CACHED_ANALYSIS" ] && { echo "📦 Prepared analysis (fresh):"; echo "$CACHED_ANALYSIS"; }
```

If `CACHED_ANALYSIS` is set, present it in the format below: its `summary` as the
context, its `options` as the approaches and `options[recommended]` as the
recommendation. Do not re-derive it; read further only if the user asks. If it is
empty, analyze the issue yourself. You should:

1. **Read the full issue** - Understand title, body, any comments
2. **Determine why it's blocked** - Explain the specific reason based on the blocking label
3. **Research context** - If the issue mentions files/components, read relevant code
4. **Generate 2-3 approaches** - Consider different ways to solve this
5. **Make a recommendation** - Pick the best approach and explain why

Present your analysis in this format:

```markdown
## Issue #${ISSUE_NUM}: ${ISSUE_TITLE}

**Priority**: ${PRIORITY_LABEL}
**Blocking Reason**: ${BLOCKING_LABEL}

### Context
[2-3 sentence summary of what the issue is asking for]

### Why It's Blocked
[Specific reason: architectural choice needed, unclear requirements, too complex, etc.]

### Recommended Approaches

**Option A: [Approach Name]** (Recommended)
- Description: [What this approach involves]
- Pros: [2-3 benefits]
- Cons: [1-2 drawbacks]
- Effort: [Small/Medium/Large]

**Option B: [Alternative Approach]**
- Description: [What this approach involves]
- Pros: [2-3 benefits]
- Cons: [1-2 drawbacks]
- Effort: [Small/Medium/Large]

**Option C: [Another Alternative]** (if applicable)
- [Same structure]

### Recommendation
I recommend Option A because [specific reasoning based on project context, existing patterns, trade-offs].
```

### Step 3: Get User Decision

After presenting your analysis, use the AskUserQuestion tool to get the user's decision:

```
AskUserQuestion with:
- Question: "How would you like to proceed with issue #${ISSUE_NUM}?"
- Options:
  A) "Approve Option A (Recommended)" - "Remove blocking label and add approval comment. Fix-loop will implement this approach."
  B) "Approve Option B" - "Remove blocking label with this alternative approach."
  C) "Approve Option C" - (if 3 options presented)
  D) "Explore further" - "Ask more questions or use other skills (/brainstorm, /q1-hypothesize) before deciding."
  E) "Reject this issue" - "Close the issue as it shouldn't be worked on."
  F) "Skip for now" - "Leave blocked and move to next issue."
```

### Step 4: Process Decision

Based on user's choice:

**If Approved (Option A/B/C):**
```bash
: "${SCRIPT_DIR:?set SCRIPT_DIR to the path the Instructions block resolved}"
APPROVED_OPTION="[User's choice: A/B/C]"
APPROVED_APPROACH="[Name of the approach they chose]"

# Use the approve script
bash "$SCRIPT_DIR/approve-blocked-issue.sh" "$ISSUE_NUM" "$BLOCKING_LABEL" "$APPROVED_APPROACH"

echo ""
echo "   Fix-loop will work on this issue on its next iteration."
echo ""
```

**If Explore Further:**
```bash
echo ""
echo "💡 You can now use other skills to explore this issue:"
echo "   - /brainstorm for design discussion"
echo "   - /q1-hypothesize for systematic hypothesis generation"
echo "   - Ask follow-up questions about the issue"
echo ""
echo "When ready to make a decision, we can continue the review process."
echo ""

# Don't remove from queue yet - let user explore
exit 0
```

**If Rejected:**
```bash
: "${SCRIPT_DIR:?set SCRIPT_DIR to the path the Instructions block resolved}"
REJECT_REASON="[Ask user for rejection reason]"

# Use the reject script
bash "$SCRIPT_DIR/reject-blocked-issue.sh" "$ISSUE_NUM" "$REJECT_REASON"

echo ""
```

**If Skipped:**
```bash
echo ""
echo "⏭️  Skipped issue #${ISSUE_NUM}. Blocking label remains."
echo "   This issue will appear in the next /review-blocked session."
echo ""
```

### Step 5: Continue to Next Issue

After processing the current issue (unless user chose "Explore further"), remove it from the queue and continue:

```bash
# Remove processed issue from queue
: "${BLOCKED_FILE:?set BLOCKED_FILE to the path the fetch block printed}"
REMAINING_FILE=$(mktemp "${BLOCKED_FILE}.XXXXXX") || exit 1
python3 -c "
import json, sys
data = json.load(sys.stdin)
data['issues'] = data['issues'][1:]   # always valid JSON, so the last issue reads as 0 left
data['total'] = len(data['issues'])
print(json.dumps(data))
" < "$BLOCKED_FILE" > "$REMAINING_FILE"

mv "$REMAINING_FILE" "$BLOCKED_FILE"

REMAINING=$(python3 -c "import json,sys; print(json.load(sys.stdin)['total'])" < "$BLOCKED_FILE")

if [ "$REMAINING" -eq 0 ]; then
  echo "✅ All blocked issues have been reviewed!"
  echo ""
  rm -f "$BLOCKED_FILE"
  exit 0
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 ${REMAINING} blocked issue(s) remaining"
echo ""
```

Now repeat from Step 1 for the next blocked issue. Use the AskUserQuestion tool to ask:

```
"Continue to next blocked issue?"
Options:
- "Yes, continue" - Proceed to review the next issue
- "Stop for now" - Exit the review session
```

If user chooses "Yes, continue", repeat the process from Step 1. If "Stop for now", exit gracefully.

## Key Behaviors

- **Non-blocking**: This command runs independently from `/fix-loop`
- **Priority-first**: Always surfaces P0 before P1, P1 before P2, etc.
- **Lightweight analysis**: Quick recommendations, user can dive deeper with other skills
- **Clear state transitions**: Issues move from blocked → approved with proper label updates
- **Interactive**: Uses AskUserQuestion for all decisions
- **Contextual**: Reads code, past comments, related issues to inform recommendations
- **Flexible**: User can explore further before deciding

## Notes

- This command is designed to run in parallel with `/fix-loop` in a separate terminal
- Fix-loop will automatically pick up approved issues (blocking label removed) on its next iteration
- Use filtering options (`--label`, `--priority`) to focus on specific types of blocked issues
- The "Explore further" option allows you to use other skills like `/brainstorm` or `/q1-hypothesize` before making a decision
