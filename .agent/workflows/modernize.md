---
description: Execute the modernization plan
---

# Modernization Execution Workflow

This workflow executes the modernization phases defined in `PLAN.md`.

1. **Initialize Execution**
    Read `PLAN.md` to load the migration phases.
    Switch to **Migration Coordinator** to verify entry criteria (Backup, Test Baseline).

2. **Phase Execution Loop**
    For each phase defined in the plan:

    a.  **Preparation**:
        - Create a feature branch for the phase.
        - Verify prerequisites.

    b.  **Implementation**:
        Switch to **Coder**:
        - Execute code changes (dependencies, framework, refactoring).
        - Commit regularly.

    c.  **Validation**:
        Switch to **Tester**:
        - Run `full-regression-test`.
        - Ensure 100% pass rate.
        - Fix any regressions (Coordinate Coder + Tester).

    d.  **Review**:
        Switch to **Architect**:
        - Verify architectural alignment.
        - Ensure ADRs are followed/created.

    e.  **Phase Completion**:
        Switch to **Documentation**:
        - Update `HISTORY.md` and `CHANGELOG.md`.
        - Mark phase as complete in `PLAN.md`.

3. **Final Verification**
    Execute a full system audit (Security Scan + Full Regression Test).
    Generate Final Report.
