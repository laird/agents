# Command Mapping

| Claude plugin command | Droid handling |
|---|---|
| `/fix` | Run the core autocoder workflow against a specific issue or the highest-priority queue item |
| `/fix-loop` | Re-run the core workflow continuously with explicit shell/session control |
| `/monitor-workers` | Inspect worker sessions, stale locks, and dispatch opportunities for parallel work |
| `/monitor-loop` | Re-run worker monitoring continuously with explicit shell/session control |
| `/stop-loop` | Stop the active shell/session loop |
| `/review-blocked` | Review blocked issues by priority and recommend approve / reject / clarify actions |
| `/full-regression-test` | Run `bash plugins/autocoder/scripts/regression-test.sh` and file issues for failures |
| `/improve-test-coverage` | Analyze current coverage and add tests without regressing the suite |
| `/list-proposals` | Query open proposal issues and summarize status |
| `/approve-proposal` | Remove the `proposal` label after validating the request |
| `/list-needs-design` | Query issues with `needs-design` |
| `/list-needs-feedback` | Query issues with feedback-related blocking labels |
| `/brainstorm-issue` | Produce implementation options and recommended direction for one issue |
| `/install` | Use repo scripts and local configuration setup steps as needed |
| `/autocoder-help` | Summarize the workflow and available operating modes |
