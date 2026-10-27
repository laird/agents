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
#   <backend> handoff <number>
#   <backend> park <number> [--comment "..."]
#   <backend> escalate <number> --label <blocking-label> [--comment "..."]
#   <backend> requeue <number> [--comment "..."]
#
# The last four are the lifecycle a detached merge job drives after a worker's
# claim (see issues-file.py's docstring). On GitHub they are label edits: the
# label that keeps the issue out of the claimable queue is added BEFORE the one it
# replaces is removed, so no query in between sees a claimable issue. Removing a
# label the issue does not carry is tolerated, so every verb converges.
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

# Blocking/blocked label sets, as JSON arrays for jq (see cmd_list below).
# `merging` (a detached merge job owns the issue) and `awaiting-integration` (landed,
# waiting for a green tip or a human merge) are excluded from the claimable queue but
# deliberately absent from BLOCKED_LABELS_JSON: neither is a human-decision gate, so
# /review-blocked must not surface them.
BLOCKING_LABELS_JSON='["working","needs-design","needs-clarification","needs-feedback","needs-approval","too-complex","future","proposal","awaiting-integration","merging"]'
BLOCKED_LABELS_JSON='["needs-design","needs-clarification","needs-feedback","needs-approval","too-complex","future","proposal"]'

# `open`/`working`/`blocked` used to be `gh issue list --search '...'`, which hits
# GitHub's index-backed /search/issues endpoint. That index lags real-time label
# writes (seconds, more under concurrent-swarm label churn), so the gate repeatedly
# handed out issues that a fresh direct read showed already `working`. The predicate
# is pure label boolean logic, so fetch open issues directly from the REST list
# endpoint (no index in between) and filter labels client-side with jq.
# `closed`/`all` below were already direct and are unchanged. Reserve `--search`
# for text queries the REST list endpoint cannot express.
IGH_LIST_FETCH_LIMIT="${IGH_LIST_FETCH_LIMIT:-1000}"

_igh_fetch_open_raw() {
  gh issue list --state open --json number,title,body,labels,state --limit "$IGH_LIST_FETCH_LIMIT"
}

# $1: raw JSON array from _igh_fetch_open_raw. $2: jq boolean expression over
# one issue `.`, with $blocking/$blocked/$req bound.
_igh_filter_open_raw() {
  local raw="$1" select_expr="$2"
  printf '%s' "$raw" | jq --argjson blocking "$BLOCKING_LABELS_JSON" --argjson blocked "$BLOCKED_LABELS_JSON" \
    --arg req "$REQUIRED_LABEL" "[.[] | select($select_expr)]"
}

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
  case "$state" in
    # Only the claimable queue is gated. `working` and `blocked` deliberately
    # are not: an issue claimed before the gate was configured must stay
    # visible to the manager, and hiding in-flight work would read as the
    # worker having vanished.
    open|working|blocked)
      local raw filtered select_expr
      raw=$(_igh_fetch_open_raw) || exit 3
      case "$state" in
        open)
          # No overlap with $blocking, and (when the approval gate is on) $req present.
          select_expr='(([.labels[].name] // []) as $names | ($blocking - $names) == $blocking)'
          [ -n "$REQUIRED_LABEL" ] && select_expr="($select_expr) and ((.labels | map(.name) | index(\$req)) != null)"
          ;;
        working)
          select_expr='((.labels | map(.name) | index("working")) != null)'
          ;;
        blocked)
          # At least one label from $blocked present.
          select_expr='(([.labels[].name] // []) as $names | ($blocked - $names) != $blocked)'
          ;;
      esac
      filtered=$(_igh_filter_open_raw "$raw" "$select_expr") || exit 3
      [ -n "$label" ] && filtered=$(printf '%s' "$filtered" | jq --arg lbl "$label" '[.[] | select(.labels | map(.name) | index($lbl))]')
      [ -n "$limit" ] && filtered=$(printf '%s' "$filtered" | jq --argjson n "$limit" '.[0:$n]')
      printf '%s\n' "$filtered"
      return
      ;;
    closed)  args+=(--state closed) ;;
    all)     args+=(--state all) ;;
    *)       echo "Unknown state: $state" >&2; exit 2 ;;
  esac
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

# ── lifecycle verbs ────────────────────────────────────────────────────────
_igh_add_label()  { gh issue edit "$1" --add-label "$2" >/dev/null || exit 3; }
# gh refuses to remove a label the repository has never defined; an issue that
# simply lacks the label is a no-op. Either way the end state is "label absent".
_igh_drop_labels() { local n="$1"; shift; local l; for l in "$@"; do gh issue edit "$n" --remove-label "$l" >/dev/null 2>&1 || true; done; }
_igh_lifecycle_args() {  # sets LC_LABEL / LC_COMMENT from the verb's options
  LC_LABEL=""; LC_COMMENT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label)   LC_LABEL="$2";   shift 2 ;;
      --comment) LC_COMMENT="$2"; shift 2 ;;
      *)         shift ;;
    esac
  done
}

cmd_handoff() {
  local n="$1"
  _igh_add_label "$n" merging
  _igh_drop_labels "$n" working
}

cmd_park() {
  local n="$1"; shift
  _igh_lifecycle_args "$@"
  _igh_add_label "$n" awaiting-integration
  _igh_drop_labels "$n" working merging
  [ -n "$LC_COMMENT" ] && cmd_comment "$n" --body "$LC_COMMENT"
  return 0
}

cmd_escalate() {
  local n="$1"; shift
  _igh_lifecycle_args "$@"
  [ -n "$LC_LABEL" ] || { echo "escalate: --label <blocking-label> is required" >&2; exit 2; }
  _igh_add_label "$n" "$LC_LABEL"
  _igh_drop_labels "$n" working merging awaiting-integration
  [ -n "$LC_COMMENT" ] && cmd_comment "$n" --body "$LC_COMMENT"
  return 0
}

cmd_requeue() {
  local n="$1"; shift
  _igh_lifecycle_args "$@"
  _igh_drop_labels "$n" working merging awaiting-integration
  [ -n "$LC_COMMENT" ] && cmd_comment "$n" --body "$LC_COMMENT"
  return 0
}

# ── any-claimable ──────────────────────────────────────────────────────────
cmd_any_claimable() {
  local open count
  open=$(cmd_list --state open) || exit 3
  count=$(printf '%s' "$open" | jq 'length')
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
  handoff)       shift; cmd_handoff "$@" ;;
  park)          shift; cmd_park "$@" ;;
  escalate)      shift; cmd_escalate "$@" ;;
  requeue)       shift; cmd_requeue "$@" ;;
  any-claimable) cmd_any_claimable ;;
  "")            echo "Usage: issues-gh.sh <verb> [args...]" >&2; exit 2 ;;
  *)             echo "Unknown verb: $1" >&2; exit 2 ;;
esac
