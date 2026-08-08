#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MONITOR="$ROOT/plugins/autocoder/commands/monitor-workers.md"
GEMINI_MONITOR="$ROOT/.agent/workflows/monitor-workers.md"
RESUME="$ROOT/plugins/autocoder/commands/manager-resume.md"

for file in "$MONITOR" "$GEMINI_MONITOR"; do
  grep -q 'No matching worktree has uncommitted changes' "$file"
  grep -q 'No matching local or remote branch has a tip commit in the last 60 minutes' "$file"
  grep -q 'fail closed: keep the label' "$file"
  grep -q 'issue_release <number>' "$file"
  grep -q 'do not pause for a permission question' "$file"
done

grep -q 'local and remote `\*issue-N\*` branch-tip timestamps' "$RESUME"
grep -q 'issue_release <number>' "$RESUME"
if grep -q 'gh issue edit <number> --remove-label' "$RESUME"; then
  echo "FAIL: manager resume bypasses the issue backend abstraction" >&2
  exit 1
fi

echo "ok stale-working protocol"
