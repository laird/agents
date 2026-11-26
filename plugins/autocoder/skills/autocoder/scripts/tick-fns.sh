#!/usr/bin/env bash
# tick-fns.sh — record each run of an operational loop in ticks.jsonl (#422).
# Source this file; do not execute it. A loop script calls
#
#   tick_start <loop> [run_id]
#   ... the run ...
#   tick_end <ok|noop|error|timeout> [observed.KEY=VALUE ...] [actions.KEY=VALUE ...] [error=TEXT]
#
# tick_start only notes the loop, the run id (default: the start time and $$) and the start time;
# tick_end writes the line through tick-log.py, which documents the format. duration_s is the time
# since tick_start, or null when there was none (the loop id is then the calling script's name).
# repo is autocoder_repo_id of the checkout, else its directory name.
#
# Recording never fails or delays the caller: errors (a bad argument included) are dropped.
_tick_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if ! declare -F autocoder_repo_id >/dev/null && [ -f "${_tick_DIR}/repo-id-fns.sh" ]; then
  # shellcheck source=repo-id-fns.sh
  source "${_tick_DIR}/repo-id-fns.sh"
fi

# Seconds since the epoch, to the microsecond where bash 5 has EPOCHREALTIME (a locale may write
# its decimal point as a comma).
_tick_now() {
  if [ -n "${EPOCHREALTIME:-}" ]; then printf '%s\n' "${EPOCHREALTIME/,/.}"; else date +%s; fi
}

tick_start() {
  _tick_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _tick_t0=$(_tick_now)
  _tick_loop="${1:-$(basename "${0:-loop}" .sh)}"
  _tick_run_id="${2:-${_tick_ts}-$$}"
}

tick_end() {
  local outcome="${1:-}" top repo="" timing=()
  [ $# -gt 0 ] && shift
  if [ -n "${_tick_t0:-}" ]; then
    timing=(--ts "$_tick_ts" --duration-s "$(awk -v a="$_tick_t0" -v b="$(_tick_now)" 'BEGIN { printf "%.3f", b - a }')")
  fi
  top=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if declare -F autocoder_repo_id >/dev/null; then
    repo=$(autocoder_repo_id "${top:-$PWD}" 2>/dev/null || true)
  fi
  [ -n "$repo" ] || repo=$(basename "${top:-$PWD}")
  python3 "${_tick_DIR}/tick-log.py" --loop "${_tick_loop:-$(basename "${0:-loop}" .sh)}" \
    ${_tick_run_id:+--run-id "$_tick_run_id"} --outcome "$outcome" --repo "$repo" \
    ${timing[@]+"${timing[@]}"} -- "$@" >/dev/null 2>&1 || true
  unset _tick_ts _tick_t0 _tick_loop _tick_run_id
  return 0
}
