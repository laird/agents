# /fix reference: decomposing an issue into sub-tasks

Moved out of the `/fix` command file (#240) because a worker rarely needs it.
The command keeps a pointer at each place this text used to be.

### Ultra-Complex Issues - Decompose into Sub-Tasks

This section is triggered both by the **task scope gate** (in the `/fix` command, at claim time) and by the
complexity assessment (Step 1) when you discover mid-implementation that the scope is larger than expected.

For issues too large for autonomous resolution (>100 test failures, major architecture changes, significant trade-off decisions, or issues that fail the scope gate):

**Decomposition rules — each sub-task MUST satisfy ALL of these:**

1. **Context fit**: Completable in one agent conversation (not "migrate everything", not "audit all files")
2. **Worktree independence**: Touches a distinct set of files from sibling sub-tasks — no sub-task may edit the same file as another sibling that could run concurrently. If two sub-tasks MUST touch the same file, sequence them (sub-task B depends on sub-task A) and describe that dependency in the body, on a line that **starts** with `Depends on: #<n>` (a list marker or bold before it is fine; the words mid-sentence are prose and declare nothing). On GitHub, prefer a native "blocked by" relationship where you can. Each sub-task's `Touches:` line (in the template below) names its areas; two sub-tasks whose `Touches:` areas overlap share a hotspot and must be chained with `Depends on:`, never run in parallel.
3. **Testable in isolation**: Has its own acceptance criteria and can be verified independently.
4. **No shared in-flight state**: Does not require uncommitted changes from a sibling sub-task to compile or pass tests.

**First, attempt to decompose the issue into manageable sub-tasks:**

```bash
echo "⚠️  Issue requires decomposition: attempting breakdown"

# Use brainstorming skill to analyze and decompose the complex issue
if [ "$SUPERPOWERS_AVAILABLE" = "true" ] || [ "$THOROUGH_SKILLS_AVAILABLE" = "true" ]; then
  echo "📋 Using thorough-brainstorming (preferred) or superpowers:brainstorming to decompose issue #$ISSUE_NUM..."
  # Prompt: "Decompose issue #$ISSUE_NUM into 3-8 sub-tasks. Each sub-task must:
  # (a) fit in one agent context window, (b) touch a DISTINCT set of files from
  # every other sub-task so they can run in parallel worktrees without merge conflicts,
  # (c) be independently testable. List any sub-tasks that must run after another
  # (sequential dependencies). For each, provide: title, description, files affected,
  # acceptance criteria, priority, and dependencies."

  # After decomposition analysis is complete, create GitHub issues for each sub-task
  # Store sub-task numbers for linking
  SUBTASK_NUMBERS=()

  # Example sub-task creation (repeat for each decomposed task):
  # for SUBTASK in "${SUBTASKS[@]}"; do
  SUBTASK_RESULT=$(issue_create \
    --label "bug" --label "P2" --label "subtask" \
    --title "Subtask: [Brief description]" \
    --body "$(cat <<SUBTASK_BODY
## Sub-task of #${ISSUE_NUM}

This is a decomposed sub-task from the larger issue #${ISSUE_NUM}.

## Description
[What needs to be done in this specific sub-task]

## Files Affected
[List specific files or directories this sub-task will modify. This MUST NOT overlap
with the files listed in sibling sub-tasks unless those sub-tasks have a sequential
dependency (listed below). Overlapping file lists = merge conflict in the worktree swarm.]

Touches: [comma-separated files, directories (trailing /) or globs from the list above]

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Dependencies
- Sub-task of #${ISSUE_NUM}
- [Depends on: #<sibling-subtask-number> — reason why this must run after that one]
- [On GitHub, also add it as a native "blocked by" link: it can't be created or lost by wording]
- [Can run in parallel with: #<sibling-subtask-number>]

## Testing
[How to verify this sub-task is complete in isolation, without sibling sub-tasks merged]

---

🤖 Auto-decomposed from #${ISSUE_NUM} by autonomous fix workflow
SUBTASK_BODY
)")
  SUBTASK_NUM=$(echo "$SUBTASK_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")

  SUBTASK_NUMBERS+=("$SUBTASK_NUM")
  echo "✅ Created sub-task #$SUBTASK_NUM"
  # done

  # Release the parent issue claim before exiting — workers will pick up sub-tasks.
  issue_update "$ISSUE_NUM" --remove-label "working" 2>/dev/null || true
  issue_release "$ISSUE_NUM" 2>/dev/null || true

  # Update original issue to reference all sub-tasks
  issue_comment "$ISSUE_NUM" --body "🔍 **Issue Decomposed into Sub-Tasks**

This issue has been broken down into independently-workable sub-tasks that can
run in parallel worktrees without merge conflicts:

$(for num in "${SUBTASK_NUMBERS[@]}"; do echo "- [ ] #$num"; done)

**Parallel safety**: each sub-task touches different files. Check each sub-task's
\"Files Affected\" section before assigning to confirm no overlap.

**Status**: This issue will be automatically closed once all sub-tasks are completed and verified.

🤖 Auto-decomposed by autonomous fix workflow"

  # Add label to indicate decomposition
  # The children go into the lifecycle event log (#190).
  AUTOCODER_EVENT_CHILDREN="${SUBTASK_NUMBERS[*]}" issue_update "$ISSUE_NUM" --add-label "decomposed" 2>/dev/null || true

  echo "✅ Decomposed issue #$ISSUE_NUM into ${#SUBTASK_NUMBERS[@]} sub-tasks"
  echo "📋 Sub-tasks: ${SUBTASK_NUMBERS[*]}"
  echo ""
  echo "⏭️  Claim released. Sub-tasks will be picked up by workers on the next tick."

else
  # Fallback: If superpowers not available, add too-complex label
  echo "ℹ️  Superpowers not available for decomposition"

  # Prepare detailed reason for blocking
  COMPLEXITY_REASON="Ultra-complex issue requiring decomposition or human guidance.

**Complexity Indicators**:
- [List specific indicators: >100 test failures, major architectural change, etc.]

**Recommended Approach**:
- Manually decompose into smaller sub-tasks
- Use /review-blocked to interactively review this issue
- Consider using superpowers plugin for assisted decomposition

**Available Tools**:
$(if [ "$QUINT_AVAILABLE" = "true" ]; then
  echo "- ✅ Quint plugin available for structured reasoning"
else
  echo "- ℹ️  Quint plugin not installed - manual review recommended"
fi)"

  # Determine script location (portable across different plugin install locations)
  SCRIPT_DIR="$HOME/.agent/plugins/autocoder/scripts"

  # Use the script to add blocking label
  bash "$SCRIPT_DIR/add-blocking-label.sh" "$ISSUE_NUM" "too-complex" "$COMPLEXITY_REASON"

  echo "⏭️  Issue labeled as too-complex. Use /review-blocked to review."
fi

echo ""
# Continue to next issue
```

## Monitoring Decomposed Issues

Moved here from fix.md (#293). After an issue closes, check for decomposed issues where all sub-tasks are complete:

```bash
# After fixing each issue, check if it was a sub-task that completes a decomposed issue
# Get parent issue if this was a subtask
PARENT_ISSUE=$(issue_get "$ISSUE_NUM" | jq -r '.body // ""' | sed -nE 's/.*Sub-task of #([0-9]+).*/\1/p' | head -1)

if [ -n "$PARENT_ISSUE" ]; then
  echo "🔍 Checking if parent issue #$PARENT_ISSUE is now complete..."

  # Check if all sub-tasks of parent are closed. The sub-task list lives in the
  # "Issue Decomposed into Sub-Tasks" COMMENT, not the body (#134): take the
  # checklist from the latest such comment, so a list corrected by a later
  # re-decomposition wins. Fall back to the body only when no such comment exists
  # (older decompositions, and the file backend, which folds comments into the body).
  PARENT_JSON=$(issue_get "$PARENT_ISSUE")
  PARENT_SUBTASKS=$(printf '%s' "$PARENT_JSON" | jq -r '
    ([(.comments // [])[] | (.body // "") | select(test("Issue Decomposed into Sub-Tasks"))] | last)
      // (.body // "")' | tr -d '\r' | grep -oE '^- \[[ xX]\] #[0-9]+' | grep -oE '[0-9]+$')
  ALL_CLOSED=true
  if [ -z "$PARENT_SUBTASKS" ]; then
    echo "⚠️  No sub-task checklist found on #$PARENT_ISSUE — not auto-closing it."
    ALL_CLOSED=false
  fi

  for SUBTASK_NUM in $PARENT_SUBTASKS; do
    SUBTASK_STATE=$(issue_get "$SUBTASK_NUM" | jq -r '.state')
    if [ "$SUBTASK_STATE" != "CLOSED" ]; then
      ALL_CLOSED=false
      break
    fi
  done

  if [ "$ALL_CLOSED" = "true" ]; then
    echo "✅ All sub-tasks complete! Closing parent issue #$PARENT_ISSUE"
    # The rollup is a review digest too (#196). It has no diff of its own (each
    # sub-task landed and was digested separately), so it renders against HEAD and
    # the sub-tasks go in "Where to look".
    ROLLUP_SECTIONS=$(mktemp "${AUTOCODER_TMP:-/tmp}/autocoder-rollup-${PARENT_ISSUE}.XXXXXX")
    {
      printf '## Intent\n%s\n\n' "$(issue_get "$PARENT_ISSUE" | jq -r '.title')"
      printf '## Where to look\nEach sub-task landed separately with its own digest; review them there:\n'
      for num in $PARENT_SUBTASKS; do printf -- '- #%s %s\n' "$num" "$(issue_get "$num" | jq -r '.title')"; done
      printf '\n## Verification\nEvery sub-task listed above is CLOSED (checked with issue_get just now).\n\n'
      printf '## Not verified / confidence\nThe sub-tasks were gated one at a time; nothing re-tested them together beyond each merge gate. Confidence: medium.\n'
    } > "$ROLLUP_SECTIONS"
    if ROLLUP=$(bash "${SCRIPT_DIR}/render-review-digest.sh" --issue "$PARENT_ISSUE" --base HEAD --sections "$ROLLUP_SECTIONS"); then
      if issue_close "$PARENT_ISSUE" --comment "✅ **Complex Issue Resolved**

${ROLLUP}

🤖 Auto-closed by autonomous fix workflow" && [ "$MERGE_MODE" != "pr" ]; then
        # Merge mode samples closed work for later human review (#197). The rollup
        # has no diff of its own, so only its labels and the random sample apply.
        bash "${SCRIPT_DIR}/spot-check-select.sh" --issue "$PARENT_ISSUE" \
          --sha "$(git rev-parse HEAD)" --base HEAD --apply || true
      fi
    else
      echo "❌ Rollup digest for #$PARENT_ISSUE did not render — leaving it open"
    fi
    rm -f "$ROLLUP_SECTIONS"
  fi
fi
```
