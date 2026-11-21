#!/bin/bash
# Run one Droid autocoder workflow pass.
set -euo pipefail
COMMAND="$1"
shift
# Flags for `droid exec` (#286). droid exec is headless and read-only by default, so
# a fix pass needs an autonomy level to edit, commit and push. The default is
# --auto high, the level docs/DROID.md documents; --full-auto, used here before, is
# not a droid flag. Nothing here passes --skip-permissions-unsafe.
# AUTOCODER_DROID_FLAGS replaces the default (split on whitespace, no globbing);
# set it to "" for droid's own default.
read -r -a DROID_FLAGS <<< "${AUTOCODER_DROID_FLAGS---auto high}"
case "$COMMAND" in
  fix)
    ISSUE_NUMBER="${1:-}"
    if [ -n "$ISSUE_NUMBER" ]; then
      droid exec ${DROID_FLAGS[@]+"${DROID_FLAGS[@]}"} "/fix $ISSUE_NUMBER"
    else
      droid exec ${DROID_FLAGS[@]+"${DROID_FLAGS[@]}"} "/fix"
    fi
    ;;
  monitor-workers)
    droid exec ${DROID_FLAGS[@]+"${DROID_FLAGS[@]}"} "/monitor-workers"
    ;;
  *)
    echo "❌ Unknown command: $COMMAND" >&2
    exit 1
    ;;
esac
