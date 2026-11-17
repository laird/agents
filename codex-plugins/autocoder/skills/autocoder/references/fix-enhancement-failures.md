# /fix reference: enhancement test failures and skips

Moved out of the `/fix` command file (#240) because a worker rarely needs it.
The command keeps a pointer at each place this text used to be.

**If Tests Fail - Create Bug Issues**:

```bash
if [ $TEST_EXIT_CODE -ne 0 ]; then
  echo "❌ Tests failed during enhancement implementation"

  # Parse test failures and create issues for each
  # Extract failing test names and create individual issues

  issue_create \
    --label "bug" --label "test-failure" --label "P1" \
    --title "Test failure during enhancement #${ENHANCE_NUM}: [Test name]" \
    --body "$(cat <<FAILURE_BODY
## Test Failure

**Related Enhancement**: #${ENHANCE_NUM}
**Branch**: \`enhancement/issue-${ENHANCE_NUM}-auto\`

## Failing Test
\`\`\`
[Test name and location]
\`\`\`

## Error Output
\`\`\`
${TEST_OUTPUT}
\`\`\`

## Context
This test failure occurred while implementing enhancement #${ENHANCE_NUM}.

## Suggested Investigation
1. Check if enhancement changes broke existing functionality
2. Verify test expectations are still valid
3. Check for missing dependencies or setup

🤖 Created by autonomous enhancement workflow
FAILURE_BODY
)"

  # Comment on enhancement issue about the failure
  issue_comment "$ENHANCE_NUM" --body "⚠️ **Implementation Blocked by Test Failures**

Test failures occurred during implementation. Bug issues have been created:
- [List created bug issue numbers]

Enhancement implementation paused. Will resume after bugs are fixed.

🤖 Autonomous enhancement workflow"

  # Do NOT merge - leave branch for investigation
  echo "⚠️ Enhancement branch preserved for investigation: enhancement/issue-${ENHANCE_NUM}-auto"

  # KEEP the 'working' label. The enhancement is PAUSED, not finished — the
  # branch is preserved and this worker intends to resume once the bug issues
  # land. Releasing here would re-expose an issue that already has unmerged work
  # on a branch (issue #14). Release it only if you are truly abandoning the
  # enhancement, and then use the explicit-release path (comment + label removal).
  echo "⏸️  Enhancement #$ENHANCE_NUM paused ('working' lock retained; branch preserved)"

  # Switch back to main
  git checkout main
fi
```

#### 5E: Enhancement Skip Criteria

Skip an enhancement and move to the next if:
- Enhancement requires external services not available
- Enhancement scope is too large (>50 files affected)
- Enhancement has unresolved dependencies on other issues
- Enhancement requires user decisions not documented

```bash
# Explicit release: announce the hand-off FIRST, then drop the lock, so peers
# and /monitor-workers see a deliberate release rather than a vanished lock.
issue_comment "$ENHANCE_NUM" --body "🔓 **Enhancement Skipped — releasing claim**

This enhancement cannot be automatically implemented because:
[Reason]

**Recommendation**: [What manual steps are needed]
**State left behind**: [what exists on the branch, if anything]

Releasing the \`working\` lock so another agent can pick this up.

🤖 Autonomous enhancement workflow"

# Terminal outcome only: this is an abandonment, paired with the release comment above.
issue_update "$ENHANCE_NUM" --remove-label "working" 2>/dev/null || true

# Add 'needs-review' label
issue_update "$ENHANCE_NUM" --add-label "needs-review"
```

---
