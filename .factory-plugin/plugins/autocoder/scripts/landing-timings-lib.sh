#!/usr/bin/env bash
# landing-timings-lib.sh — best-effort writer for landing-timings.jsonl (see landing-timings.py).
# Source this file; do not execute it. A project's gate, queue or train script sources it and calls
#
#   landing_change <issue> <event> [--batch ID] [--cause CAUSE] [--ts ISO]
#   landing_batch  --batch ID --members 1,2,3 [--assembly-s N] [--stage NAME=SECS ...]
#                  [--gate-s N] [--discarded-gate-s N] [--publish-s N] [--verdict V] [--cause C]
#                  [--resyncs N] [--push-rejected N]
#
# Recording never fails or delays the caller: errors (a bad argument included) are dropped.
_lt_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

landing_change() {
  [ $# -ge 2 ] || return 0
  local issue="$1" event="$2"; shift 2
  python3 "${_lt_DIR}/landing-timings.py" change --issue "$issue" --event "$event" "$@" 2>/dev/null || true
}

landing_batch() {
  python3 "${_lt_DIR}/landing-timings.py" batch "$@" 2>/dev/null || true
}
