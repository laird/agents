# Command Mapping

| Claude plugin command | Codex handling |
|---|---|
| `/autocoder:plan` | Turn a goal into a reviewed design doc plus linked story issues for the worker fleet |
| `/dev` | Run the core autocoder workflow against a specific issue or the highest-priority queue item |
| `/dev-loop` | Re-run the core workflow continuously with explicit shell/session control |
| `/fix`, `/fix-loop` | Deprecated aliases — forward to `/dev` and `/dev-loop` |
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
| `/set-issue-source` | Switch issue backend (file or GitHub) |
| `/record-issue` | Create a new issue in the configured backend |
| `/list-issues` | List issues in the current backend |
| `/update-issue` | Update an existing issue |
| `/close-issue` | Close an issue |
| `/install` | Use repo scripts and local configuration setup steps as needed |
| `/autocoder-help` | Summarize the workflow and available operating modes |
