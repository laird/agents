#!/bin/bash
# issue-fns.sh — shared shell function layer for issue backend dispatch.
# Source this file; do not execute it directly.
# Provides: issue_list, issue_get, issue_update, issue_comment, issue_close, issue_create

# Bootstrap: ALWAYS resolve the backend through issue-config.sh. Skipping this
# whenever ISSUE_SOURCE happened to be set is what let a stale exported value
# override the repo's .autocoder.json. issue-config.sh decides precedence.
_ifns_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=issue-config.sh
source "${_ifns_DIR}/issue-config.sh"

_ifns_PY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/issues-file.py"
_ifns_JIRA="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/issues-jira.sh"
_ifns_ADO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/issues-ado.sh"

# ── Internal: dispatch to file backend ────────────────────────────────────
_ifns_file() {
  python3 "$_ifns_PY" "$@"
}

# ── Internal: dispatch to Jira backend (self-contained 9-verb script) ──────
_ifns_jira() {
  "$_ifns_JIRA" "$@"
}

# ── Internal: dispatch to Azure DevOps backend (self-contained 9-verb) ─────
_ifns_ado() {
  "$_ifns_ADO" "$@"
}

# ── Internal: GitHub backend implementations ──────────────────────────────
_ifns_gh_list() {
  local args=() priority=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority) priority="$2"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [ -n "$priority" ] && args+=(--label "$priority")
  gh issue list "${args[@]}" --json number,title,body,labels,state
}

_ifns_gh_update() {
  local number="$1"; shift
  local add_labels=() remove_labels=() status=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --add-label)    add_labels+=("$2"); shift 2 ;;
      --remove-label) remove_labels+=("$2"); shift 2 ;;
      --status)       status="$2"; shift 2 ;;
      --assignee)     shift 2 ;;
      *)              shift ;;
    esac
  done
  if [ -n "$status" ]; then
    case "$status" in
      closed)  gh issue close "$number" ;;
      open)    gh issue reopen "$number" ;;
      working) gh issue edit "$number" --add-label "working" ;;
    esac
  fi
  local edit_args=()
  for l in "${add_labels[@]}";    do edit_args+=(--add-label    "$l"); done
  for l in "${remove_labels[@]}"; do edit_args+=(--remove-label "$l"); done
  [ "${#edit_args[@]}" -gt 0 ] && gh issue edit "$number" "${edit_args[@]}"
}

_ifns_gh_close() {
  local number="$1"; shift
  local comment=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --comment) comment="$2"; shift 2 ;; *) shift ;; esac
  done
  if [ -n "$comment" ]; then
    gh issue close "$number" --comment "$comment"
  else
    gh issue close "$number"
  fi
}

_ifns_gh_create() {
  local title="" body="" labels=() priority=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)    title="$2"; shift 2 ;;
      --body)     body="$2"; shift 2 ;;
      --label)    labels+=("$2"); shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      *)          shift ;;
    esac
  done
  [ -n "$priority" ] && labels+=("$priority")
  local create_args=(--title "$title" --body "$body")
  for l in "${labels[@]}"; do create_args+=(--label "$l"); done
  # gh issue create outputs the URL (e.g. https://github.com/owner/repo/issues/42)
  local issue_url
  issue_url=$(gh issue create "${create_args[@]}")
  local number
  number=$(echo "$issue_url" | grep -oE '[0-9]+$')
  echo "{\"number\": $number}"
}

# ── Public functions ──────────────────────────────────────────────────────

issue_list() {
  local args=() priority=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority) priority="$2"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [ -n "$priority" ] && args+=(--label "$priority")
  case "$ISSUE_SOURCE" in
    github) _ifns_gh_list "${args[@]}" ;;
    file)   _ifns_file list "${args[@]}" ;;
    jira)   _ifns_jira list "${args[@]}" ;;
    ado)    _ifns_ado list "${args[@]}" ;;
    *)      "$ISSUE_BACKEND" list "${args[@]}" ;;
  esac
}

issue_get() {
  case "$ISSUE_SOURCE" in
    github) gh issue view "$1" --json number,title,body,labels,state,comments ;;
    file)   _ifns_file get "$@" ;;
    jira)   _ifns_jira get "$@" ;;
    ado)    _ifns_ado get "$@" ;;
    *)      "$ISSUE_BACKEND" get "$@" ;;
  esac
}

issue_update() {
  case "$ISSUE_SOURCE" in
    github) _ifns_gh_update "$@" ;;
    file)   _ifns_file update "$@" ;;
    jira)   _ifns_jira update "$@" ;;
    ado)    _ifns_ado update "$@" ;;
    *)      "$ISSUE_BACKEND" update "$@" ;;
  esac
}

issue_comment() {
  case "$ISSUE_SOURCE" in
    github)
      local number="$1"; shift
      local body=""
      while [[ $# -gt 0 ]]; do
        case "$1" in --body) body="$2"; shift 2 ;; *) shift ;; esac
      done
      gh issue comment "$number" --body "$body"
      ;;
    file) _ifns_file comment "$@" ;;
    jira) _ifns_jira comment "$@" ;;
    ado)  _ifns_ado comment "$@" ;;
    *)    "$ISSUE_BACKEND" comment "$@" ;;
  esac
}

issue_close() {
  case "$ISSUE_SOURCE" in
    github) _ifns_gh_close "$@" ;;
    file)   _ifns_file close "$@" ;;
    jira)   _ifns_jira close "$@" ;;
    ado)    _ifns_ado close "$@" ;;
    *)      "$ISSUE_BACKEND" close "$@" ;;
  esac
}

issue_create() {
  local args=() priority=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority) priority="$2"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [ -n "$priority" ] && args+=(--label "$priority")
  case "$ISSUE_SOURCE" in
    github) _ifns_gh_create "${args[@]}" ;;
    file)   _ifns_file create "${args[@]}" ;;
    jira)   _ifns_jira create "${args[@]}" ;;
    ado)    _ifns_ado create "${args[@]}" ;;
    *)      "$ISSUE_BACKEND" create "${args[@]}" ;;
  esac
}
