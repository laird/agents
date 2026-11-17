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
#     different process (its start time differs from the recorded start=), AND
#     the claim's worktree (wt=) does not hold THIS claim in its #182 record (same
#     issue and same claim timestamp) within the grace period. The record catches
#     an owner pid that was only ever short-lived (claim-owner.sh falls back to the
#     gate's parent when it finds no agent ancestor): the gate writes it in the
#     same run as the claim. It stops counting after the grace period, so a record
#     left behind by a crashed worker cannot keep a dead claim alive forever; or
#   - its owner cannot be checked from here (another host, no pid, or a marker
#     from before #202, which named the gate's own always-dead pid) and the claim
#     is older than AUTOCODER_CLAIM_GRACE_S (default 7200 s). Another host's
#     branch only shows on origin once it is pushed, often most of an hour into
#     the work, so this grace must be long.
# A live owner, a worktree record, any branch, or an origin that cannot be asked,
# means the claim stands. An issue is taken over only when EVERY claim on it is
# abandoned.
#
# Requires claim-owner.sh to be sourced (for _co_start).
#
#   claims_abandoned <issue-json> <issue-num> [<now-ms>]
#     stdout: one "<ms> <id> <reason>" line per claim, when all are abandoned
#     exit:   0 when the issue has at least one claim and all are abandoned;
#             1 otherwise (live claim, branch evidence, or no claim markers)

# _ct_branch_exists <issue-num> → exit 0 when feature/issue-N exists locally (the
# branch namespace every worktree on this host shares) or on origin, AND when
# origin cannot be asked: only a definite "no such branch" (ls-remote exit 2)
# counts as no evidence.
_ct_branch_exists() {
  local n="$1" rc=0
  git show-ref --verify -q "refs/heads/feature/issue-${n}" && return 0
  git ls-remote --exit-code --heads origin "feature/issue-${n}" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 2 ]
}

# _ct_worktree_holds <wt-path> <issue-num> <claim-ms> → exit 0 when that
# worktree's #182 record (worker-state-fns.sh: "<issue> <claim-ms> ...") is this
# very claim, not merely the same issue number.
_ct_worktree_holds() {
  local wt="$1" n="$2" ms="$3" gd rec_n="" rec_ms=""
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  gd=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  read -r rec_n rec_ms _ < "$gd/autocoder-worker-state" 2>/dev/null || return 1
  [ "$rec_n" = "$n" ] && [ "$rec_ms" = "$ms" ]
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
  grace_ms=$(( ${AUTOCODER_CLAIM_GRACE_S:-7200} * 1000 ))
  host=$(hostname 2>/dev/null || echo host)

  # "<ms> <id> <start-or-dash> <wt-or-dash>" per claim marker; wt is last, as it
  # may contain spaces.
  claims=$(printf '%s' "$json" | jq -r '
    .comments[]?.body // ""
    | capture("^\\s*🔒 claim (?<id>\\S+) (?<ms>[0-9]+)( start=(?<start>[0-9]+))?( wt=(?<wt>[^\\n]*))?\\s*$")?
    | "\(.ms) \(.id) \(.start // "-") \(.wt // "-")"' 2>/dev/null) || return 1
  [ -n "$claims" ] || return 1

  local wt
  while read -r ms id start wt; do
    [ -n "$ms" ] || continue
    seen=1
    [ "$start" = "-" ] && start=""
    age=$(( now_ms - ms ))
    if [ "$wt" != "-" ] && [[ "$id" =~ ^(.+)-([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" = "$host" ]; then
      pid="${BASH_REMATCH[2]}"
      _ct_owner_alive "$pid" "$start" && return 1
      [ "$age" -le "$grace_ms" ] && _ct_worktree_holds "$wt" "$n" "$ms" && return 1
      out+="${ms} ${id} owner pid ${pid} is no longer running on ${host}"$'\n'
    else
      [ "$age" -gt "$grace_ms" ] || return 1
      out+="${ms} ${id} no branch $(( age / 1000 ))s after the claim, owner not checkable from here"$'\n'
    fi
  done <<< "$claims"

  [ "$seen" -eq 1 ] || return 1
  # Last, as it is the one network call: any branch means work is under way.
  _ct_branch_exists "$n" && return 1
  printf '%s' "$out"
}
