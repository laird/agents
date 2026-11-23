---
description: Apply improvements from retrospective
---

# Retrospective Application Workflow

This workflow applies the recommendations from `IMPROVEMENTS.md`, written by either the autocoder or
the modernize `/retro` (#150). The file's title says which: `# Autocoder Process Improvement
Recommendations` targets the autocoder protocols (`fix.md` and the other autocoder workflows,
and the scripts they call); any other title targets the modernize protocols.

1. **Review & Plan**
    Switch to **Migration Coordinator**:
    - Read `IMPROVEMENTS.md`.
    - Create an implementation plan (Order of operations, dependencies).
    - Get User Approval (via `notify_user` if needed, or assume validation).

2. **Apply Changes**
    For each recommendation:

    a.  **Protocol Updates**:
        Switch to **Documentation**:
        - Update guidelines in `.agent/rules/` or workflows, for the plugin the title names.
          In a repository that keeps the plugin source, give the Claude copy
          (`plugins/<plugin>/commands/`, agents in `plugins/<plugin>/agents/`) the same edit.
          For autocoder that is mostly `fix.md` and the scripts it calls
          (`plugins/autocoder/scripts/`, then re-run the script packager as `CLAUDE.md` says);
          `retro-apply.md` itself is edited only in the modernize source.
        - File, do not apply, a change to the merge gate, claim or merge scripts, CI
          workflows, git hooks or install scripts: record it as an issue so it goes
          through the repository's normal review.

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
    - Commit changes, staging the changed files by name (never `git add -A`).
