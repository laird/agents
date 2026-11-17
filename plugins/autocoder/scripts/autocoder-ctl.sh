#!/usr/bin/env bash
#
# autocoder-ctl.sh — one command surface for UIs and scripts (#243, sub-task of #192).
#
# A UI that drives a swarm should not paste text into panes or call a dozen scripts
# with a dozen output formats. It calls this one entry point, and every verb answers
# in the same shape.
#
# Usage: autocoder-ctl.sh <verb> [args]
#        autocoder-ctl.sh help
#
# Result contract (docs/autocoder-ctl.md): every invocation prints exactly one JSON
# object on stdout, and nothing else:
#
#   {"ok": true|false, "action": "<verb>", "target": "<issue|worktree|repo>"|null,
#    "detail": "<text>" | {...}}
#
# Exit: 0 ok; 1 the action failed; 2 usage (unknown verb, missing or bad argument);
# 3 the verb's module is not installed yet. Diagnostics go to stderr.
#
# Verbs live in per-group modules (ctl-<group>.sh next to this file), sourced only
# for the verb being run. A module defines ctl_verb_<verb> (dashes become
# underscores) and reports through ctl_ok / ctl_fail / ctl_usage; it never prints
# to stdout itself. Adding a group is a new file, not an edit here.
#
# Actor: release and the other verbs that act on the tracker name who acted, from
# $AUTOCODER_CTL_ACTOR, else $USER.

set -uo pipefail

_ctl_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Verb → module. Every verb of #192 is listed now, so a UI can tell "not installed
# yet" (exit 3) from "no such verb" (exit 2). The modules by name, so the packager's
# reference scan (scripts/package-plugin-scripts.py) ships them with this script:
# ctl-core.sh, ctl-workers.sh, ctl-issues.sh, ctl-swarm.sh.
ctl_module_for() {
  case "$1" in
    release|status)                                  echo core ;;
    nudge|stop|restart)                              echo workers ;;
    approve|reject|request-changes|file)             echo issues ;;
    start|add-worker|remove-worker|stop-swarm)       echo swarm ;;
    *) return 1 ;;
  esac
}
CTL_VERBS="release status nudge stop restart approve reject request-changes file start add-worker remove-worker stop-swarm"

# ── Result ────────────────────────────────────────────────────────────────────
# A verb sets the result; the dispatcher prints it once, through ctl_emit, which then
# records it (ctl_record, #247). Anything that should happen once per action goes there.
CTL_ACTION="" CTL_SET=false CTL_OK=false CTL_RC=1 CTL_TARGET="" CTL_DETAIL="" CTL_DETAIL_JSON=false

_ctl_set() {  # _ctl_set <ok> <rc> <target> <detail> [--json]
  CTL_SET=true CTL_OK="$1" CTL_RC="$2" CTL_TARGET="$3" CTL_DETAIL="$4" CTL_DETAIL_JSON=false
  [ "${5:-}" = --json ] && CTL_DETAIL_JSON=true
  return 0
}
ctl_ok()    { _ctl_set true 0 "$@"; }       # ctl_ok <target> <detail> [--json]
ctl_fail()  { _ctl_set false 1 "$@"; }      # ctl_fail <target> <detail> [--json]
ctl_usage() { _ctl_set false 2 "" "$1"; }   # ctl_usage <message>

ctl_actor() { printf '%s\n' "${AUTOCODER_CTL_ACTOR:-${USER:-unknown}}"; }

ctl_emit() {
  local detail_arg=(--arg detail "$CTL_DETAIL")
  if $CTL_DETAIL_JSON; then
    if printf '%s' "$CTL_DETAIL" | jq -e . >/dev/null 2>&1; then
      detail_arg=(--argjson detail "$CTL_DETAIL")
    else
      CTL_OK=false CTL_RC=1 detail_arg=(--arg detail "internal: verb produced invalid JSON detail")
    fi
  fi
  jq -cn --argjson ok "$CTL_OK" --arg action "$CTL_ACTION" --arg target "$CTL_TARGET" "${detail_arg[@]}" \
    '{ok: $ok, action: $action, target: (if $target == "" then null else $target end), detail: $detail}' >&3
  ctl_record
  return "$CTL_RC"
}

# ── Event per action (#247) ───────────────────────────────────────────────────
# After the result is out, append one `ctl` event to the lifecycle log (#190,
# issue-events-lib.sh): action, target, ok, exit, actor and the first 200 characters
# of the detail. `issue` is the target when the target is an issue number.
#
# Best effort: it runs in a subshell with every stream closed, so a missing library,
# an unwritable log or a crash here changes neither the result nor the exit code.
#
# Read-only verbs are not recorded: they change nothing, and a UI polls `status`
# every few seconds, which would bury the lifecycle log in lines nobody reads.
CTL_UNRECORDED="help status"

ctl_record() {
  case " $CTL_UNRECORDED " in *" $CTL_ACTION "*) return 0 ;; esac
  (
    lib="${_ctl_DIR}/issue-events-lib.sh"
    [ -f "$lib" ] || exit 0
    # shellcheck source=issue-events-lib.sh
    source "$lib"
    issue=-
    [[ "$CTL_TARGET" =~ ^[0-9]+$ ]] && issue="$CTL_TARGET"
    summary="$CTL_DETAIL"
    if $CTL_DETAIL_JSON; then summary=$(printf '%s' "$CTL_DETAIL" | jq -c . 2>/dev/null) || summary="$CTL_DETAIL"; fi
    issue_event ctl "$issue" action="$CTL_ACTION" target="$CTL_TARGET" ok="$CTL_OK" \
      exit="$CTL_RC" actor="$(ctl_actor)" summary="${summary:0:200}"
  ) </dev/null >/dev/null 2>&1 || true
  return 0
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
ctl_main() {
  # Keep stdout for the one result: anything a verb or a library it sources prints
  # goes to stderr instead.
  exec 3>&1 1>&2
  command -v jq >/dev/null 2>&1 || {
    # No jq to quote the verb with, so the action is left null rather than echoed raw.
    printf '{"ok":false,"action":null,"target":null,"detail":"jq is required"}\n' >&3
    exit 1
  }

  CTL_ACTION="${1:-}"
  case "$CTL_ACTION" in
    ""|-h|--help|help)
      CTL_ACTION=help
      if [ -z "${1:-}" ]; then ctl_usage "usage: autocoder-ctl.sh <verb> [args]; verbs: $CTL_VERBS"
      else ctl_ok "" "{\"verbs\": $(printf '%s\n' $CTL_VERBS | jq -R . | jq -cs .)}" --json; fi
      ctl_emit; exit $? ;;
  esac
  shift

  local group module fn
  if ! group=$(ctl_module_for "$CTL_ACTION"); then
    ctl_usage "unknown verb '$CTL_ACTION'; verbs: $CTL_VERBS"
    ctl_emit; exit $?
  fi
  module="${_ctl_DIR}/ctl-${group}.sh"
  fn="ctl_verb_${CTL_ACTION//-/_}"
  if [ -f "$module" ]; then
    # shellcheck source=/dev/null
    source "$module"
  fi
  if ! declare -F "$fn" >/dev/null; then
    _ctl_set false 3 "" "not implemented"
    ctl_emit; exit $?
  fi

  "$fn" "$@"
  $CTL_SET || _ctl_set false 1 "" "internal: verb '$CTL_ACTION' reported no result"
  ctl_emit
  exit $?
}

# Sourced (tests, other scripts): define the functions only.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ctl_main "$@"
fi
