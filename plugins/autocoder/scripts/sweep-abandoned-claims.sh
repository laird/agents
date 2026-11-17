#!/usr/bin/env bash
#
# sweep-abandoned-claims.sh — release `working` claims whose owner is provably
# gone, without waiting for /monitor-workers' 60-minute stale rule (#205,
# sub-task of #179).
#
# A claim is abandoned when ALL of these hold:
#   1. The issue carries at least one claim marker (`🔒 claim <id> <ms> …`,
#      written by fix-loop-gate.sh via claim-owner.sh, #202).
#   2. Every marker names an owner `<host>-<pid>` on THIS host whose process is
#      gone: the pid does not exist, or it exists but started at a different
#      time than the marker's `start=` (the pid was reused).
#   3. No branch, local or on the remote, names the issue (`issue-<N>`).
#
# Anything this host cannot judge is left alone: a claim from another host, an
# id that is not `<host>-<pid>` (AUTOCODER_WORKER_ID set verbatim), an issue
# with no marker at all (claimed by /autocoder:fix's `[autocoder-claim]` path),
# or one with a branch. Those still fall to the 60-minute rule.
#
# A released issue gets a comment naming the dead owner(s), then loses the
# `working` label, so peers can tell a sweep from a crashed worker.
#
# Usage:  sweep-abandoned-claims.sh [--dry-run] [--remote <name>]
# Output: one line per `working` issue: `released #N: …` or `kept #N: …`.
# Exit:   0 on success (including nothing to do); 1 when the issue list cannot
#         be read.
#
# Env:    AUTOCODER_SWEEP_HOST       host name to compare owners against
#                                    (default: `hostname`)
#         AUTOCODER_SWEEP_START_SLOP seconds of start-time jitter tolerated
#                                    before a pid counts as reused (default 5)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=issue-fns.sh
source "${SCRIPT_DIR}/issue-fns.sh"
# shellcheck source=claim-owner.sh
source "${SCRIPT_DIR}/claim-owner.sh"   # for _co_start

DRY_RUN=false
REMOTE=origin
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --remote)  REMOTE="${2:?--remote needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "sweep-abandoned-claims: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

HOST="${AUTOCODER_SWEEP_HOST:-$(hostname 2>/dev/null || echo host)}"
SLOP="${AUTOCODER_SWEEP_START_SLOP:-5}"

WORKING=$(issue_list --state working 2>/dev/null) || {
  echo "sweep-abandoned-claims: cannot list working issues" >&2; exit 1; }

# Issue numbers with a branch: the remote (claimed-issue-numbers.sh) plus local
# branches, which every worktree of this clone shares — a worker on this host
# may not have pushed yet.
REMOTE_NUMS=$(bash "${SCRIPT_DIR}/claimed-issue-numbers.sh" "$REMOTE" 2>/dev/null || echo "[]")
LOCAL_NUMS=$(git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null \
  | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+' | sort -un | tr '\n' ' ')

# owner_dead <pid> <start-or-empty> — 0 when the owner process is gone.
owner_dead() {
  local pid="$1" want="$2" have
  ps -p "$pid" >/dev/null 2>&1 || return 0
  [ -n "$want" ] || return 1
  have=$(_co_start "$pid") || return 1
  [ $(( have > want ? have - want : want - have )) -gt "$SLOP" ]
}

NUMS=$(printf '%s' "$WORKING" | jq -r '.[]? | .number' 2>/dev/null)
for n in $NUMS; do
  if printf '%s' "$REMOTE_NUMS" | jq -e --argjson n "$n" 'index($n) != null' >/dev/null 2>&1 \
     || [[ " $LOCAL_NUMS " == *" $n "* ]]; then
    echo "kept #$n: a branch exists for it"; continue
  fi

  # One line per marker: "<id> <start-or-empty>".
  markers=$(issue_get "$n" 2>/dev/null | python3 -c '
import json, re, sys
try:
    issue = json.load(sys.stdin)
except Exception:
    sys.exit(3)
for c in issue.get("comments") or []:
    m = re.match(r"\s*🔒 claim (\S+) \d+(?: start=(\d+))?(?: wt=[^\n]*)?\s*$", c.get("body") or "")
    if m:
        print(m.group(1), m.group(2) or "")
') || { echo "kept #$n: could not read its comments"; continue; }

  if [ -z "$markers" ]; then
    echo "kept #$n: no claim marker to judge"; continue
  fi

  verdict=dead; dead_ids=()
  while read -r id start; do
    host="${id%-*}"; pid="${id##*-}"
    if [ "$host" = "$id" ] || ! [[ "$pid" =~ ^[0-9]+$ ]]; then
      verdict="owner $id is not <host>-<pid>"; break
    fi
    if [ "$host" != "$HOST" ]; then
      verdict="owner $id is on another host"; break
    fi
    if ! owner_dead "$pid" "$start"; then
      verdict="owner $id is alive"; break
    fi
    dead_ids+=("$id")
  done <<< "$markers"

  if [ "$verdict" != dead ]; then
    echo "kept #$n: $verdict"; continue
  fi

  owners="${dead_ids[*]}"
  if $DRY_RUN; then
    echo "released #$n: owner(s) $owners dead on $HOST, no branch (dry run)"; continue
  fi
  issue_comment "$n" --body "🔓 **Releasing abandoned claim**

**Reason**: the claim's owner process ($owners) is no longer running on \`$HOST\`, and no \`issue-$n\` branch exists locally or on \`$REMOTE\`, so no work was in flight.
**Released by**: \`sweep-abandoned-claims.sh\` (/monitor-workers)

Releasing the \`working\` lock so another agent can pick this up." >/dev/null 2>&1 \
    || { echo "kept #$n: could not post the release comment"; continue; }
  if issue_release "$n" >/dev/null 2>&1; then
    echo "released #$n: owner(s) $owners dead on $HOST, no branch"
  else
    echo "kept #$n: comment posted but the label could not be removed"
  fi
done
exit 0
