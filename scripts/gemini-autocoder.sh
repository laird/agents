#!/bin/bash
# Run one Gemini (Antigravity) autocoder workflow pass.
# Usage:
#   gemini-autocoder.sh fix [issue_number]
#   gemini-autocoder.sh monitor-workers

set -euo pipefail

usage() {
  echo "Usage:"
  echo "  $0 fix [issue_number]"
  echo "  $0 monitor-workers"
}

if [ $# -lt 1 ]; then
  usage >&2
  exit 1
fi

if ! command -v gemini >/dev/null 2>&1; then
  echo "❌ gemini CLI not found in PATH" >&2
  exit 1
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "❌ Must be run inside a git repository" >&2
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
COMMAND="$1"
shift

case "$COMMAND" in
  fix)
    ISSUE_NUMBER="${1:-}"
    if [ -n "$ISSUE_NUMBER" ]; then
      gemini -p "/dev $ISSUE_NUMBER" --sandbox=false -y
    else
      gemini -p "/dev" --sandbox=false -y
    fi
    ;;
  monitor-workers)
    gemini -p "/monitor-workers" --sandbox=false -y
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "❌ Unknown command: $COMMAND" >&2
    usage >&2
    exit 1
    ;;
esac
