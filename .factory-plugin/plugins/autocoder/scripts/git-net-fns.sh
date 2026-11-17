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
# Two guards: http.lowSpeedLimit/Time aborts an HTTP transfer that sends under 1 KB/s
# for the whole limit (the only guard where coreutils `timeout` is missing), and `timeout` caps the whole call including SSH and
# connect stalls. A timed-out call exits 124 (or 137 if it had to be killed), which
# callers treat like any other failure. git_net_timed_out <rc> says whether that
# was the cause. Interactive prompts are off: a human running this by hand needs
# credentials from a helper or agent, not a typed password.
git_net_timed_out() { [ "${1:-0}" -eq 124 ] || [ "${1:-0}" -eq 137 ]; }
git_net() {
  local limit="${AUTOCODER_GIT_TIMEOUT:-60}"
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=60
  local -a cmd=(git -c http.lowSpeedLimit=1000 -c "http.lowSpeedTime=${limit}")
  if command -v timeout >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 timeout -k 5 "$limit" "${cmd[@]}" "$@"
  else
    GIT_TERMINAL_PROMPT=0 "${cmd[@]}" "$@"
  fi
}

# git_net_long <git args...>: git_net with AUTOCODER_GIT_TIMEOUT_LONG (default 300s), for
# transfers that can legitimately take minutes: the detached merge job's fetches of the
# integration branch and its pushes (#234). A stall there used to hang the job for as
# long as the connection did, with the issue stuck under `merging`.
git_net_long() {
  AUTOCODER_GIT_TIMEOUT="${AUTOCODER_GIT_TIMEOUT_LONG:-300}" git_net "$@"
}
