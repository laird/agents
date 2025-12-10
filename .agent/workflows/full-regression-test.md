---
description: Run full regression test suite
---

# Full Regression Test Workflow

This workflow runs the comprehensive regression suite and manages GitHub issues for failures.

1. **Preparation**
    - Ensure `plugins/autofix/scripts/regression-test.sh` is executable. (If not found, create it from the reference implementation).

2. **Execution**
    Run the regression test script:

    ```bash
    bash plugins/autofix/scripts/regression-test.sh
    ```

3. **Analysis**
    The script automatically:
    - Runs Unit Tests.
    - Runs E2E Tests.
    - Updates `docs/test/regression-reports/`.
    - Creates/Updates GitHub issues for any failures.

4. **Verification**
    - specific check: `exit code == 0`
    - If exit code is 0, all tests passed.
    - If non-zero, check generated issues.
