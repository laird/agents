# Issue Triage Workflow

**Purpose**: Review and prioritize unprioritized GitHub issues

## Process

### 1. Fetch Unprioritized Issues

```bash
gh issue list --state open --json number,title,body,labels --limit 100 | \
  python3 -c "
import json, sys
issues = json.load(sys.stdin)
unprioritized = [i for i in issues
    if not any(l['name'] in ['P0','P1','P2','P3'] for l in i.get('labels', []))]
for i in unprioritized:
    print(f\"{i['number']}|{i['title']}\")"
```

### 2. Priority Matrix

| Priority | Severity | User Impact | Examples |
|----------|----------|-------------|----------|
| **P0** | Critical | All users, no workaround | System down, security vuln, data loss |
| **P1** | High | Many users, difficult workaround | Major feature broken, auth failure |
| **P2** | Medium | Some users, workaround exists | Partial functionality, display issues |
| **P3** | Low | Few users, easy workaround | Minor bugs, cosmetic, edge cases |

### 3. Keyword Detection

- **P0**: crash, down, urgent, security, vulnerability, data loss
- **P1**: broken, fails, blocking, cannot, error
- **P2**: issue, bug, incorrect, wrong, problem
- **P3**: minor, cosmetic, enhancement, nice-to-have, typo

### 4. Assign & Comment

```bash
gh issue edit {number} --add-label "P2"
gh issue comment {number} --body "**Triage**: P2 (Medium)
**Rationale**: {explanation}
Triaged by autocoder agent"
```

## Integration

1. Run triage FIRST before bug fixing
2. Re-triage when new issues detected
3. Priority can be adjusted if new information emerges
