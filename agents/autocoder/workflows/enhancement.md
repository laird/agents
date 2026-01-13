# Enhancement Implementation Workflow

**Purpose**: Implement **approved** enhancements (those WITHOUT `proposal` label)

## Important

- Only implement enhancements that do NOT have `proposal` label
- Proposals await human approval - see `proposals.md`

## Process

### 1. Select Approved Enhancement

```bash
gh issue list --state open --label "enhancement" --json number,title,body,labels | \
  python3 -c "
import json, sys
issues = json.load(sys.stdin)
approved = [i for i in issues if not any(l['name'] == 'proposal' for l in i.get('labels', []))]
for i in approved:
    print(f\"{i['number']}|{i['title']}\")"
```

If none exist, see `proposals.md` to create new proposals.

### 2. Plan Implementation

Use `Task` for complex enhancements:
```
Task(description="Plan enhancement", prompt="Create implementation plan for: {issue}")
```

### 3. Implement

**Simple**: Read → Edit/Write → Follow project coding standards

**Complex**: Delegate via `Task` with plan and requirements

### 4. Test & Validate

Run project test suite (command from project guidance file):

```bash
# JavaScript/TypeScript
npm test && npm run test:integration

# Java
mvn test && mvn verify

# C#/.NET
dotnet test
```

### 5. Git & Close

```bash
git checkout -b feature/enhancement-{number}
git add . && git commit -m "feat: #{number} {title}"
git push origin feature/enhancement-{number}
gh pr create --title "feat: {title}" --body "{summary}"
```

## Quality Checklist

- [ ] Tests pass
- [ ] No security vulnerabilities
- [ ] Documentation updated if needed
- [ ] Code follows project style

## Error Handling

- **Test failures**: Create bug issues, return to bug fixing phase
- **Blockers**: Document in issue, create sub-issues if needed
