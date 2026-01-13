# Bug Resolution Workflow

**Purpose**: Systematic resolution of GitHub issues by priority (P0-P3)

## Prerequisites

1. Run triage first (see `triage.md`) - all issues must have P0-P3 labels
2. Exclude issues with `proposal` label

## Process

### 1. Fetch & Prioritize Issues

```bash
gh issue list --state open --json number,title,labels,body --limit 100 | \
  python3 -c "
import json, sys
issues = json.load(sys.stdin)
priority = {'P0': 0, 'P1': 1, 'P2': 2, 'P3': 3}
bugs = [i for i in issues
        if any(l['name'] in priority for l in i.get('labels', []))
        and not any(l['name'] == 'proposal' for l in i.get('labels', []))]
bugs.sort(key=lambda x: min(priority.get(l['name'], 99) for l in x.get('labels', [])))
for b in bugs:
    p = next((l['name'] for l in b['labels'] if l['name'] in priority), '?')
    print(f\"{p}|#{b['number']}|{b['title']}\")"
```

### 2. Priority Assignment

| Priority | Criteria | Examples |
|----------|----------|----------|
| **P0** | Security, crashes, data loss | Auth bypass, corruption |
| **P1** | Major features broken | CRUD fails, core workflow |
| **P2** | Partial functionality | Filters, display issues |
| **P3** | Edge cases, UI polish | Validation, cosmetic |

### 3. Issue Processing

#### Complexity Assessment

| Complexity | Criteria | Approach |
|------------|----------|----------|
| Simple | Single file, <50 lines, clear fix | Direct: Read → Edit → Test → Commit |
| Medium | 2-5 files, <200 lines, known pattern | Direct with extra validation |
| Complex | >5 files, architectural impact, unclear | Delegate via `Task` tool |

**Decision logic**:
- If fix location is obvious AND change is localized → Simple
- If requires research OR multiple components → Complex
- When in doubt, treat as Complex

### 4. Git Operations

```bash
git checkout -b fix/issue-{number}-{description}
git add . && git commit -m "Fix #{number}: {title}"
git push origin fix/issue-{number}-{description}
```

### 5. Closure

- Comment with resolution details
- Close with commit reference
- Log via `append-to-history.sh`

## Quality Gates

- All tests pass before merge
- Security implications considered
- Code follows project style (read from project guidance file)

## Error Handling

| Situation | Action |
|-----------|--------|
| Fix doesn't resolve issue | Revert, re-analyze, try alternative approach |
| Tests fail after fix | Debug test failure, fix implementation or update test |
| Merge conflict | Resolve manually or create issue for human intervention |
| Fix introduces new bug | Revert, create P1 issue for original + new bug |
| Cannot reproduce | Comment on issue, request more info, lower priority |

## Success Metrics

| Metric | Target |
|--------|--------|
| Fix success rate | >95% of attempted fixes resolve issue |
| Test pass rate | 100% after each fix |
| Revert rate | <5% of fixes need reverting |
| Time to fix P0 | <4 hours |
| Time to fix P1 | <24 hours |
