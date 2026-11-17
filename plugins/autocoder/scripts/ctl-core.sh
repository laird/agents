#!/usr/bin/env bash
#
# ctl-core.sh — autocoder-ctl's core verbs: release and status (#243).
#
# Sourced by autocoder-ctl.sh, never run on its own. Each verb reports through
# ctl_ok / ctl_fail / ctl_usage; stdout belongs to the dispatcher.
#
#   release <issue> [--reason <text>]
#       Drop the claim on <issue> through issue_release (every backend), then comment
#       who released it ($AUTOCODER_CTL_ACTOR, else $USER) and why.
#   status [--json] [--session <name>]
#       The swarm's workers from the manifest (.autocoder/swarm/<session>.json in the
#       main worktree): each worker's worktree, pane, branch, issue, and whether it is
#       idle or busy (worker-idle.sh). Output is always JSON; --json is accepted for
#       callers that pass it.

_ctlc_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ctl_verb_release() {
  local issue="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) [ $# -ge 2 ] || { ctl_usage "release: --reason needs a value"; return; }
                reason="$2"; shift 2 ;;
      -*)       ctl_usage "release: unknown option '$1'"; return ;;
      *)        [ -z "$issue" ] || { ctl_usage "release: one issue only"; return; }
                issue="$1"; shift ;;
    esac
  done
  [ -n "$issue" ] || { ctl_usage "usage: release <issue> [--reason <text>]"; return; }

  # shellcheck source=issue-fns.sh
  source "${_ctlc_DIR}/issue-fns.sh" || { ctl_fail "$issue" "cannot load the issue backend"; return; }

  local actor rc
  actor=$(ctl_actor)
  issue_release "$issue"; rc=$?
  if [ "$rc" -ne 0 ]; then
    ctl_fail "$issue" "could not release #${issue}: not claimed, not found, or the backend failed (exit ${rc})"
    return
  fi

  local commented=true
  issue_comment "$issue" --body "🔓 **Claim released** by ${actor} via autocoder-ctl

**Reason**: ${reason:-none given}

The \`working\` lock is gone, so the issue is claimable again." || commented=false

  ctl_ok "$issue" "$(jq -cn --arg issue "$issue" --arg actor "$actor" --arg reason "$reason" --argjson commented "$commented" \
    '{issue: $issue, released: true, commented: $commented, actor: $actor, reason: (if $reason == "" then null else $reason end)}')" --json
}

# One worker's activity: {"activity": "idle|busy|unknown", "reason": "..."}.
_ctlc_activity() {  # <pane> <mux>
  local pane="$1" mux="$2" out state
  if [ -z "$pane" ]; then
    jq -cn '{activity: "unknown", reason: "no pane recorded in the manifest"}'; return
  fi
  case "$mux" in
    tmux|herdr) ;;
    *) jq -cn --arg m "$mux" '{activity: "unknown", reason: ("cannot probe panes under mux " + $m)}'; return ;;
  esac
  out=$("${AUTOCODER_CTL_IDLE_CMD:-${_ctlc_DIR}/worker-idle.sh}" --pane "$pane" --mux "$mux" --json 2>/dev/null)
  state=$(printf '%s' "$out" | jq -r '.state // empty' 2>/dev/null)
  case "$state" in
    IDLE|BUSY) printf '%s' "$out" | jq -c '{activity: (.state | ascii_downcase), reason: (.reason // "")}' ;;
    *)         jq -cn '{activity: "unknown", reason: "worker-idle.sh could not classify the pane"}' ;;
  esac
}

ctl_verb_status() {
  local session=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)    shift ;;
      --session) [ $# -ge 2 ] || { ctl_usage "status: --session needs a value"; return; }
                 session="$2"; shift 2 ;;
      *)         ctl_usage "status: unknown argument '$1'"; return ;;
    esac
  done

  # shellcheck source=issue-source-lib.sh
  source "${_ctlc_DIR}/issue-source-lib.sh"
  # shellcheck source=swarm-manifest-lib.sh
  source "${_ctlc_DIR}/swarm-manifest-lib.sh"
  local root
  root="${AUTOCODER_CTL_PROJECT_ROOT:-$(resolve_main_worktree)}"

  local manifests=() m
  if [ -n "$session" ]; then
    m=$(manifest_path_for_session "$root" "$session")
    [ -f "$m" ] || { ctl_fail "$root" "no swarm manifest for session '$session'"; return; }
    manifests=("$m")
  else
    shopt -s nullglob
    manifests=("$root/$SWARM_STATE_DIR"/*.json)
    shopt -u nullglob
  fi

  # Probe every pane at once: each probe waits out worker-idle's settle window, so
  # probing in turn would cost that window once per worker.
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/autocoder-ctl-status.XXXXXX") || { ctl_fail "$root" "cannot create a temp dir"; return; }
  # Fields are split on \x1f, not tabs: read collapses runs of a whitespace IFS, so an
  # empty field (a worker with no pane) would shift every field after it.
  local i=0 nread=0 mux number worktree pane mstate
  for m in "${manifests[@]}"; do
    jq -e 'type == "object"' "$m" >/dev/null 2>&1 || { echo "autocoder-ctl: skipping unreadable manifest $m" >&2; continue; }
    nread=$((nread + 1))
    mux=$(jq -r '.mux // ""' "$m")
    while IFS=$'\x1f' read -r number worktree pane mstate; do
      i=$((i + 1))
      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$m" "$number" "$worktree" "$pane" "$mstate" > "$tmp/$i.row"
      _ctlc_activity "$pane" "$mux" > "$tmp/$i.act" &
    done < <(jq -r '.workers[]? | [(.number|tostring), (.worktree // ""), (.tmuxTarget // .herdrPane // ""), (.state // "")] | join("\u001f")' "$m")
  done
  wait

  local j branch issue act workers=()
  for ((j = 1; j <= i; j++)); do
    IFS=$'\x1f' read -r m number worktree pane mstate < "$tmp/$j.row"
    branch=$(git -C "$worktree" symbolic-ref --short -q HEAD 2>/dev/null || true)
    issue=$(printf '%s' "$branch" | sed -nE 's#^(feature|enhancement)/issue-([0-9]+)([^0-9].*)?$#\2#p')
    act=$(cat "$tmp/$j.act" 2>/dev/null)
    printf '%s' "$act" | jq -e . >/dev/null 2>&1 || act='{"activity":"unknown","reason":"probe failed"}'
    workers+=("$(jq -cn --arg session "$(basename "$m" .json)" --argjson number "$number" --arg worktree "$worktree" \
      --arg pane "$pane" --arg state "$mstate" --arg branch "$branch" --arg issue "$issue" --argjson act "$act" \
      '{session: $session, number: $number, worktree: $worktree, pane: (if $pane == "" then null else $pane end),
        state: $state, branch: (if $branch == "" then null else $branch end),
        issue: (if $issue == "" then null else ($issue | tonumber) end)} + $act')")
  done
  rm -rf "$tmp"

  local detail
  detail=$(printf '%s\n' "${workers[@]+"${workers[@]}"}" | jq -cs --argjson n "$nread" \
    'map(select(. != null)) | {swarms: $n, workers: .}')
  ctl_ok "$root" "$detail" --json
}
