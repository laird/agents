# Bug Resolution Workflow

**Purpose**: Systematic resolution of GitHub issues by priority (P0-P3)

## Process

### 1. Issue Fetching & Prioritization
```bash
# Fetch all open issues
gh issue list --state open --json number,title,labels,body --limit 100

# Sort by priority (P0 → P1 → P2 → P3)
# Create priority labels if missing
```

### 2. Priority Assignment Rules
- **P0**: Auth, security, crashes, data loss
- **P1**: CRUD operations, major features
- **P2**: Filters, sorting, search, display
- **P3**: UI issues, validation, edge cases

### 3. Issue Processing
For each issue in priority order:

#### A. Complexity Analysis
- Read issue title and description
- Estimate implementation complexity
- Determine if direct fix or specialist skill needed

#### B. Implementation Strategy
**Simple Issues** (direct fix):
- Use `Read` to understand affected code
- Use `Edit`/`Write` to implement fix
- Run tests to validate
- Commit and close issue

**Complex Issues** (specialist delegation):
- Use `Task` with appropriate specialist
- Provide issue context and requirements
- Review implementation
- Handle testing and integration

#### C. Git Operations
```bash
# Create feature branch
git checkout -b fix/issue-{number}-{description}

# Commit changes
git add .
git commit -m "Fix #{number}: {title}"

# Push and merge (if configured)
git push origin fix/issue-{number}-{description}
```

#### D. Issue Closure
- Add comment with resolution details
- Close issue with reference to commit
- Log activity using append-to-history.sh

## Quality Gates

- All tests must pass before merge
- Code must follow project style guidelines
- Security implications must be considered
- Documentation updated if needed

## Error Handling

- If implementation fails, create new issue with details
- If tests fail, analyze and fix before proceeding
- If merge conflicts, resolve or create issue for manual resolution