#!/bin/bash
# worker-state-fns.sh — remember which issue THIS worktree holds, so a worker that
# was compacted, cleared or restarted mid-issue resumes it instead of claiming new
# work and stranding its own `working` lock (#182).
#
# The record lives in the worktree's own git dir (per worktree, never committed,
# survives compaction and restarts):
#   $(git rev-parse --absolute-git-dir)/autocoder-worker-state   →  "<issue-number>"
#
# A claim this worktree holds is recognised from either source:
#   1. the record above, written when the gate claims an issue;
#   2. a checked-out feature/issue-N or enhancement/issue-N-auto branch, which
#      covers claims made before this record existed, or by /fix N directly.
# It is still held while the issue is OPEN and carries `working`. Anything else
# (closed, handed to the merge job as `merging`, parked, blocked, or released)
# means the claim ended, so the record is cleared and the next tick claims fresh.
#
# Requires issue-fns.sh to be sourced (issue_get).

worker_state_file() {
  local gd
  gd=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 1
  printf '%s/autocoder-worker-state\n' "$gd"
}

worker_state_set() {
  local f
  f=$(worker_state_file) || return 0
  printf '%s\n' "$1" > "$f" 2>/dev/null || true
}

worker_state_clear() {
  local f
  f=$(worker_state_file) || return 0
  rm -f "$f"
}

# _worker_issue_held <issue-json> → exit 0 when the issue is open and still `working`.
_worker_issue_held() {
  printf '%s' "$1" | jq -e \
    '(.state | ascii_upcase) == "OPEN" and ([.labels[]?.name] | index("working") != null)' \
    >/dev/null 2>&1
}

# worker_resume_plan → prints a work-plan JSON line and exits 0 when this worktree
# holds an open, `working` issue; exits 1 otherwise. Checks out the issue's local
# branch when the tree is clean and a different branch is checked out, because
# /fix treats a pre-claimed issue as a hand-off only from its own branch.
worker_resume_plan() {
  local state_file recorded="" branch cur_num="" n json phase prio target
  state_file=$(worker_state_file) || return 1
  [ -f "$state_file" ] && recorded=$(tr -dc '0-9' < "$state_file")

  branch=$(git branch --show-current 2>/dev/null || true)
  if [[ "$branch" =~ ^feature/issue-([0-9]+)$ ]] || [[ "$branch" =~ ^enhancement/issue-([0-9]+)-auto$ ]]; then
    cur_num="${BASH_REMATCH[1]}"
  fi

  for n in $recorded $cur_num; do
    json=$(issue_get "$n" 2>/dev/null) || continue
    if ! _worker_issue_held "$json"; then
      [ "$n" = "$recorded" ] && worker_state_clear
      continue
    fi

    if printf '%s' "$json" | jq -e '[.labels[]?.name] | index("enhancement") != null' >/dev/null 2>&1; then
      phase=enhance
    else
      phase=fix
    fi
    # /fix N works every gate-dispatched issue, enhancements included, on feature/issue-N.
    target="feature/issue-${n}"
    if [ "$n" != "$cur_num" ] && git show-ref --verify -q "refs/heads/${target}"; then
      if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
        git checkout -q "$target" 2>/dev/null || true
      else
        echo "worker-state: holding #${n} but the tree is dirty on '${branch}'; not switching to ${target}" >&2
      fi
    fi
    worker_state_set "$n"
    prio=$(printf '%s' "$json" | jq -r '[.labels[]?.name | select(test("^P[0-3]$"))] | sort | .[0] // "P2"')
    if [ "$phase" = fix ]; then
      printf '{"phase":"fix","issue":%s,"priority":"%s","resume":true}\n' "$n" "$prio"
    else
      printf '{"phase":"enhance","issue":%s,"resume":true}\n' "$n"
    fi
    return 0
  done
  return 1
}
