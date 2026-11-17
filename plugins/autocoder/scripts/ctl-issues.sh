#!/usr/bin/env bash
#
# ctl-issues.sh — autocoder-ctl's issue decisions: approve, reject, request-changes
# and file (#245, sub-task of #192).
#
# Sourced by autocoder-ctl.sh, never run on its own. Each verb reports through
# ctl_ok / ctl_fail / ctl_usage; stdout belongs to the dispatcher. Everything goes
# through the configured issue backend (issue-fns.sh), so a UI gets the same verbs
# on GitHub, Jira, Azure DevOps and the local file store.
#
#   approve <issue>
#       Remove `proposal` from an open proposal, then comment who approved it. The
#       fix loop implements it on a later tick.
#   reject <issue> [reason]
#       Close the issue with a comment naming who rejected it and why.
#   request-changes <issue> <text>
#       Comment the requested changes, naming who asked. `proposal` stays, so
#       /refine-proposal picks the issue up.
#   file --title <t> [--body <b>] [--label <l>]...
#       Create an issue. The result's target is the new issue's number.
#
# The actor is $AUTOCODER_CTL_ACTOR, else $USER (ctl_actor).

_ctli_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_ctli_load() {
  # shellcheck source=issue-fns.sh
  source "${_ctli_DIR}/issue-fns.sh"
}

# _ctli_issue_arg <verb> <value>: a positive issue number, else a usage error.
_ctli_issue_arg() {
  case "$2" in
    ''|*[!0-9]*|0*) ctl_usage "$1: '$2' is not an issue number"; return 1 ;;
  esac
}

# _ctli_fetch <issue>: sets _ctli_STATE (open|closed) and _ctli_LABELS (one per
# line), or reports a failure and returns 1.
_ctli_fetch() {
  local json
  if ! json=$(issue_get "$1" 2>/dev/null) || ! printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    ctl_fail "$1" "issue #$1 not found, or the backend failed"
    return 1
  fi
  _ctli_STATE=$(printf '%s' "$json" | jq -r '(.state // "open") | ascii_downcase')
  _ctli_LABELS=$(printf '%s' "$json" | jq -r '(.labels // [])[] | (.name? // .)')
}

_ctli_has_label() { printf '%s\n' "$_ctli_LABELS" | grep -qFx "$1"; }

# _ctli_open_issue <verb> <issue>: load the backend and require an open issue.
_ctli_open_issue() {
  _ctli_load || { ctl_fail "$2" "cannot load the issue backend"; return 1; }
  _ctli_fetch "$2" || return 1
  if [ "$_ctli_STATE" != open ]; then
    ctl_fail "$2" "$1: issue #$2 is closed"
    return 1
  fi
}

ctl_verb_approve() {
  [ $# -eq 1 ] || { ctl_usage "usage: approve <issue>"; return; }
  local issue="$1"
  _ctli_issue_arg approve "$issue" || return
  _ctli_open_issue approve "$issue" || return
  if ! _ctli_has_label proposal; then
    ctl_fail "$issue" "approve: issue #$issue is not a proposal (no 'proposal' label)"
    return
  fi

  local actor rc
  actor=$(ctl_actor)
  issue_update "$issue" --remove-label proposal; rc=$?
  if [ "$rc" -ne 0 ]; then
    ctl_fail "$issue" "could not remove 'proposal' from #${issue} (backend exit ${rc})"
    return
  fi

  local commented=true
  issue_comment "$issue" --body "✅ **Proposal approved** by ${actor} via autocoder-ctl

The \`proposal\` label is removed, so the fix loop will implement this issue." || commented=false

  ctl_ok "$issue" "$(jq -cn --arg issue "$issue" --arg actor "$actor" --argjson commented "$commented" \
    '{issue: $issue, approved: true, commented: $commented, actor: $actor}')" --json
}

ctl_verb_reject() {
  [ $# -ge 1 ] && [ $# -le 2 ] || { ctl_usage "usage: reject <issue> [reason]"; return; }
  local issue="$1" reason="${2:-}"
  _ctli_issue_arg reject "$issue" || return
  _ctli_open_issue reject "$issue" || return

  local actor rc
  actor=$(ctl_actor)
  # The comment travels with the close, so a rejection never lands without its reason.
  issue_close "$issue" --comment "❌ **Rejected** by ${actor} via autocoder-ctl

**Reason**: ${reason:-none given}"; rc=$?
  if [ "$rc" -ne 0 ]; then
    ctl_fail "$issue" "could not close #${issue} (backend exit ${rc})"
    return
  fi

  ctl_ok "$issue" "$(jq -cn --arg issue "$issue" --arg actor "$actor" --arg reason "$reason" \
    '{issue: $issue, closed: true, actor: $actor, reason: (if $reason == "" then null else $reason end)}')" --json
}

ctl_verb_request_changes() {
  [ $# -eq 2 ] || { ctl_usage "usage: request-changes <issue> <text>"; return; }
  local issue="$1" text="$2"
  _ctli_issue_arg request-changes "$issue" || return
  [ -n "${text//[[:space:]]/}" ] || { ctl_usage "request-changes: the requested changes are empty"; return; }
  _ctli_open_issue request-changes "$issue" || return

  local actor rc proposal=false
  actor=$(ctl_actor)
  _ctli_has_label proposal && proposal=true
  issue_comment "$issue" --body "✏️ **Changes requested** by ${actor} via autocoder-ctl

${text}

Run \`/refine-proposal ${issue}\` to revise the proposal with this feedback."; rc=$?
  if [ "$rc" -ne 0 ]; then
    ctl_fail "$issue" "could not comment on #${issue} (backend exit ${rc})"
    return
  fi

  ctl_ok "$issue" "$(jq -cn --arg issue "$issue" --arg actor "$actor" --argjson proposal "$proposal" \
    '{issue: $issue, commented: true, actor: $actor, proposal: $proposal}')" --json
}

ctl_verb_file() {
  local title="" body="" have_title=false labels=() label_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --title|--body|--label)
        [ $# -ge 2 ] || { ctl_usage "file: $1 needs a value"; return; }
        case "$1" in
          --title) title="$2"; have_title=true ;;
          --body)  body="$2" ;;
          --label) [ -n "$2" ] || { ctl_usage "file: --label needs a value"; return; }
                   labels+=("$2"); label_args+=(--label "$2") ;;
        esac
        shift 2 ;;
      *) ctl_usage "file: unknown argument '$1'"; return ;;
    esac
  done
  if ! $have_title || [ -z "${title//[[:space:]]/}" ]; then
    ctl_usage "usage: file --title <title> [--body <body>] [--label <label>]..."
    return
  fi

  _ctli_load || { ctl_fail "" "cannot load the issue backend"; return; }
  local actor out number
  actor=$(ctl_actor)
  body="${body:+${body}

}---
Filed by ${actor} via autocoder-ctl"
  if ! out=$(issue_create --title "$title" --body "$body" "${label_args[@]+"${label_args[@]}"}"); then
    ctl_fail "" "could not create the issue (the backend failed; is every label defined?)"
    return
  fi
  number=$(printf '%s' "$out" | jq -r '.number // empty' 2>/dev/null)
  case "$number" in
    ''|*[!0-9]*) ctl_fail "" "the backend created an issue but reported no number: ${out}"; return ;;
  esac

  ctl_ok "$number" "$(jq -cn --argjson number "$number" --arg title "$title" --arg actor "$actor" \
    --args '{number: $number, title: $title, labels: $ARGS.positional, actor: $actor}' "${labels[@]+"${labels[@]}"}")" --json
}
