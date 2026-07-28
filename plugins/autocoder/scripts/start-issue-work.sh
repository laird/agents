#!/usr/bin/env bash
# Claim an issue, switch to its issue branch, and post the visible start marker.
#
# Usage:
#   start-issue-work.sh <issue_number> [--phase fix|enhance]
#
# This is the worker-side concurrency handshake. The `working` label is the
# queue lock, while the issue branch and start comment let peers distinguish a
# live worker from an abandoned label.

set -euo pipefail

usage() {
  echo "Usage: $0 <issue_number> [--phase fix|enhance]" >&2
}

if [ $# -lt 1 ]; then
  usage
  exit 2
fi

ISSUE_NUM="$1"
shift
PHASE="fix"

while [ $# -gt 0 ]; do
  case "$1" in
    --phase)
      PHASE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$PHASE" in
  fix)
    BRANCH="feature/issue-${ISSUE_NUM}"
    MARKER="Automated Fix Started"
    TITLE="Automated Fix Started"
    ;;
  enhance)
    BRANCH="enhancement/issue-${ISSUE_NUM}-auto"
    MARKER="Enhancement Implementation Started"
    TITLE="Enhancement Implementation Started"
    ;;
  *)
    echo "Unknown phase: $PHASE" >&2
    usage
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=issue-fns.sh
source "${SCRIPT_DIR}/issue-fns.sh"

current_branch() {
  git branch --show-current 2>/dev/null || true
}

has_start_comment() {
  issue_get "$ISSUE_NUM" 2>/dev/null | jq -e \
    --arg marker "$MARKER" \
    --arg branch "$BRANCH" \
    '
      (((.comments // []) | any((.body // "") | contains($marker) and contains($branch))))
      or
      (((.body // "") | contains($marker) and contains($branch)))
    ' >/dev/null 2>&1
}

CURRENT_BRANCH="$(current_branch)"

if has_start_comment; then
  if [ "$CURRENT_BRANCH" = "$BRANCH" ]; then
    echo "Issue #${ISSUE_NUM} is already started on ${BRANCH}; continuing in this worktree."
    exit 0
  fi

  echo "Issue #${ISSUE_NUM} already has a start marker for ${BRANCH}; not taking it." >&2
  exit 1
fi

if ! issue_claim "$ISSUE_NUM" 2>/dev/null; then
  echo "Issue #${ISSUE_NUM} could not be claimed; another worker may own it." >&2
  exit 1
fi

if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
  if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    if ! git switch "$BRANCH" >/dev/null 2>&1; then
      echo "Branch ${BRANCH} exists but cannot be checked out here; another worktree may own it." >&2
      exit 1
    fi
  else
    # Base the new branch on the latest shared integration branch (default main, override
    # with INTEGRATION_BRANCH) instead of the worktree's current branch. In a parallel-
    # worktree swarm each worktree sits on its own main-wt-N; branching from
    # origin/<integration> means work starts from — and later merges back to — the same
    # shared branch rather than stranding on main-wt-N.
    INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')}"
    INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-main}"
    git fetch origin "$INTEGRATION_BRANCH" >/dev/null 2>&1 || true
    if ! git switch -c "$BRANCH" "origin/${INTEGRATION_BRANCH}" >/dev/null 2>&1 \
       && ! git switch -c "$BRANCH" >/dev/null 2>&1; then
      echo "Could not create branch ${BRANCH}." >&2
      exit 1
    fi
  fi
fi

issue_comment "$ISSUE_NUM" --body "🤖 **${TITLE}**

Starting automated work for this issue.

**Branch**: \`${BRANCH}\`
**Implementation Started**: $(date)

Work in progress..." 2>/dev/null || {
  echo "Warning: could not post start comment for issue #${ISSUE_NUM}." >&2
}

echo "Started issue #${ISSUE_NUM} on ${BRANCH}."
