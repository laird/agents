---
description: Apply improvements from retrospective
---

# Retrospective Application Workflow

This workflow applies the recommendations from `IMPROVEMENTS.md`.

1. **Review & Plan**
    Switch to **Migration Coordinator**:
    - Read `IMPROVEMENTS.md`.
    - Create an implementation plan (Order of operations, dependencies).
    - Get User Approval (via `notify_user` if needed, or assume validation).

2. **Apply Changes**
    For each recommendation:

    a.  **Protocol Updates**:
        Switch to **Documentation**:
        - Update guidelines in `.agent/rules/` or workflows.

    b.  **Automation**:
        Switch to **Coder**:
        - Create/Update scripts in `scripts/`.
        - Configure CI/CD or hooks.

    c.  **Documentation**:
        - Update `README.md`, `CHANGELOG.md`.

3. **Validation**
    - Verify all changes are syntactically correct.
    - Run any new automation scripts to test them.

4. **Completion**
    - Update `IMPROVEMENTS.md` status to "Implemented".
    - Commit changes.
