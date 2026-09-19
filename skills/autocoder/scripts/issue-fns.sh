#!/bin/bash
# issue-fns.sh — thin dispatcher to issues-<backend>.{sh,py}.
# Source this file; do not execute it directly.
# Exposes: issue_list, issue_get, issue_update, issue_comment, issue_close,
#          issue_create, issue_claim, issue_release, issue_any_claimable,
#          issue_deps, issue_block, issue_unblock.
# Defines 12 functions. Convention: any consumer that needs the dependency
# verbs guards against sourcing a stale copy of this file (a vendored
# .agent/scripts tree may predate them) via the compact stale-dispatcher
# guard block — see brainstorm-issue/list-issues/show-issue for the canonical
# block to copy when another command adopts the dep verbs.
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

# Dispatch each verb through the configured backend.
issue_list()          { "$_ifns_BACKEND_BIN" list          "$@"; }
issue_get()           { "$_ifns_BACKEND_BIN" get           "$@"; }
issue_update()        { "$_ifns_BACKEND_BIN" update        "$@"; }
issue_comment()       { "$_ifns_BACKEND_BIN" comment       "$@"; }
issue_close()         { "$_ifns_BACKEND_BIN" close         "$@"; }
issue_create()        { "$_ifns_BACKEND_BIN" create        "$@"; }
issue_claim()         { "$_ifns_BACKEND_BIN" claim         "$@"; }
issue_release()       { "$_ifns_BACKEND_BIN" release       "$@"; }
issue_any_claimable() { "$_ifns_BACKEND_BIN" any-claimable; }
issue_deps()          { "$_ifns_BACKEND_BIN" deps          "$@"; }
issue_block()         { "$_ifns_BACKEND_BIN" block         "$@"; }
issue_unblock()       { "$_ifns_BACKEND_BIN" unblock       "$@"; }
