#!/bin/bash
# Run the Codex worker monitor.
set -euo pipefail
codex exec --dangerously-bypass-approvals-and-sandbox "/monitor-workers"
