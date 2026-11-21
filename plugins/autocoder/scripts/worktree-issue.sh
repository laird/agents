#!/bin/bash
# worktree-issue.sh: which issue each swarm worktree was working, and what to
# send its worker (#274, part of #271).
#
# After a reboot the manager restarts one worker per worktree on the issue that
# worktree already holds: the branch, its commits and its uncommitted edits are
# still there. This prints, for every linked worktree named <repo>-wt-*:
#
#   <path>\t<branch>\t<issue|->\t<state>\t<command>
#
#   issue    N from the branch name feature/issue-N or enhancement/issue-N-auto
#   state    claimed  issue open and holding a `working` claim
#            open     issue open, no `working` claim (corroboration missing;
#                     the worker still resumes it, /fix re-claims)
#            closed   issue closed: the worktree is free
#            none     the branch names no issue
#            unknown  the issue backend could not answer
#   command  /autocoder:fix N for claimed, open and unknown; /autocoder:fix-loop
#            for closed and none. Non-claude agents (AUTOCODER_AGENT) get bare
#            names.
#
# With --orphan-claims it prints instead the `working` claims whose worktree is
# gone, one "N\t<worktree-or-->" per line. File backend (a tracker local to this
# checkout): claims whose fix branch no worktree holds. Shared trackers (GitHub,
# Jira, ADO), which also hold other hosts' and clones' claims: only claims whose
# newest marker (`🔒 claim <host>-<pid> <ms> ... wt=<path>`, #202) names this host
# and a worktree directory that no longer exists. AUTOCODER_HOST_ID overrides the
# host name, for tests.
#
# Usage: worktree-issue.sh [--project DIR] [--orphan-claims]
# Exit: 0, 1 bad usage or not inside a git checkout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$PWD"
MODE=table
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || { echo "worktree-issue: --project needs a directory" >&2; exit 1; }
               PROJECT_DIR="$2"; shift 2 ;;
    --orphan-claims) MODE=orphans; shift ;;
    --marker-orphan) MODE=marker; shift ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "worktree-issue: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# marker_orphan: issue JSON on stdin → the worktree path when the newest claim
# marker names THIS host and a worktree directory that no longer exists.
marker_orphan() {
  local host
  host=$(hostname 2>/dev/null || echo host); host="${host//[[:space:]]/_}"
  HOST_ID="${AUTOCODER_HOST_ID:-$host}" python3 -c '
import json, os, re, sys
host = os.environ["HOST_ID"]
last = None
for c in json.load(sys.stdin).get("comments") or []:
    m = re.match(r"\s*🔒 claim (\S+) \d+(?: start=\d+)?(?: wt=([^\n]*))?\s*$", c.get("body") or "")
    if m:
        last = m
if last and last.group(2) and re.fullmatch(re.escape(host) + r"-\d+", last.group(1)) \
        and not os.path.isdir(last.group(2).strip()):
    print(last.group(2).strip())' 2>/dev/null
}

# Internal (tests): classify one issue JSON on stdin.
[ "$MODE" = marker ] && { marker_orphan; exit 0; }

COMMON=$(cd "$PROJECT_DIR" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) \
  || { echo "worktree-issue: $PROJECT_DIR is not inside a git checkout" >&2; exit 1; }
COMMON=$(cd "$PROJECT_DIR" && cd "$COMMON" && pwd -P)
case "$COMMON" in */.git) ROOT="${COMMON%/.git}" ;; *) echo "worktree-issue: bare repository" >&2; exit 1 ;; esac
cd "$ROOT" || exit 1
# The issue layer reads .autocoder.json from the main checkout.
# shellcheck source=issue-fns.sh
source "$SCRIPT_DIR/issue-fns.sh"
case "${AUTOCODER_AGENT:-claude}" in claude) PFX="autocoder:" ;; *) PFX="" ;; esac

# issue_of_branch <branch>: N, or nothing.
issue_of_branch() {
  printf '%s\n' "$1" | sed -nE 's#^feature/issue-([0-9]+)$#\1#p; s#^enhancement/issue-([0-9]+)-auto$#\1#p'
}

# "<path>\t<branch>" for every worktree, main first.
WORKTREES=$(git worktree list --porcelain | awk '
  /^worktree / { if (p != "") print p "\t" b; p = substr($0, 10); b = "" }
  /^branch refs\/heads\// { b = substr($0, 19) }
  END { if (p != "") print p "\t" b }')

if [ "$MODE" = orphans ]; then
  CLAIM_STATE=open; [ "${ISSUE_SOURCE:-}" = file ] && CLAIM_STATE=working
  claims=$(issue_list --state "$CLAIM_STATE" --label working --limit 200 2>/dev/null | python3 -c '
import json, sys
try:
    for i in json.load(sys.stdin):
        print(i["number"])
except Exception:
    sys.exit(1)') || { echo "worktree-issue: could not list working claims" >&2; exit 1; }
  if [ "${ISSUE_SOURCE:-}" = file ]; then
    # The file tracker lives in this checkout: every claim in it is this swarm's,
    # so one whose branch no worktree holds has lost its worktree.
    for n in $claims; do
      held=false
      while IFS='	' read -r _ b; do
        [ "$(issue_of_branch "$b")" = "$n" ] && { held=true; break; }
      done <<< "$WORKTREES"
      [ "$held" = true ] || printf '%s\t-\n' "$n"
    done
    exit 0
  fi
  # A shared tracker (GitHub, Jira, ADO) also holds other hosts' and other
  # clones' claims, which no worktree here would hold. Only a claim whose newest
  # marker (`🔒 claim <host>-<pid> <ms> ... wt=<path>`, #202) names THIS host and a
  # worktree directory that no longer exists has lost its worktree.
  for n in $claims; do
    json=$(issue_get "$n" 2>/dev/null) || continue
    wt=$(printf '%s' "$json" | marker_orphan)
    [ -n "$wt" ] && printf '%s\t%s\n' "$n" "$wt"
  done
  exit 0
fi

BASE=$(basename "$ROOT")
while IFS='	' read -r path branch; do
  case "$(basename "$path")" in "$BASE"-wt-*) ;; *) continue ;; esac
  n=$(issue_of_branch "$branch")
  if [ -z "$n" ]; then
    state=none
  elif ! json=$(issue_get "$n" 2>/dev/null) || [ -z "$json" ]; then
    state=unknown
  else
    state=$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if str(d.get("state", "")).lower() == "closed":
    print("closed")
elif any((l.get("name") if isinstance(l, dict) else l) == "working" for l in d.get("labels", [])):
    print("claimed")
else:
    print("open")' 2>/dev/null) || state=unknown
  fi
  case "$state" in
    closed|none) cmd="/${PFX}fix-loop" ;;
    *) cmd="/${PFX}fix $n" ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$path" "${branch:--}" "${n:--}" "$state" "$cmd"
done <<< "$WORKTREES"
