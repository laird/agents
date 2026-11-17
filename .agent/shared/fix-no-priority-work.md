# /fix reference: when no priority issues are left

Moved out of the `/fix` command file (#240) because a worker rarely needs it.
The command keeps a pointer at each place this text used to be.

## No Priority Issues Found

If no issues with P0-P3 labels exist, run full regression testing:

### Step 1: Run Full Regression Test

Use the `/full-regression-test` command to run the complete test suite:

```
/full-regression-test
```

This command will:
- Load test configuration from GEMINI.md
- Run build verification
- Run unit tests
- Run E2E tests (if configured)
- Analyze failures and assign priorities
- Create/update GitHub issues for each failure
- Generate a detailed report

### Step 2: Review Results

After `/full-regression-test` completes:

- **If failures found**: Issues are created with priority labels (P0-P3)
- **If all pass**: No new issues created

Check newly created issues:

```bash
# View issues created by regression test
issue_list --state open --label "test-failure" --limit 20
```

### Step 3: Continue Workflow

After regression testing:

- **If issues were created** → Continue fixing (workflow picks them up automatically)
- **If all tests passed** → Move to Enhancement Phase (Step 5)

#### 5B: Propose New Enhancements (if none exist)

If no enhancement issues exist, analyze the codebase and propose improvements:

**First, check test coverage** using the persistent coverage report:

```bash
# Fast path: Read existing report if available
if [ -f "test-coverage.md" ]; then
  echo "📊 Reading test-coverage.md (fast path)"
  # Parse coverage from report header
  OVERALL_COV=$(grep "Overall Coverage" test-coverage.md | grep -oE '[0-9]+' | head -1)
  echo "Current coverage: ${OVERALL_COV}%"

  # Show lowest coverage areas from report
  echo ""
  echo "Areas needing coverage:"
  grep -E "<!-- COVERAGE: [0-9]+%" test-coverage.md | head -5
else
  # No report exists - run full analysis to create it
  echo "📊 No test-coverage.md found, running full analysis..."
  /improve-test-coverage --analyze
fi
```

If coverage is below 80%, use `/improve-test-coverage` to improve it (this uses the fast path when test-coverage.md exists).

**Then use `thorough-brainstorming` (preferred) or `superpowers:brainstorming`** to identify other valuable enhancements:

```
# If thorough-brainstorming available (preferred):
Use Skill tool: thorough-brainstorming

# If superpowers available (fallback):
Use Skill tool: superpowers:brainstorming
```

Focus areas for enhancement proposals:
1. **Test Coverage** - Use `/improve-test-coverage` to improve gaps (reads from test-coverage.md)
2. **Code Quality** - Complex functions to refactor, duplication to reduce
3. **Performance** - Slow queries, caching opportunities, bundle optimization
4. **Documentation** - API docs, code examples, best practices

**Create Enhancement Proposal** (tagged with `proposal` label for human review):

```bash
PROPOSAL_RESULT=$(issue_create \
  --label "enhancement" --label "proposal" --label "P3" \
  --title "Proposal: [Brief description]" \
  --body "$(cat <<'ENHANCEMENT_BODY'
## Proposed Enhancement

[Detailed description of what this enhancement accomplishes]

## Rationale

[Why this improvement is valuable - metrics, user impact, maintainability]

## Implementation Plan

### Phase 1: [First phase]
- [ ] Task 1.1
- [ ] Task 1.2

### Phase 2: [Second phase]
- [ ] Task 2.1
- [ ] Task 2.2

### Phase 3: Verification
- [ ] Run full test suite
- [ ] Manual verification of feature
- [ ] Update documentation

## Success Criteria

- [ ] All existing tests pass
- [ ] New tests added for enhancement
- [ ] Documentation updated
- [ ] No performance regression

## Estimated Complexity

[Simple | Medium | Complex]

---

## 📋 Proposal Status

**Status**: ⏳ Awaiting Human Approval

### How to Approve This Proposal

To approve and allow automated implementation:
```bash
/update-issue <issue_number> --remove-label "proposal"
```

### How to Provide Feedback

Comment on this issue with your feedback. The AI will incorporate your suggestions when you run `/refine-proposal <issue_number>`.

### How to Reject This Proposal

```bash
/close-issue <issue_number> "Rejected: [reason]"
```

---

🤖 Proposed by autonomous improvement workflow
ENHANCEMENT_BODY
)")
PROPOSAL_NUM=$(echo "$PROPOSAL_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")

echo "✅ Created proposal issue #${PROPOSAL_NUM}. Awaiting human approval before implementation."
echo "💡 Use '/list-proposals' to view all pending proposals"
echo ""

echo "IDLE_NO_WORK_AVAILABLE"
```

**IMPORTANT**: After creating a proposal, output `IDLE_NO_WORK_AVAILABLE` to trigger the sleep cycle. This gives humans time to review the proposal before the next iteration. Do NOT immediately create more proposals or loop without sleeping.
