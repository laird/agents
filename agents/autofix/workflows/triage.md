# Issue Triage Workflow

**Version**: 1.5.0
**Purpose**: Review and prioritize unprioritized GitHub issues

## Overview

Before processing issues, the autofix agent must triage any open issues that lack priority labels (P0-P3). This ensures all issues are properly categorized before entering the fix workflow.

## Process

### 1. Fetch Unprioritized Issues

```bash
# Fetch all open issues
gh issue list --state open --json number,title,body,labels --limit 100 > /tmp/all-issues.json

# Filter for issues without P0-P3 labels
python3 -c "
import json
issues = json.load(open('/tmp/all-issues.json'))
unprioritized = [i for i in issues if not any(
    l['name'] in ['P0','P1','P2','P3'] for l in i.get('labels',[])
)]
for i in unprioritized:
    print(f\"{i['number']}|{i['title']}\")
"
```

### 2. Priority Assessment

For each unprioritized issue, assess severity using this matrix:

| Priority | Severity | User Impact | Workaround | Examples |
|----------|----------|-------------|------------|----------|
| **P0** | Critical | All users | None | System down, security vulnerability, data loss |
| **P1** | High | Many users | Difficult | Major feature broken, auth failure |
| **P2** | Medium | Some users | Available | Feature partially working, display issues |
| **P3** | Low | Few users | Easy | Minor bugs, cosmetic issues, edge cases |

### 3. Keyword Detection

Use keywords to help determine priority:

- **P0 Keywords**: "crash", "down", "urgent", "security", "vulnerability", "data loss"
- **P1 Keywords**: "broken", "fails", "blocking", "cannot", "error"
- **P2 Keywords**: "issue", "bug", "incorrect", "wrong", "problem"
- **P3 Keywords**: "minor", "cosmetic", "enhancement", "nice-to-have", "typo"

### 4. Assign Priority Label

```bash
# Assign priority to an issue
gh issue edit <ISSUE_NUMBER> --add-label "P2"  # Use appropriate priority
```

### 5. Post Triage Comment

```bash
gh issue comment <ISSUE_NUMBER> --body "🏷️ **Triage Complete**

**Priority Assigned**: P2 (Medium)

**Rationale**: [Brief explanation of priority decision]

🤖 Triaged by autofix agent"
```

## Triage Decision Logic

```python
def determine_priority(issue):
    title = issue['title'].lower()
    body = (issue.get('body') or '').lower()
    text = f"{title} {body}"

    # P0: Critical
    if any(kw in text for kw in ['crash', 'down', 'security', 'vulnerability', 'data loss']):
        return 'P0'

    # P1: High
    if any(kw in text for kw in ['broken', 'fails', 'blocking', 'cannot login', 'auth']):
        return 'P1'

    # P2: Medium (default for bugs)
    if any(kw in text for kw in ['bug', 'issue', 'incorrect', 'error']):
        return 'P2'

    # P3: Low
    return 'P3'
```

## Integration with Main Workflow

1. **Run triage FIRST** before bug fixing
2. **Continue to bug fixing** after all issues are triaged
3. **Re-triage** when new issues are detected

## Quality Gates

- Every open issue must have a P0-P3 label before processing
- Triage decisions should be documented in issue comments
- Priority can be adjusted if new information emerges
