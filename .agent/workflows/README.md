# Antigravity Workflows

This directory contains workflow definitions that chain multiple agent actions together to perform complex tasks.

- **`/fix`**: An autonomous workflow for resolving GitHub issues.
- **`/fix-loop`**: Repeats `/fix` until stopped.
- **`/monitor-workers`**: Monitors workers, stale locks, and dispatch opportunities.
- **`/monitor-loop`**: Repeats `/monitor-workers` for the manager session.
- **`/review-blocked`**: Reviews issues labeled as blocked for human decision.
- **`/list-proposals`**: Lists pending enhancement proposals.
- **`/approve-proposal`**: Approves a proposal for implementation.
- **`/list-needs-design`**: Lists issues that need design work.
- **`/list-needs-feedback`**: Lists issues that need human feedback.
- **`/brainstorm-issue`**: Explores options for a blocked issue.
- **`/full-regression-test`**: Runs the full regression suite.
- **`/improve-test-coverage`**: Analyzes and improves test coverage.
- **`/autocoder-help`**: Shows the autocoder workflow overview.
- **`/modernize`**: A workflow for modernizing legacy codebases.
