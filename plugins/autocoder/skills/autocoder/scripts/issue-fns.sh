#!/bin/bash
# issue-fns.sh — thin dispatcher to issues-<backend>.{sh,py}.
# Source this file; do not execute it directly.
# Exposes: issue_list, issue_get, issue_update, issue_comment, issue_close,
#          issue_create, issue_claim, issue_release, issue_any_claimable,
#          and the lifecycle verbs a merge job drives after a claim:
#          issue_handoff (working -> merging), issue_park (-> awaiting-integration),
#          issue_escalate --label L (-> blocked), issue_requeue (-> open),
#          and issue_unmet_dependencies (issue-deps.sh).
#
# One policy lives here rather than in a backend: the claimable queue
# (`issue_list --state open`, the default) leaves out issues whose
# dependencies are not closed yet (issue-deps.sh), so every caller (the
# fix-loop gate, /fix, the manager, the idle sentinel) works issues in an
# order their dependencies allow.
#
# Each function shells out to the configured backend script with the verb
# name and the caller's arguments. No backend logic lives here — backends
# are self-contained in issues-file.py, issues-gh.sh, and any future
# issues-<other>.{sh,py}.

# Bootstrap: ALWAYS resolve the backend through issue-config.sh. Skipping this
# whenever ISSUE_SOURCE happened to be set is what let a stale exported value
# override the repo's .autocoder.json and point the whole workflow at the wrong
# backend. issue-config.sh decides precedence (config wins, env is fallback).
_ifns_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=issue-config.sh
source "${_ifns_DIR}/issue-config.sh"

case "${ISSUE_SOURCE:-}" in
  github) _ifns_BACKEND_SCRIPT="issues-gh.sh"   ;;
  file)   _ifns_BACKEND_SCRIPT="issues-file.py" ;;
  jira)   _ifns_BACKEND_SCRIPT="issues-jira.sh" ;;
  ado)    _ifns_BACKEND_SCRIPT="issues-ado.sh"  ;;
  *)      _ifns_BACKEND_SCRIPT="${ISSUE_BACKEND:-}" ;;
esac
_ifns_BACKEND_BIN="${_ifns_DIR}/${_ifns_BACKEND_SCRIPT}"
# Dependency policy. A scripts dir without issue-deps.sh (an older package, a
# partial copy) keeps working, just without the filter.
if [ -f "${_ifns_DIR}/issue-deps.sh" ]; then
  # shellcheck source=issue-deps.sh
  source "${_ifns_DIR}/issue-deps.sh"
else
  _ideps_filter() { cat; }
  issue_unmet_dependencies() { return 0; }
fi

# The claimable queue is `list` with no --state, or --state open.
_ifns_is_open_list() {
  local prev="" a
  for a in "$@"; do
    case "$a" in --state=*) [ "${a#--state=}" = "open" ]; return ;; esac
    [ "$prev" = "--state" ] && { [ "$a" = "open" ]; return; }
    prev="$a"
  done
  return 0
}

# Dispatch each verb through the configured backend.
issue_list() {
  if _ifns_is_open_list "$@"; then
    local out
    out=$("$_ifns_BACKEND_BIN" list "$@") || return $?
    printf '%s' "$out" | _ideps_filter
  else
    "$_ifns_BACKEND_BIN" list "$@"
  fi
}
issue_get()           { "$_ifns_BACKEND_BIN" get           "$@"; }
issue_update()        { "$_ifns_BACKEND_BIN" update        "$@"; }
issue_comment()       { "$_ifns_BACKEND_BIN" comment       "$@"; }
issue_close()         { "$_ifns_BACKEND_BIN" close         "$@"; }
issue_create()        { "$_ifns_BACKEND_BIN" create        "$@"; }
issue_claim()         { "$_ifns_BACKEND_BIN" claim         "$@"; }
issue_release()       { "$_ifns_BACKEND_BIN" release       "$@"; }
# The backend answers cheaply when nothing is open; when something is, check
# that at least one open issue is free of unmet dependencies.
issue_any_claimable() {
  "$_ifns_BACKEND_BIN" any-claimable || return $?
  local ready
  ready=$(issue_list --state open 2>/dev/null) || return 0
  [ "$(printf '%s' "$ready" | jq 'length' 2>/dev/null || echo 1)" -gt 0 ]
}
issue_handoff()       { "$_ifns_BACKEND_BIN" handoff       "$@"; }
issue_park()          { "$_ifns_BACKEND_BIN" park          "$@"; }
issue_escalate()      { "$_ifns_BACKEND_BIN" escalate      "$@"; }
issue_requeue()       { "$_ifns_BACKEND_BIN" requeue       "$@"; }
