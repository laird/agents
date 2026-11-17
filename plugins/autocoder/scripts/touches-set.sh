#!/usr/bin/env bash
#
# touches-set.sh — keep an issue's `Touches:` line current (#229, sub-task of #186).
#
# The fix-loop gate steers workers away from areas a claimed issue declares
# (claims.avoid_overlap, touches-fns.sh). A declaration is only as good as it is
# accurate, so a worker declares its areas when it starts an issue and brings
# the line up to date after each commit with the files the branch really changed.
#
# Usage: touches-set.sh <issue> [--declare "<areas>"] [--base <ref>] [--dry-run]
#
#   --declare  comma-separated areas to add (paths, directories with a trailing
#              `/`, globs), e.g. the files a worker expects to edit before its
#              first commit
#   --base     ref the branch is compared with (default origin/$INTEGRATION_BRANCH,
#              else origin/main); `git diff --name-only <base>...HEAD`
#   --dry-run  print the new line, change nothing
#
# Declared entries are kept; each changed file not covered by one is added, and
# three or more changed files in one directory are collapsed to the directory.
# The body is rewritten on the GitHub backend. The other backends have no verb
# to edit a body, so there the line is printed for the worker to add by hand.
#
# Exit: 0 written, already current or printed; 1 a read, diff or write failed;
# 2 usage.

set -uo pipefail

_ts_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=issue-fns.sh
source "${_ts_DIR}/issue-fns.sh"
# shellcheck source=touches-fns.sh
source "${_ts_DIR}/touches-fns.sh"

ISSUE="" DECLARE="" BASE="" DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --declare|--base)
               [ $# -ge 2 ] || { echo "touches-set: $1 needs a value" >&2; exit 2; }
               if [ "$1" = --declare ]; then DECLARE="$2"; else BASE="$2"; fi
               shift 2 ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
    -*)        echo "touches-set: unknown option '$1'" >&2; exit 2 ;;
    *)         [ -z "$ISSUE" ] && ISSUE="$1" || { echo "touches-set: one issue only" >&2; exit 2; }; shift ;;
  esac
done
[ -n "$ISSUE" ] || { echo "usage: touches-set.sh <issue> [--declare \"<areas>\"] [--base <ref>] [--dry-run]" >&2; exit 2; }
BASE="${BASE:-origin/${INTEGRATION_BRANCH:-main}}"

CHANGED=$(git diff --name-only "${BASE}...HEAD") \
  || { echo "touches-set: cannot diff ${BASE}...HEAD" >&2; exit 1; }
BODY=$(issue_get "$ISSUE" | jq -r '.body // ""') \
  || { echo "touches-set: cannot read issue #${ISSUE}" >&2; exit 1; }

NEW=$(touches_update "$BODY" "$DECLARE" "$CHANGED"); rc=$?
case $rc in
  0) ;;
  3) echo "touches: #${ISSUE} already current"; exit 0 ;;
  *) echo "touches-set: could not compute the Touches: line" >&2; exit 1 ;;
esac
LINE=$(printf '%s\n' "$NEW" | head -n 1)

if $DRY; then
  echo "touches: #${ISSUE} would set: ${LINE}"
elif [ "${ISSUE_SOURCE:-}" = github ]; then
  printf '%s\n' "$NEW" | tail -n +2 | gh issue edit "$ISSUE" --body-file - >/dev/null \
    || { echo "touches-set: cannot edit #${ISSUE}'s body" >&2; exit 1; }
  echo "touches: #${ISSUE} ${LINE}"
else
  echo "touches: the ${ISSUE_SOURCE:-configured} backend cannot edit a body; add this line to #${ISSUE}'s body by hand:"
  echo "${LINE}"
fi
