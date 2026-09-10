#!/bin/bash
# issues-gh.sh — GitHub backend implementing the uniform 9-verb CLI.
#
# Counterpart to issues-file.py. Both backends honor the same contract:
#   <backend> list [--state open|working|blocked|closed|all] [--label L] [--limit N]
#   <backend> get <number>
#   <backend> update <number> [--add-label L] [--remove-label L] [--status S] [--assignee A]
#   <backend> comment <number> --body "..."
#   <backend> close <number> [--comment "..."]
#   <backend> create --title "..." --body "..." [--label L ...]
#   <backend> claim <number>
#   <backend> release <number>
#   <backend> any-claimable
#
# Exit codes:
#   0 — success / work exists
#   1 — clean negative (no claimable, race lost, issue not found)
#   2 — usage error
#   3 — backend error (gh failure, auth failure, parse error)
#
# Output schema for list/get matches issues-file.py's to_gh_json shape
# (number, title, body, state OPEN|CLOSED, labels[{name}], comments[]).
#
# Notes:
#   - claim is BEST-EFFORT on github (no atomic single-writer label edit
#     in the gh API). Concurrent claims may both succeed; see the spec
#     for rationale.
#   - --state open/working/blocked filter by label, since gh has no
#     directory partitioning. blocked = any of the BLOCKING_LABELS.

set -e

# The approved-work gate: when a required label is configured, only issues
# carrying it are claimable. See issue-approval-lib.sh.
_igh_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=issue-approval-lib.sh
source "${_igh_DIR}/issue-approval-lib.sh"
REQUIRED_LABEL="$(required_issue_label)"

# Render the gate as a search qualifier, empty when the gate is off.
_igh_required_search() {
  [ -n "$REQUIRED_LABEL" ] || return 0
  printf ' label:"%s"' "$REQUIRED_LABEL"
}

# Exclude each blocking label with `-label:"X"`. NOT `no:label "X"` — `no:label`
# is a valueless qualifier meaning "issue has no labels at all", so that form
# matches only unlabeled issues and silently hides every real issue, leaving the
# autocoder loop permanently idle. See tests/test_issues_gh_search.sh.
# `awaiting-integration` is excluded from the claimable queue but deliberately
# absent from BLOCKED_LABEL_SEARCH below: the work is finished and waiting to be
# merged, not blocked on a human decision, so /review-blocked must not surface it.
BLOCKING_SEARCH='-label:"working" -label:"needs-design" -label:"needs-clarification" -label:"needs-feedback" -label:"needs-approval" -label:"too-complex" -label:"future" -label:"proposal" -label:"awaiting-integration"'
BLOCKED_LABEL_SEARCH='label:"needs-design" OR label:"needs-clarification" OR label:"needs-feedback" OR label:"needs-approval" OR label:"too-complex" OR label:"future" OR label:"proposal"'

# ── list ───────────────────────────────────────────────────────────────────
cmd_list() {
  local args=() label="" state="open" limit=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) label="$2"; shift 2 ;;
      --state) state="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *)       shift ;;
    esac
  done
  local search=""
  case "$state" in
    # Only the claimable queue is gated. `working` and `blocked` deliberately
    # are not: an issue claimed before the gate was configured must stay
    # visible to the manager, and hiding in-flight work would read as the
    # worker having vanished.
    open)    search="$BLOCKING_SEARCH$(_igh_required_search)" ;;
    working) search='label:"working"' ;;
    blocked) search="$BLOCKED_LABEL_SEARCH" ;;
    closed)  args+=(--state closed) ;;
    all)     args+=(--state all) ;;
    *)       echo "Unknown state: $state" >&2; exit 2 ;;
  esac
  [ "$state" = "open" ] || [ "$state" = "working" ] || [ "$state" = "blocked" ] && args+=(--state open)
  [ -n "$search" ] && args+=(--search "$search")
  [ -n "$label" ] && args+=(--label "$label")
  # Default the page size well above gh's own default of 30. With --search in
  # play gh goes through the search API, whose ordering is "best match" over a
  # purely negative query — so a 30-issue page is an arbitrary slice, not the
  # newest or the highest priority. Callers rank P0>P1>P2>P3 *after* this call,
  # which only ever reorders whatever the slice happened to contain: an
  # unblocked P0 outside the page is invisible, not deprioritised, and the
  # swarm reports IDLE_NO_WORK_AVAILABLE with real work outstanding.
  args+=(--limit "${limit:-200}")
  gh issue list "${args[@]}" --json number,title,body,labels,state || exit 3
}

# ── get ────────────────────────────────────────────────────────────────────
cmd_get() {
  local n="$1"
  gh issue view "$n" --json number,title,body,labels,state,comments || exit 1
}

# ── update ─────────────────────────────────────────────────────────────────
cmd_update() {
  local number="$1"; shift
  local add_labels=() remove_labels=() status="" assignee=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --add-label)    add_labels+=("$2"); shift 2 ;;
      --remove-label) remove_labels+=("$2"); shift 2 ;;
      --status)       status="$2"; shift 2 ;;
      --assignee)     assignee="$2"; shift 2 ;;
      *)              shift ;;
    esac
  done
  if [ -n "$status" ]; then
    case "$status" in
      closed)  gh issue close "$number" || exit 3 ;;
      open)    gh issue reopen "$number" || exit 3 ;;
      working) gh issue edit "$number" --add-label "working" >/dev/null || exit 3 ;;
    esac
  fi
  local edit_args=()
  for l in "${add_labels[@]}";    do edit_args+=(--add-label    "$l"); done
  for l in "${remove_labels[@]}"; do edit_args+=(--remove-label "$l"); done
  [ -n "$assignee" ] && edit_args+=(--add-assignee "$assignee")
  if [ "${#edit_args[@]}" -gt 0 ]; then
    gh issue edit "$number" "${edit_args[@]}" >/dev/null || exit 3
  fi
}

# ── comment ────────────────────────────────────────────────────────────────
cmd_comment() {
  local number="$1"; shift
  local body=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --body) body="$2"; shift 2 ;; *) shift ;; esac
  done
  gh issue comment "$number" --body "$body" >/dev/null || exit 3
}

# ── close ──────────────────────────────────────────────────────────────────
cmd_close() {
  local number="$1"; shift
  local comment=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --comment) comment="$2"; shift 2 ;; *) shift ;; esac
  done
  if [ -n "$comment" ]; then
    gh issue close "$number" --comment "$comment" || exit 3
  else
    gh issue close "$number" || exit 3
  fi
}

# ── create ─────────────────────────────────────────────────────────────────
cmd_create() {
  local title="" body="" labels=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --body)  body="$2"; shift 2 ;;
      --label) labels+=("$2"); shift 2 ;;
      *)       shift ;;
    esac
  done
  local create_args=(--title "$title" --body "$body")
  for l in "${labels[@]}"; do create_args+=(--label "$l"); done
  local issue_url number
  issue_url=$(gh issue create "${create_args[@]}") || exit 3
  number=$(echo "$issue_url" | grep -oE '[0-9]+$')
  echo "{\"number\": $number}"
}

# ── claim (best-effort) ────────────────────────────────────────────────────
cmd_claim() {
  local n="$1"
  # Gate the claim itself, not just the queue. Issues reach a worker by number
  # from several paths -- a manager dispatch, /fix N, a resumed loop -- and a
  # filtered queue does not constrain any of them. Refusing here is what makes
  # the approval actually authoritative. Exit 1: a clean negative, the same
  # code a lost claim race returns, so callers already handle it.
  if [ -n "$REQUIRED_LABEL" ]; then
    local labels
    labels=$(gh issue view "$n" --json labels --jq '.labels[].name' 2>/dev/null) || exit 3
    if ! issue_labels_approved "$labels"; then
      issue_approval_refusal "$n" "$REQUIRED_LABEL"
      exit 1
    fi
  fi
  gh issue edit "$n" --add-label working >/dev/null || exit 3
  # Best-effort: gh has no atomic single-writer label edit. See spec §4.
}

# ── release ────────────────────────────────────────────────────────────────
cmd_release() {
  local n="$1"
  gh issue edit "$n" --remove-label working >/dev/null || exit 3
}

# ── any-claimable ──────────────────────────────────────────────────────────
cmd_any_claimable() {
  local count
  count=$(gh issue list --state open \
    --search "$BLOCKING_SEARCH$(_igh_required_search)" \
    -L 1 --json number --jq 'length') || exit 3
  [ "$count" -gt 0 ]
}

# ── dispatch ───────────────────────────────────────────────────────────────
case "${1:-}" in
  list)          shift; cmd_list "$@" ;;
  get)           shift; cmd_get "$@" ;;
  update)        shift; cmd_update "$@" ;;
  comment)       shift; cmd_comment "$@" ;;
  close)         shift; cmd_close "$@" ;;
  create)        shift; cmd_create "$@" ;;
  claim)         shift; cmd_claim "$@" ;;
  release)       shift; cmd_release "$@" ;;
  any-claimable) cmd_any_claimable ;;
  "")            echo "Usage: issues-gh.sh <verb> [args...]" >&2; exit 2 ;;
  *)             echo "Unknown verb: $1" >&2; exit 2 ;;
esac
