#!/bin/bash
# worker-state-fns.sh — remember which issue THIS worktree holds, so a worker that
# was compacted, cleared or restarted mid-issue resumes it instead of claiming new
# work and stranding its own `working` lock (#182).
#
# The record lives in the worktree's own git dir (per worktree, never committed,
# survives compaction and restarts):
#   $(git rev-parse --absolute-git-dir)/autocoder-worker-state  →  "<issue> [<claim-ms>]"
# <claim-ms> is the timestamp of this worktree's `🔒 claim <id> <ms> [start=<s>] wt=<path>`
# comment (owner fields since #202; older markers end at <ms>), written
# by the gate on GitHub/Jira/ADO; the file backend's atomic claim leaves no comment.
#
# A recorded issue is resumed only when ALL hold:
#   - it is OPEN and still carries `working`;
#   - it is still ours: no `🔒 claim` comment was posted after our claim's race
#     window, so an issue released and since re-claimed elsewhere is not taken back;
#   - this worktree is, or can be switched (clean tree) onto, feature/issue-N, or
#     that branch does not exist yet (compacted before /fix created it). /fix treats
#     a pre-claimed issue as a resume only from its own branch.
# A checked-out branch alone is never enough: it cannot show who owns the issue now.
# When the claim has ended (closed, `merging`, parked, blocked, released, re-claimed)
# the record is cleared and the next tick claims fresh work.
#
# Requires issue-fns.sh to be sourced (issue_get).

worker_state_file() {
  local gd
  gd=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 1
  printf '%s/autocoder-worker-state\n' "$gd"
}

# worker_state_set <issue> [<claim-ms>]
worker_state_set() {
  local f
  f=$(worker_state_file) || return 0
  printf '%s %s\n' "$1" "${2:-}" > "$f" 2>/dev/null || true
}

worker_state_clear() {
  local f
  f=$(worker_state_file) || return 0
  rm -f "$f"
}

# _worker_still_ours <issue-json> <recorded-ms> → exit 0 when the issue is open,
# `working`, and nobody has claimed it since our claim's race settled. Racers that
# lost to us posted within the gate's claim window (AUTOCODER_CLAIM_WINDOW_S) and
# their comments stay on the issue, so only a claim AFTER that window — a re-claim
# once ours was released — means it is no longer ours. With no recorded claim (the
# file backend's atomic claim leaves no comment) the label alone decides.
_worker_still_ours() {
  printf '%s' "$1" | MS="$2" WINDOW_MS="$(( ${AUTOCODER_CLAIM_WINDOW_S:-120} * 1000 ))" jq -e '
    ((.state | ascii_upcase) == "OPEN")
    and ([.labels[]?.name] | index("working") != null)
    and (env.MS == ""
         or ([.comments[]?.body // ""
              | capture("^\\s*🔒 claim \\S+ (?<ms>[0-9]+)( start=[0-9]+)?( wt=[^\\n]*)?\\s*$")?.ms | tonumber]
             | all(. <= ((env.MS | tonumber) + (env.WINDOW_MS | tonumber)))))
  ' >/dev/null 2>&1
}

# worker_resume_plan → exit 0 and print a work-plan JSON line when this worktree
# holds an open, `working` issue it can resume now; exit 2 when it holds one but
# cannot resume it this tick (dirty tree), so the caller must not claim new work
# over it; exit 1 when it holds nothing.
worker_resume_plan() {
  local state_file n="" ms="" json target phase prio
  state_file=$(worker_state_file) || return 1
  [ -f "$state_file" ] || return 1
  read -r n ms < "$state_file" || true
  n="${n//[^0-9]/}"; ms="${ms//[^0-9]/}"
  [ -n "$n" ] || { worker_state_clear; return 1; }

  json=$(issue_get "$n" 2>/dev/null) || return 1   # backend hiccup: keep the record for the next tick
  if ! _worker_still_ours "$json" "$ms"; then
    worker_state_clear
    return 1
  fi

  target="feature/issue-${n}"
  if [ "$(git branch --show-current 2>/dev/null)" != "$target" ]; then
    local have_local=0 have_remote=0
    git show-ref --verify -q "refs/heads/${target}" && have_local=1
    git fetch -q origin "+refs/heads/${target}:refs/remotes/origin/${target}" 2>/dev/null && have_remote=1
    if [ "$have_local" -eq 0 ] && [ "$have_remote" -eq 0 ]; then
      : # Claimed, but compacted before /fix made the branch: resume, and /fix creates it.
    elif [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
      # Mid-edit on something else. Still ours, so neither resume nor claim new work.
      echo "worker-state: holding #${n} but the tree is dirty; not switching to ${target}" >&2
      return 2
    elif ! { [ "$have_local" -eq 1 ] && git checkout -q "$target" 2>/dev/null; } \
         && ! { [ "$have_local" -eq 0 ] && git checkout -q -b "$target" "origin/${target}" 2>/dev/null; }; then
      # The branch is checked out in another worktree: this worktree cannot carry
      # the issue on, so let it go rather than retry it every tick.
      echo "worker-state: cannot switch to ${target}; dropping the record for #${n}" >&2
      worker_state_clear
      return 1
    fi
  fi

  if printf '%s' "$json" | jq -e '[.labels[]?.name] | index("enhancement") != null' >/dev/null 2>&1; then
    phase=enhance
  else
    phase=fix
  fi
  prio=$(printf '%s' "$json" | jq -r '[.labels[]?.name | select(test("^P[0-3]$"))] | sort | .[0] // "P2"' 2>/dev/null || echo P2)
  if [ "$phase" = fix ]; then
    printf '{"phase":"fix","issue":%s,"priority":"%s","resume":true}\n' "$n" "$prio"
  else
    printf '{"phase":"enhance","issue":%s,"resume":true}\n' "$n"
  fi
  return 0
}
