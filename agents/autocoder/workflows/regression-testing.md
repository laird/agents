# Regression Testing Workflow

**Purpose**: Execute test suite and analyze failures

## Configuration

Read test commands from project guidance file (e.g., `CLAUDE.md`, `gemini.md`).

## Test Execution

### 1. Build Verification

```bash
# JavaScript/TypeScript
npm run build

# Java
mvn compile

# C#/.NET
dotnet build
```

### 2. Unit Tests

```bash
# JavaScript/TypeScript
npm test

# Java
mvn test

# C#/.NET
dotnet test --filter "Category=Unit"
```

### 3. Integration/E2E Tests

```bash
# JavaScript/TypeScript
npm run test:e2e
# or: npx playwright test --reporter=json

# Java
mvn verify -P integration

# C#/.NET
dotnet test --filter "Category=Integration"
```

## Failure Analysis

### Parse Results
- Extract pass/fail counts
- Identify syntax vs logic vs integration failures
- Assign priority based on impact

### Priority Assignment

| Pattern in test description | Priority |
|-----------------------------|----------|
| auth, security, crash, data loss | P0 |
| create, delete, update, save | P1 |
| filter, sort, search, display | P2 |
| other | P3 |

### Create Issue for Each Failure

```bash
gh issue create \
  --title "{priority}: {test_description}" \
  --body "## Test Failure
**File**: \`{test_file}\`
**Description**: {test_desc}
**Detected**: {timestamp}

Detected during regression testing." \
  --label "bug,automated-test-failure,{priority}"
```

## Status Determination

- **Success** (all pass): Proceed to enhancement phase
- **Failure** (any fail): Return to bug fixing phase

## Defaults

If project guidance file not found:
- Build: `npm run build` / `mvn compile` / `dotnet build`
- Unit tests: `npm test` / `mvn test` / `dotnet test`
- E2E: `npx playwright test` / `mvn verify` / `dotnet test`
