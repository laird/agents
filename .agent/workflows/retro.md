---
description: Run a retrospective to identify process improvements
---

# Retrospective Analysis Workflow

This workflow orchestrates a team retrospective to identify improvements, creating `IMPROVEMENTS.md`.

1. **Historical Analysis**
    - **Migration Coordinator**: Analyze `HISTORY.md` for timeline deviations and blockers.
    - **Architect**: Review ADRs for decision outcomes.
    - **Tester**: Analyze test pass rates and flaky tests.
    - **Security**: Review vulnerability trends.
    - **Coder**: Analyze git history for churn and large commits.
    - **Documentation**: specific check: is documentation up to date?

2. **Agent Behavior Analysis**
    - Search git logs for "fix", "oops", "correct" to identify agent errors.
    Run the following analysis commands:

    ```bash
    bash -c 'git log --all --grep="fix\|correct\|actually\|oops\|mistake"'
    bash -c 'grep -i "user:\|correction\|fix\|reverted\|undo" HISTORY.md'
    bash -c 'git log --all --oneline | grep -i "revert\|undo"'
    bash -c 'git log --all --format="%ai %s" | awk "{print \$1, \$2}" | sort'
    bash -c 'git log --all --oneline --graph'
    bash -c 'git log --all --numstat --pretty="%H" | awk "NF==3 {plus+=\$1; minus+=\$2} END {printf(\"+%d, -%d\n\", plus, minus)}"'
    bash -c 'git shortlog -sn'
    ```

    - Identify instances of:
        - Wrong tool usage (search logs).
        - User interruptions (history check).
        - Wasted effort.

3. **Synthesis**
    Switch to **Migration Coordinator**:
    - Synthesize findings into 3-5 high-impact recommendations.
    - Focus on: Protocol updates, Automation (scripts), and Agent behavior.

4. **Generate Report**
    Switch to **Documentation**:
    - Create `IMPROVEMENTS.md` (MADR format).
    - Include: Problem, Evidence, Proposed Change, and Expected Impact for each recommendation.
