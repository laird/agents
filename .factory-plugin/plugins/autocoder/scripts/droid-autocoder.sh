#!/bin/bash
# Run one Droid autocoder workflow pass.
set -euo pipefail
COMMAND="$1"
shift
case "$COMMAND" in
  fix)
    ISSUE_NUMBER="${1:-}"
    if [ -n "$ISSUE_NUMBER" ]; then
      droid exec --full-auto "/fix $ISSUE_NUMBER"
    else
      droid exec --full-auto "/fix"
    fi
    ;;
  monitor-workers)
    droid exec --full-auto "/monitor-workers"
    ;;
  *)
    echo "❌ Unknown command: $COMMAND" >&2
    exit 1
    ;;
esac
