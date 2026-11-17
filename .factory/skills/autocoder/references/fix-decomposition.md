# /fix reference: decomposing an issue into sub-tasks

Moved out of the `/fix` command file (#240) because a worker rarely needs it.
The command keeps a pointer at each place this text used to be.

### Ultra-Complex Issues - Decompose into Sub-Tasks

This section is triggered both by the **task scope gate** (in the `/fix` command, at claim time) and by the
complexity assessment (Step 1) when you discover mid-implementation that the scope is larger than expected.

For issues too large for autonomous resolution (>100 test failures, major architecture changes, significant trade-off decisions, or issues that fail the scope gate):

**Decomposition rules — each sub-task MUST satisfy ALL of these:**

1. **Context fit**: Completable in one agent conversation (not "migrate everything", not "audit all files")
2. **Worktree independence**: Touches a distinct set of files from sibling sub-tasks — no sub-task may edit the same file as another sibling that could run concurrently. If two sub-tasks MUST touch the same file, sequence them (sub-task B depends on sub-task A) and describe that dependency in the body. Write it on a `Depends on: #<n>` line in the sub-task's `## Dependencies` section: workers will not claim a sub-task until every issue on its "Depends on" lines is closed (`issue-deps.sh`), so the order is enforced, not just described. The line must **start** with `Depends on:` (a list marker or bold before it is fine); the words mid-sentence are prose and declare nothing, and a sub-task's parent never counts. On GitHub, prefer a native "blocked by" relationship between the issues where you can: it is read too, and no wording can create one by accident. Each sub-task's `Touches:` line (in the template below) names its areas; two sub-tasks whose `Touches:` areas overlap share a hotspot and must be chained with `Depends on:`, never run in parallel.
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
  SCRIPT_DIR="$HOME/.claude/plugins/autocoder/scripts"

  # Use the script to add blocking label
  bash "$SCRIPT_DIR/add-blocking-label.sh" "$ISSUE_NUM" "too-complex" "$COMPLEXITY_REASON"

  echo "⏭️  Issue labeled as too-complex. Use /review-blocked to review."
fi

echo ""
# Continue to next issue
```
