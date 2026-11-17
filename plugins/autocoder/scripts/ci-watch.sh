#!/bin/bash
# ci-watch.sh — react to the integration branch's GitHub Actions CI for a landed commit.
#
# WHY THIS EXISTS:
#   The merge gate and the post-merge sentinel run the regression suite on this host. CI
#   runs other things (other OSes, other toolchains), and after a merge lands nothing in
#   the swarm looked at it: a master stayed red for hours with nobody told. This turns a
#   red CI run on the integration branch into a P0 `test-failure` issue a worker claims,
#   and closes that issue once a later landed commit's CI is green.
#
# USAGE:
#   ci-watch.sh [--repo DIR] [--integration main] [--state-dir DIR] <sha>
#   One call checks the CI runs of <sha> once. main-sentinel.sh calls it every tick with
#   the integration tip, so CI that is still pending is re-checked on a later tick.
#
# OUTCOMES for <sha>:
#   no runs, or a run still queued/in progress → nothing; re-checked on a later call
#   every run completed, one or more failed      → open the CI issue, or comment on it
#   every run completed, one succeeded, none failed → close the CI issue, if one is open
#   A sha is reported once: after it reaches a verdict, later calls for it exit at once.
#
# The CI issue is the open `test-failure` issue titled "CI red on <integration>"; it is
# found by title, so a lost state file or a second sentinel never files a duplicate.
#
# Best effort, always exit 0: no `gh`, no GitHub `origin`, or a gh/API failure is a
# silent no-op. Rate limit: at most one check per AUTOCODER_CI_WATCH_INTERVAL seconds
# (default 120) per repo and integration branch.

set -uo pipefail

_CW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO="" INTEGRATION="main" STATE_DIR="" SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--integration|--state-dir)
      [ $# -ge 2 ] || { echo "ci-watch.sh: $1 needs a value" >&2; exit 0; } ;;
  esac
  case "$1" in
    --repo)        REPO="$2"; shift 2 ;;
    --integration) INTEGRATION="$2"; shift 2 ;;
    --state-dir)   STATE_DIR="$2"; shift 2 ;;
    -*) echo "ci-watch.sh: unknown arg '$1'" >&2; exit 0 ;;
    *)  SHA="$1"; shift ;;
  esac
done
[ -n "$SHA" ] || { echo "usage: ci-watch.sh [--repo DIR] [--integration BR] [--state-dir DIR] <sha>" >&2; exit 0; }

command -v gh >/dev/null 2>&1 || exit 0
REPO=$(git -C "${REPO:-.}" rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$REPO" || exit 0
case "$(git config --get remote.origin.url 2>/dev/null)" in
  *github.com[:/]*) ;;
  *) exit 0 ;;
esac
SHA=$(git rev-parse -q --verify "${SHA}^{commit}" 2>/dev/null) || exit 0

# shellcheck source=repo-id-fns.sh
source "${_CW_DIR}/repo-id-fns.sh"
# shellcheck source=issue-fns.sh
source "${_CW_DIR}/issue-fns.sh" || exit 0

REPO_ID=$(autocoder_repo_id "$REPO") || exit 0
STATE_DIR="${STATE_DIR:-${AUTOCODER_SENTINEL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/sentinel}}"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
STATE_FILE="$STATE_DIR/${REPO_ID}-${INTEGRATION}.ci"
INTERVAL="${AUTOCODER_CI_WATCH_INTERVAL:-120}"
TITLE="CI red on ${INTEGRATION}"

# State: last_check=<epoch> of the last gh call, done_sha=<sha> that last reached a
# verdict, red_sha=<sha> last reported red.
last_check=0 done_sha="" red_sha=""
if [ -f "$STATE_FILE" ]; then
  while IFS='=' read -r k v; do
    case "$k" in last_check|done_sha|red_sha) printf -v "$k" '%s' "$v" ;; esac
  done < "$STATE_FILE"
fi
state_save() {
  printf 'last_check=%s\ndone_sha=%s\nred_sha=%s\n' "$last_check" "$done_sha" "$red_sha" \
    > "$STATE_FILE.tmp" && mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

[ "$SHA" = "$done_sha" ] && exit 0
now=$(date +%s)
[[ "$last_check" =~ ^[0-9]+$ ]] || last_check=0
[ $(( now - last_check )) -ge "$INTERVAL" ] || exit 0
last_check="$now"
state_save

RUNS=$(gh run list --commit "$SHA" --limit 100 --json databaseId,conclusion,name,status 2>/dev/null) || exit 0
VERDICT=$(printf '%s' "$RUNS" | python3 -c '
import json, sys
try:
    runs = json.load(sys.stdin)
except Exception:
    print("error"); sys.exit()
RED = {"failure", "timed_out", "startup_failure"}
if not runs:
    print("none")
elif any((r.get("status") or "") != "completed" for r in runs):
    print("pending")
elif any((r.get("conclusion") or "") in RED for r in runs):
    print("red")
elif any((r.get("conclusion") or "") == "success" for r in runs):
    print("green")
else:
    print("neutral")')

case "$VERDICT" in
  none|pending|error) exit 0 ;;
esac
done_sha="$SHA"

# The open CI issue, found by title.
find_ci_issue() {
  issue_list --state open --label test-failure 2>/dev/null | python3 -c '
import json, sys
t = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
for r in rows:
    if str(r.get("title", "")) == t and str(r.get("state", "OPEN")).upper() == "OPEN":
        print(r["number"]); break' "$TITLE"
}

# Issues whose push landed this sha, from refs/autocoder/tips/<integration>/<sha>-<issue>.
landing_issues() {
  git for-each-ref --format='%(refname)' "refs/autocoder/tips/${INTEGRATION}/${SHA}-*" 2>/dev/null \
    | sed 's/.*-//' | while read -r n; do
        if [[ "$n" =~ ^[0-9]+$ ]]; then printf '#%s ' "$n"; else printf '%s ' "$n"; fi
      done
}

# Markdown list of failing workflows, their failed jobs and failed steps.
failure_report() {
  local id name
  while IFS=$'\t' read -r id name; do
    [ -n "$id" ] || continue
    printf -- '- workflow **%s** (run %s)\n' "$name" "$id"
    gh run view "$id" --json jobs 2>/dev/null | python3 -c '
import json, sys
RED = {"failure", "timed_out", "startup_failure"}
try:
    jobs = json.load(sys.stdin).get("jobs", [])
except Exception:
    jobs = []
for j in jobs:
    if (j.get("conclusion") or "") not in RED:
        continue
    print("  - job `%s`" % j.get("name", "?"))
    for s in j.get("steps", []) or []:
        if (s.get("conclusion") or "") in RED:
            print("    - failed step: `%s`" % s.get("name", "?"))' || true
  done < <(printf '%s' "$RUNS" | python3 -c '
import json, sys
RED = {"failure", "timed_out", "startup_failure"}
for r in json.load(sys.stdin):
    if (r.get("conclusion") or "") in RED:
        print("%s\t%s" % (r.get("databaseId", ""), r.get("name", "?")))')
}

case "$VERDICT" in
  red)
    landed=$(landing_issues); landed="${landed% }"
    report="CI failed on \`${INTEGRATION}\` at \`${SHA}\`.

Landed by: ${landed:-an unrecorded push}

$(failure_report)"
    existing=$(find_ci_issue)
    if [ -n "$existing" ]; then
      issue_comment "$existing" --body "Still red. ${report}" >/dev/null 2>&1 \
        && echo "🔴 CI red at ${SHA:0:7}; updated #${existing}"
    else
      body="${report}

The integration branch's GitHub Actions CI is red. Fix forward on \`${INTEGRATION}\`.
This issue is updated while CI stays red and closed when a later landed commit's CI is green.

🤖 Filed by ci-watch.sh (post-merge sentinel)"
      out=$(issue_create --title "$TITLE" --body "$body" --label P0 --label test-failure 2>/dev/null) \
        && echo "🔴 CI red at ${SHA:0:7}; filed #$(printf '%s' "$out" | grep -oE '[0-9]+' | tail -1)"
    fi
    red_sha="$SHA"
    ;;
  green)
    # Only a commit at or after the last red one counts; a stale green sha must not
    # close a newer red report.
    if [ -z "$red_sha" ] || git merge-base --is-ancestor "$red_sha" "$SHA" 2>/dev/null; then
      existing=$(find_ci_issue)
      if [ -n "$existing" ]; then
        issue_close "$existing" --comment "✅ CI is green on \`${INTEGRATION}\` at \`${SHA}\`." >/dev/null 2>&1 \
          && echo "🟢 CI green at ${SHA:0:7}; closed #${existing}"
      fi
      red_sha=""
    fi
    ;;
esac
state_save
exit 0
