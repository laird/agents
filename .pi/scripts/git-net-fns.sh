#!/bin/bash
# git-net-fns.sh — bounded git network calls (#220). Source this file; do not execute it.
#
#   git_net <git args...>   runs `git <args>` and gives up after AUTOCODER_GIT_TIMEOUT
#                           seconds (default 60) instead of hanging.
#
# Why: a stalled HTTPS connection to the remote left `git fetch` in merge-launch.sh
# (via resolve_feature_sha) hanging for minutes, so the worker's foreground launch
# never returned and the issue sat under `working`. A bounded call fails fast and
# the caller's existing refusal path runs; the worker can retry.
#
# Two guards: http.lowSpeedLimit/Time aborts an HTTP transfer that stalls (works
# without coreutils `timeout`), and `timeout` caps the whole call including SSH and
# connect stalls. A timed-out call exits 124 (or 137 if it had to be killed), which
# callers treat like any other failure.
git_net() {
  local limit="${AUTOCODER_GIT_TIMEOUT:-60}"
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=60
  local -a cmd=(git -c http.lowSpeedLimit=1000 -c "http.lowSpeedTime=$(( limit < 30 ? limit : 30 ))")
  if command -v timeout >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 timeout -k 5 "$limit" "${cmd[@]}" "$@"
  else
    GIT_TERMINAL_PROMPT=0 "${cmd[@]}" "$@"
  fi
}
