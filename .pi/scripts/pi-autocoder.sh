#!/bin/bash
# Run one Pi autocoder workflow pass.
#
# Pi's non-interactive mode is a first-class path (`pi -p`), so the worker never
# needs a TUI driven by send-keys: no readiness race, and no consent dialog to
# answer, since Pi has no permission prompts at all.
#
# THE `-a` FLAG IS LOAD-BEARING. Project-local resources -- which is where our
# prompt templates live (.pi/prompts/) -- are governed by project trust, and in
# non-interactive mode an untrusted project is silently IGNORED rather than
# refused. Without `-a`, `pi -p "/fix"` sends the literal three characters
# "/fix" to the model as a prompt: no error, no exit code, just an agent that
# was asked nothing useful. Verified against pi 0.84.4 by reading the user
# message off `--mode json`. See tests/test_pi_support.sh.
set -euo pipefail

PI_BIN="${PI_BIN:-pi}"
# Extra flags for the operator: --model, --thinking, --provider all belong here.
PI_ARGS=${PI_ARGS:-}

run_pi() {
  # shellcheck disable=SC2086  # PI_ARGS is deliberately word-split.
  "$PI_BIN" -p -a $PI_ARGS "$1"
}

COMMAND="${1:-}"
[ $# -gt 0 ] && shift

case "$COMMAND" in
  fix)
    ISSUE_NUMBER="${1:-}"
    if [ -n "$ISSUE_NUMBER" ]; then
      run_pi "/fix $ISSUE_NUMBER"
    else
      run_pi "/fix"
    fi
    ;;
  monitor-workers)
    run_pi "/monitor-workers"
    ;;
  review-blocked)
    run_pi "/review-blocked"
    ;;
  *)
    echo "❌ Unknown command: $COMMAND" >&2
    echo "Usage: $0 {fix [issue]|monitor-workers|review-blocked}" >&2
    exit 1
    ;;
esac
