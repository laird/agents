---
description: Autonomous GitHub issue resolution
---

# Autonomous Issue Fix Workflow

This workflow autonomously manages and fixes GitHub issues.

1. **Prioritize Issues**
    - List all open issues.
    - Identify P0 (Critical) and P1 (High) issues using labels or keywords.
    - Select the highest priority issue to work on.

2. **Fix Loop**
    For the selected issue:

    a.  **Analysis**:
        Switch to **Coder**:
        - Read the issue description.
        - Reproduce the issue (create a reproduction script/test).

    b.  **Implementation**:
        Switch to **Coder**:
        - Implement the fix.
        - Verify locally.

    c.  **Verification**:
        Switch to **Tester**:
        - Run `full-regression-test` workflow/script.
        - If regression found, revert/fix and retry.
        - Ensure the reproduction test now passes.

    d.  **Completion**:
        - Commit changes.
        - Close the GitHub issue with a comment referencing the fix and test results.

3. **Repeat**
    If more issues exist, repeat the loop. If no bugs, check for enhancements or coverage improvements.
