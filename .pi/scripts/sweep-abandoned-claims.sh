#!/usr/bin/env bash
#
# sweep-abandoned-claims.sh — release `working` claims whose owner is provably
# gone, without waiting for /monitor-workers' 60-minute stale rule (#205,
# sub-task of #179).
#
# A claim is abandoned when ALL of these hold:
#   1. The issue's current claim carries owner markers (`🔒 claim <id> <ms> …`,
#      written by fix-loop-gate.sh via claim-owner.sh, #202). Only markers
#      posted after the last comment that ends or replaces a claim count (a
#      `[autocoder-claim]`, a 🔓 release, a 🚫/🎨 block, a "Releasing …" one):
#      an earlier claim's dead owner says nothing about a later re-claim, and a
#      re-claim made through /autocoder:fix leaves no owner marker at all.
#   2. Every such marker names an owner `<host>-<pid>` on THIS host whose
#      process is gone: the pid does not exist, or it exists but started at a
#      different time than the marker's `start=` (the pid was reused).
#   3. The newest marker is older than AUTOCODER_SWEEP_MIN_AGE_S. When
#      claim-owner.sh finds no long-lived agent process it names the gate's
#      short-lived caller, which is dead seconds after a perfectly live claim;
#      by the time the grace period ends that worker has created its branch.
#   4. No branch, local or on the remote, names the issue (`issue-<N>`). If the
#      remote cannot be read the sweep releases nothing: an unknown remote is
#      not proof that no work was pushed.
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
# Exit:   0 on success (including nothing to do); 1 when the issue list or the
#         remote's branches cannot be read (nothing is released).
#
# Env:    AUTOCODER_SWEEP_HOST       host name to compare owners against
#                                    (default: `hostname`)
#         AUTOCODER_SWEEP_START_SLOP seconds of start-time jitter tolerated
#                                    before a pid counts as reused (default 5)
#         AUTOCODER_SWEEP_MIN_AGE_S  seconds a claim must have stood before it
#                                    can be judged abandoned (default 120)

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
    -h|--help) sed -n '2,43p' "$0"; exit 0 ;;
    *) echo "sweep-abandoned-claims: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

HOST="${AUTOCODER_SWEEP_HOST:-$(hostname 2>/dev/null || echo host)}"
SLOP="${AUTOCODER_SWEEP_START_SLOP:-5}"
MIN_AGE_S="${AUTOCODER_SWEEP_MIN_AGE_S:-120}"

WORKING=$(issue_list --state working 2>/dev/null) || {
  echo "sweep-abandoned-claims: cannot list working issues" >&2; exit 1; }

# Issue numbers with a branch: the remote (claimed-issue-numbers.sh) plus local
# branches, which every worktree of this clone shares — a worker on this host
# may not have pushed yet.
# Read the remote directly rather than through claimed-issue-numbers.sh, which
# fails open (prints [] when the remote is unreachable): right for picking
# candidates, wrong for releasing claims. If the remote cannot be read, stop.
REMOTE_REFS=$(git ls-remote --heads "$REMOTE" 2>/dev/null) || {
  echo "sweep-abandoned-claims: cannot read branches from '$REMOTE'; releasing nothing" >&2; exit 1; }
BRANCH_NUMS=" $( { printf '%s\n' "$REMOTE_REFS" | sed 's#.*refs/heads/##'
                   git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null; } \
  | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+' | sort -un | tr '\n' ' ') "
NOW_MS=$(( $(date +%s) * 1000 ))

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
  if [[ "$BRANCH_NUMS" == *" $n "* ]]; then
    echo "kept #$n: a branch exists for it"; continue
  fi

  # The current claim's markers, one per line: "<id> <epoch-ms> <start-or-empty>".
  markers=$(issue_get "$n" 2>/dev/null | python3 -c '
import json, re, sys
try:
    issue = json.load(sys.stdin)
except Exception:
    sys.exit(3)
marker = re.compile(r"\s*🔒 claim (\S+) (\d+)(?: start=(\d+))?(?: wt=[^\n]*)?\s*$")
# Comments that end a claim (fix.md 🔓 releases, add-blocking-label.sh 🚫/🎨,
# the stale-label release in monitor-workers/manager-resume) or start a new one
# with no owner marker (/autocoder:fix posts `[autocoder-claim]`).
def ends_claim(body):
    b = body.lstrip()
    return ("[autocoder-claim]" in body or b.startswith(("🔓", "🚫", "🎨"))
            or b.lower().startswith("releasing"))
current = []
for c in issue.get("comments") or []:
    body = c.get("body") or ""
    m = marker.match(body)
    if m:
        current.append(" ".join([m.group(1), m.group(2), m.group(3) or ""]))
    elif ends_claim(body):
        current = []   # a later claim or a release supersedes earlier markers
print("\n".join(current))
') || { echo "kept #$n: could not read its comments"; continue; }

  if [ -z "$markers" ]; then
    echo "kept #$n: its current claim has no owner marker to judge"; continue
  fi
  newest_ms=$(awk '{ if ($2 > m) m = $2 } END { print m + 0 }' <<< "$markers")
  if [ $(( (NOW_MS - newest_ms) / 1000 )) -lt "$MIN_AGE_S" ]; then
    echo "kept #$n: claimed less than ${MIN_AGE_S}s ago"; continue
  fi

  verdict=dead; dead_ids=()
  while read -r id _ms start; do
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
