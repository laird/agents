#!/usr/bin/env bash
#
# claim-takeover-fns.sh — recognise an ABANDONED claim so the gate can take the
# issue over instead of backing off from it forever (#203, sub-task of #179).
#
# A claim lock can outlive the process that took it: a worker claims, then dies,
# and the issue stays `working` with nobody on it until a human notices. Since
# #202 every claim names its long-lived owner:
#
#   🔒 claim <host>-<pid> <epoch-ms> [start=<epoch-s>] [wt=<path>]
#
# A claim is abandoned when there is no evidence of work (no feature/issue-N
# branch, local or on origin) AND either
#   - its owner is on THIS host and is dead: the pid is gone, or now belongs to a
#     different process (its start time differs from the recorded start=); or
#   - its owner is elsewhere, names no pid (AUTOCODER_WORKER_ID), or the marker
#     predates #202 (no wt= field: it named the gate's own pid, which is always
#     dead seconds later, so its pid proves nothing), and the claim is older than
#     the grace period, AUTOCODER_CLAIM_GRACE_S (default 120 s).
# A live owner, or any branch, means the claim stands. An issue is taken over only
# when EVERY claim on it is abandoned.
#
# Requires claim-owner.sh to be sourced (for _co_start).
#
#   claims_abandoned <issue-json> <issue-num> [<now-ms>]
#     stdout: one "<ms> <id> <reason>" line per claim, when all are abandoned
#     exit:   0 when the issue has at least one claim and all are abandoned;
#             1 otherwise (live claim, branch evidence, or no claim markers)

# _ct_branch_exists <issue-num> → exit 0 when feature/issue-N exists locally (the
# branch namespace every worktree on this host shares) or on origin.
_ct_branch_exists() {
  local n="$1"
  git show-ref --verify -q "refs/heads/feature/issue-${n}" && return 0
  git ls-remote --exit-code --heads origin "feature/issue-${n}" >/dev/null 2>&1 && return 0
  return 1
}

# _ct_owner_alive <pid> <recorded-start> → exit 0 when the pid is alive and is the
# same process the claim recorded (start time within a few seconds).
_ct_owner_alive() {
  local pid="$1" rec="$2" now_start
  kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$rec" ] || return 0            # no start recorded: a live pid is all we can check
  now_start=$(_co_start "$pid") || return 0
  [ $(( now_start > rec ? now_start - rec : rec - now_start )) -le 5 ]
}

claims_abandoned() {
  local json="$1" n="$2" now_ms="${3:-}" grace_ms host claims ms id start age pid out="" seen=0
  [ -n "$now_ms" ] || now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
  grace_ms=$(( ${AUTOCODER_CLAIM_GRACE_S:-120} * 1000 ))
  host=$(hostname 2>/dev/null || echo host)

  _ct_branch_exists "$n" && return 1

  # "<ms> <id> <start-or-dash> <has-wt>" per claim marker.
  claims=$(printf '%s' "$json" | jq -r '
    .comments[]?.body // ""
    | capture("^\\s*🔒 claim (?<id>\\S+) (?<ms>[0-9]+)( start=(?<start>[0-9]+))?(?<wt> wt=[^\\n]*)?\\s*$")?
    | "\(.ms) \(.id) \(.start // "-") \(if .wt then "wt" else "-" end)"' 2>/dev/null) || return 1
  [ -n "$claims" ] || return 1

  local has_wt
  while read -r ms id start has_wt; do
    [ -n "$ms" ] || continue
    seen=1
    [ "$start" = "-" ] && start=""
    age=$(( now_ms - ms ))
    if [ "$has_wt" = wt ] && [[ "$id" =~ ^(.+)-([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" = "$host" ]; then
      pid="${BASH_REMATCH[2]}"
      _ct_owner_alive "$pid" "$start" && return 1
      out+="${ms} ${id} owner pid ${pid} is no longer running on ${host}"$'\n'
    else
      [ "$age" -gt "$grace_ms" ] || return 1
      out+="${ms} ${id} no branch $(( age / 1000 ))s after the claim, owner not checkable from here"$'\n'
    fi
  done <<< "$claims"

  [ "$seen" -eq 1 ] || return 1
  printf '%s' "$out"
}
