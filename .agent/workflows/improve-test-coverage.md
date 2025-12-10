---
description: Improve test coverage
---

# Improve Test Coverage Workflow

This workflow identifies coverage gaps and adds missing tests.

1. **Analyze Coverage**
    Switch to **Tester**:
    - Run coverage tools (e.g., `npm run test:coverage`).
    - Identify files with < 80% coverage.
    - Identify critical paths (Auth, Security) with missing tests.

2. **Improvement Loop**
    For each low-coverage file (Priority: P0 Critical -> P1 Logic -> P2 Utils):

    a.  **Plan**:
        - Identify missing test cases (edge cases, error conditions).

    b.  **Implement**:
        Switch to **Coder**:
        - Create/Update test files.
        - Use TDD: Write failing test -> Write code (if needed) -> Pass.

    c.  **Verify**:
        Switch to **Tester**:
        - Run tests for the specific file.
        - Run full regression to ensure no side effects.

3. **Final Report**
    - Generate updated coverage report.
    - Document improvements.
