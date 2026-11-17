#!/usr/bin/env bash
# bounce-resume.sh — find the merge bounce this worktree owns (#208).
#
# WHY THIS EXISTS:
#   When a merge job hits a conflict or a red gate that its change caused, it hands
#   the issue back to the worker that launched it (#207): the issue goes back to
#   `working`, and a comment ends in
#     <!-- autocoder-bounce kind=<conflict|gate> worktree=<top level> sha=<sha> sig=<sig> -->
#   Nothing then sent that worker back to it. Its loop claimed new work instead,
#   and the bounced issue sat in `working` with a live branch, which no other
#   worker may claim either (#140, agents-ui #412). The owner must resolve its own
#   bounce before it claims anything new; this script tells it which one.
#
#   The owner is matched by worktree path, not worker id: worker ids are
#   <hostname>-<pid> and change every tick.
#
# USAGE:
#   bounce-resume.sh find  [worktree]          print "<issue> <kind>" for this
#                                              worktree's oldest open bounce
#   bounce-resume.sh check <issue> [worktree]  print "<kind>" when <issue> is
#                                              bounced to this worktree
#   worktree defaults to `git rev-parse --show-toplevel`.
#
# A bounce counts only while the issue is open and labelled `working` (the job
# re-labels it `merging` when relaunched), and only if its marker is the newest
# one and no "Automated Fix Started" comment came after it (someone else took it).
#
# Exit: 0 found; 1 none; 2 bad arguments or no backend. Always fails toward
#   "none", so a backend error can never stop a worker from claiming new work.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:-}"; shift || true
case "$MODE" in
  find)  ISSUE=""; WT="${1:-}" ;;
  check) ISSUE="${1:-}"; WT="${2:-}"
         [[ "$ISSUE" =~ ^[0-9]+$ ]] || { echo "bounce-resume.sh: check needs an issue number" >&2; exit 2; } ;;
  *) echo "usage: bounce-resume.sh find [worktree] | check <issue> [worktree]" >&2; exit 2 ;;
esac
[ -n "$WT" ] || WT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "bounce-resume.sh: not in a git worktree" >&2; exit 2; }
WT=$(cd "$WT" 2>/dev/null && pwd -P) || exit 2

# shellcheck source=issue-fns.sh
source "${SCRIPT_DIR}/issue-fns.sh" 2>/dev/null || exit 2

# owns <issue-json> — prints the kind when this worktree owns the newest live bounce.
owns() {
  ISSUE_JSON="$1" ME="$WT" python3 - <<'PY'
import json, os, re, sys
try:
    issue = json.loads(os.environ["ISSUE_JSON"])
except ValueError:
    sys.exit(1)
if str(issue.get("state", "")).upper() != "OPEN":
    sys.exit(1)
labels = {l.get("name") for l in issue.get("labels") or []}
if "working" not in labels or "merging" in labels:
    sys.exit(1)
# Events in the order they were written. GitHub/Jira/ADO keep comments in
# comments[]; the file backend appends them to the body, so read the body first,
# then each comment, and within each text take matches in position order.
event = re.compile(
    r"<!-- autocoder-bounce kind=(?P<kind>[a-z]+) worktree=(?P<wt>.+?) sha=\S* sig=\S* -->"
    r"|(?P<start>Automated Fix Started|Enhancement Implementation Started)")
texts = [issue.get("body") or ""] + [(c.get("body") or "") for c in issue.get("comments") or []]
newest = None
for text in texts:
    for m in event.finditer(text):
        if m.group("kind"):
            newest = (m.group("kind"), m.group("wt"))
        else:
            newest = None   # work (re)started after the bounce: it is whoever started it
if not newest:
    sys.exit(1)
kind, owner = newest
try:
    owner = os.path.realpath(owner)
except OSError:
    pass
if owner != os.environ["ME"]:
    sys.exit(1)
print(kind)
PY
}

if [ "$MODE" = check ]; then
  json=$(issue_get "$ISSUE" 2>/dev/null) || exit 1
  owns "$json"
  exit $?
fi

# find: oldest first, so a worker clears its backlog in order. Only issues with a
# local feature/issue-N branch can be ours: the merge was launched from this repo,
# and its branches are shared by every worktree of it. That keeps the per-issue
# issue_get calls to our own candidates, not every worker's live issue.
LOCAL=$(git for-each-ref --format='%(refname:lstrip=2)' 'refs/heads/feature/issue-*' 2>/dev/null \
  | sed -nE 's#^feature/issue-([0-9]+)$#\1#p' | tr '\n' ' ')
[ -n "$LOCAL" ] || exit 1
nums=$(issue_list --state working --limit 200 2>/dev/null | LOCAL="$LOCAL" python3 -c '
import json, os, sys
mine = set(os.environ["LOCAL"].split())
try:
    issues = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
print(" ".join(str(n) for n in sorted(i["number"] for i in issues if str(i["number"]) in mine)))') || exit 1
for n in $nums; do
  json=$(issue_get "$n" 2>/dev/null) || continue
  if kind=$(owns "$json"); then
    echo "$n $kind"
    exit 0
  fi
done
exit 1
