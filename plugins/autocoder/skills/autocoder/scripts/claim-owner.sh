#!/usr/bin/env bash
#
# claim-owner.sh — name the process that owns a claim for as long as the claim
# lives (#202, sub-task of #179).
#
# fix-loop-gate.sh used to sign its claim with its own pid ($$). The gate exits
# seconds after claiming, so every claim named a dead pid and nothing could
# tell a live claim from an orphan. The owner is the long-lived process
# instead, found in this order:
#
#   1. AUTOCODER_WORKER_ID  — an explicit id, used verbatim (no pid in it is
#                             assumed; the other fields are still recorded).
#   2. AUTOCODER_OWNER_PID  — exported by a worker loop (claude-worker-loop.sh)
#                             that outlives the agent sessions it starts. Used
#                             only while that pid is alive.
#   3. The nearest ancestor whose command is an agent CLI (claude, codex,
#      droid, gemini, pi) — the interactive session a /loop gate runs inside.
#   4. The claimer's parent (the gate's caller), as a last resort.
#
# Usage (sourced, as fix-loop-gate.sh does):
#   source claim-owner.sh
#   owner=$(claim_owner_pid $$)
#   id=$(claim_owner_id "$owner")        # <host>-<pid>
#   extra=$(claim_owner_extra "$owner")  # start=<epoch-s> wt=<path>
#   # marker: 🔒 claim <id> <epoch-ms> <extra>
#
# Usage (executed): claim-owner.sh  → "<id> <extra>"
#
# Fields, all whitespace-free except wt, which is always last so a path with
# spaces survives:
#   <host>-<pid>   the owner id (or AUTOCODER_WORKER_ID verbatim)
#   start=<s>      owner process start, epoch seconds (pid-reuse guard);
#                  omitted when it cannot be read
#   wt=<path>      the worktree the claim was made from

# Agent CLIs whose process is the long-lived owner of an interactive session.
CLAIM_OWNER_AGENTS="${CLAIM_OWNER_AGENTS:-claude codex droid gemini pi}"

# _co_comm <pid> — the process's command name, basename only.
_co_comm() {
  local c
  c=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
  c="${c##*/}"
  printf '%s\n' "${c//[[:space:]]/}"
}

# _co_ppid <pid>
_co_ppid() {
  local p
  p=$(ps -o ppid= -p "$1" 2>/dev/null) || return 1
  p="${p//[[:space:]]/}"
  [ -n "$p" ] && printf '%s\n' "$p"
}

# _co_start <pid> — process start time in epoch seconds, from `etime`
# ([[dd-]hh:]mm:ss), which both GNU and BSD ps support.
_co_start() {
  local et now d=0 h=0 m=0 s=0 rest a b c
  et=$(ps -o etime= -p "$1" 2>/dev/null) || return 1
  et="${et//[[:space:]]/}"
  [ -n "$et" ] || return 1
  case "$et" in *-*) d="${et%%-*}"; et="${et#*-}" ;; esac
  rest="$et"
  IFS=: read -r a b c <<< "$rest"
  if [ -n "$c" ]; then h=$a; m=$b; s=$c; else m=$a; s=$b; fi
  now=$(date +%s)
  echo $(( now - (10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s) ))
}

# claim_owner_pid <claimer-pid> — the owner pid, per the order above. The walk
# starts at the claimer's parent, so the short-lived claimer (the gate's own
# bash) is never chosen.
claim_owner_pid() {
  local claimer="$1" parent pid comm agent hops=0
  if [ -n "${AUTOCODER_OWNER_PID:-}" ] && kill -0 "$AUTOCODER_OWNER_PID" 2>/dev/null; then
    echo "$AUTOCODER_OWNER_PID"; return 0
  fi
  parent=$(_co_ppid "$claimer") || parent=""
  pid="$parent"
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$hops" -lt 32 ]; do
    comm=$(_co_comm "$pid") || break
    for agent in $CLAIM_OWNER_AGENTS; do
      if [ "$comm" = "$agent" ]; then echo "$pid"; return 0; fi
    done
    pid=$(_co_ppid "$pid") || break
    hops=$((hops + 1))
  done
  echo "${parent:-$claimer}"
}

# claim_owner_id <owner-pid> — the id a claim marker names.
claim_owner_id() {
  local id
  if [ -n "${AUTOCODER_WORKER_ID:-}" ]; then
    id="$AUTOCODER_WORKER_ID"
  else
    id="$(hostname 2>/dev/null || echo host)-$1"
  fi
  printf '%s\n' "${id//[[:space:]]/_}"
}

# claim_owner_extra <owner-pid> — the fields after the epoch-ms:
# "start=<s> wt=<path>", or "wt=<path>" when the start time is unreadable.
claim_owner_extra() {
  local start wt
  wt=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  if start=$(_co_start "$1"); then
    printf 'start=%s wt=%s\n' "$start" "$wt"
  else
    printf 'wt=%s\n' "$wt"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Executed: the claimer is whoever ran this script.
  _co_owner=$(claim_owner_pid "$$")
  printf '%s %s\n' "$(claim_owner_id "$_co_owner")" "$(claim_owner_extra "$_co_owner")"
fi
