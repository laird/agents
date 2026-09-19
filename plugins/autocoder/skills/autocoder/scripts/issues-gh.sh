#!/bin/bash
# issues-gh.sh — GitHub backend implementing the uniform 12-verb CLI.
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
#   <backend> deps <number>
#   <backend> block <number> --on <number>
#   <backend> unblock <number> --on <number>
#
# Exit codes:
#   0 — success / work exists
#   1 — clean negative (no claimable, race lost, issue not found, unblock of
#       an absent edge, block refused for a self-edge or two-node cycle,
#       claim refused on an open blocker)
#   2 — usage error
#   3 — backend error (gh failure, auth failure, parse error — including any
#       failure while resolving blockers during claim/any-claimable: a broken
#       backend must never read as "no work")
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
#   - dependencies use GitHub's native issue-dependency endpoints
#     (issues/<n>/dependencies/blocked_by and .../blocking); on GHES without
#     that API (a dependencies 404 for an issue proven to exist) edges fall
#     back to `blocked-by-<m>` labels on the blocked issue.

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
  [ -n "$limit" ] && args+=(--limit "$limit")
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
  # Blocker gate (KTD8): after the approval gate, before the label edit.
  # Resolve blockers from the issue's own dependency read; any resolution
  # failure is exit 3 — an issue must never look unclaimable because a deps
  # read failed (KTD5). Claim-time-only resolution: a blocker that reopens
  # after the claim is an accepted race, same as the file backend.
  local vrc=0
  _igh_view "$n" labels || vrc=$?
  case "$vrc" in 1) exit 1 ;; 3) exit 3 ;; esac
  _igh_blockers_of "$n" "$_IGH_VIEW_JSON" || exit 3
  local m state open_blockers=""
  for m in $_IGH_BLOCKERS; do
    state=$(_igh_blocker_state "$m") || exit 3
    if [ "$state" = "open" ]; then open_blockers="$open_blockers #$m"; fi
  done
  if [ -n "$open_blockers" ]; then
    echo "Issue #$n is blocked by open issue(s)${open_blockers}." \
         "Close them first, or remove the edge with \`unblock $n --on N\`." >&2
    exit 1
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
  # Blocker-aware probe (KTD8): no GitHub search qualifier expresses "all
  # blockers closed", so enumerate candidates from the existing claimable
  # search — bounded at the first 50 — and resolve blockers per candidate.
  # Exit 0 on the first unblocked candidate, 1 when none within the bound is
  # unblocked, 3 on ANY resolution failure: a deps fetch error must never
  # read as "no work" (KTD5).
  local candidates
  candidates=$(gh issue list --state open \
    --search "$BLOCKING_SEARCH$(_igh_required_search)" \
    -L 50 --json number --jq '.[].number') || exit 3
  [ -n "$candidates" ] || exit 1
  local n m state vrc blocked
  for n in $candidates; do
    vrc=0
    _igh_view "$n" labels || vrc=$?
    case "$vrc" in
      1) continue ;;   # closed/deleted since the search snapshot: skip
      3) exit 3 ;;
    esac
    _igh_blockers_of "$n" "$_IGH_VIEW_JSON" || exit 3
    blocked=0
    for m in $_IGH_BLOCKERS; do
      state=$(_igh_blocker_state "$m") || exit 3
      if [ "$state" = "open" ]; then blocked=1; break; fi
    done
    if [ "$blocked" -eq 0 ]; then exit 0; fi
  done
  exit 1
}

# ── dependency verbs (deps / block / unblock) ──────────────────────────────
#
# Storage: GitHub's native issue-dependency REST endpoints —
#   blockedBy: GET    repos/{owner}/{repo}/issues/<n>/dependencies/blocked_by
#   add edge:  POST   .../dependencies/blocked_by  (blocker's issue_id in body)
#   remove:    DELETE .../dependencies/blocked_by/<issue_id>
#   blocks:    GET    .../dependencies/blocking
#
# All four endpoints verified live against api.github.com on 2026-09-19
# (laird/agents scratch issues #155/#156): blocked_by GET/POST/DELETE and
# blocking GET all behave as implemented, including the full block ->
# refused-claim -> unblock lifecycle. This closes the plan's third
# implementation-time verification item.
#
# GHES fallback: older GitHub Enterprise Server has no dependencies API and
# answers 404 — but a 404 from those endpoints ALSO means "issue not found".
# Callers therefore always confirm the issue exists first (gh issue view,
# needed for blocker state anyway) and only then read a dependencies 404/410
# as feature-unavailable. In that mode an edge is a `blocked-by-<m>` label on
# the blocked issue, and the reverse (blocks) direction is a label search.
# The determination is cached for the rest of the invocation
# (_igh_deps_mode), so native and label writes can never interleave.

_IGH_ERRF="$(mktemp)"
trap 'rm -f "$_IGH_ERRF"' EXIT
_igh_deps_mode=""      # "" = undetermined, "native", or "labels" (GHES)
_IGH_VIEW_JSON=""      # last successful `gh issue view --json` payload
_IGH_BLOCKERS=""       # newline-separated blocker numbers (from _igh_blockers_of)
_IGH_BB_PAIRS=""       # native mode only: "number issue_id" lines
_IGH_DEP_OUT=""        # last successful _igh_dep_get output

# _igh_view <n> <fields> — wrap `gh issue view`, splitting "issue not found"
# (return 1) from every other gh failure (return 3, stderr passed through).
# Sets _IGH_VIEW_JSON on success. Call directly, not in $(...).
_igh_view() {
  local n="$1" fields="$2" rc=0
  _IGH_VIEW_JSON=$(gh issue view "$n" --json "$fields" 2>"$_IGH_ERRF") || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if grep -qiE 'could not resolve|not found' "$_IGH_ERRF"; then return 1; fi
  cat "$_IGH_ERRF" >&2
  return 3
}

# _igh_dep_get <path-under-issues/> <jq> — GET a dependencies endpoint.
# Returns: 0 ok (_IGH_DEP_OUT set), 4 on a clean HTTP 404/410 — only
# meaningful when the caller has already confirmed the issue exists —
# 3 on any other failure (stderr passed through).
_igh_dep_get() {
  local path="$1" jq="$2" rc=0
  _IGH_DEP_OUT=$(gh api "repos/{owner}/{repo}/issues/$path" --jq "$jq" \
    2>"$_IGH_ERRF") || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if grep -qE 'HTTP 404|HTTP 410' "$_IGH_ERRF"; then return 4; fi
  cat "$_IGH_ERRF" >&2
  return 3
}

# _igh_blockers_of <n> <labels-json> — resolve <n>'s blockedBy edges into
# _IGH_BLOCKERS (numbers, one per line; _IGH_BB_PAIRS carries the native
# "number issue_id" pairs). <labels-json> is <n>'s own `--json labels`
# payload, consulted only on the label fallback. The caller MUST have
# confirmed <n> exists: that is what lets a dependencies 404 be read as
# feature-unavailable (GHES) instead of issue-not-found. Returns 3 on
# backend failure. Call directly, never in $(...) — it caches
# _igh_deps_mode for the rest of the invocation.
_igh_blockers_of() {
  local n="$1" labels_json="$2" rc=0
  _IGH_BLOCKERS=""; _IGH_BB_PAIRS=""
  if [ "$_igh_deps_mode" != "labels" ]; then
    _igh_dep_get "$n/dependencies/blocked_by" '.[] | "\(.number) \(.id)"' || rc=$?
    case "$rc" in
      0) _igh_deps_mode="native"
         _IGH_BB_PAIRS="$_IGH_DEP_OUT"
         _IGH_BLOCKERS=$(printf '%s\n' "$_IGH_BB_PAIRS" | cut -d' ' -f1)
         return 0 ;;
      4) # The issue exists yet the endpoint is gone: GHES without the
         # dependencies API. Lock in the label fallback for this invocation.
         _igh_deps_mode="labels" ;;
      *) return 3 ;;
    esac
  fi
  _IGH_BLOCKERS=$(printf '%s' "$labels_json" \
    | grep -oE '"name":[[:space:]]*"blocked-by-[0-9]+"' \
    | grep -oE '[0-9]+' || true)
}

# _igh_blocker_state <m> — print open|closed|missing for blocker <m>.
# not-found → missing (a dangling edge is satisfied for claimability, R4);
# any other view failure returns 3 — resolution failures are backend errors.
_igh_blocker_state() {
  local m="$1" rc=0
  _igh_view "$m" state || rc=$?
  case "$rc" in
    0) case "$_IGH_VIEW_JSON" in
         *CLOSED*) echo closed ;;
         *)        echo open ;;
       esac ;;
    1) echo missing ;;
    *) return 3 ;;
  esac
}

# ── deps ────────────────────────────────────────────────────────────────────
cmd_deps() {
  local n="${1:-}"
  [ -n "$n" ] || { echo "Usage: issues-gh.sh deps <number>" >&2; exit 2; }
  local rc=0
  _igh_view "$n" labels || rc=$?
  case "$rc" in 1) exit 1 ;; 3) exit 3 ;; esac
  _igh_blockers_of "$n" "$_IGH_VIEW_JSON" || exit 3
  local m state bb=""
  for m in $_IGH_BLOCKERS; do
    state=$(_igh_blocker_state "$m") || exit 3
    [ -z "$bb" ] || bb+=", "
    bb+="{\"number\": $m, \"state\": \"$state\"}"
  done
  local out="" blocks=""
  if [ "$_igh_deps_mode" = "labels" ]; then
    # Reverse direction under the fallback: which issues carry our label.
    out=$(gh issue list --state all --search "label:\"blocked-by-$n\"" \
      --json number --jq '.[].number') || exit 3
  else
    rc=0
    _igh_dep_get "$n/dependencies/blocking" '.[].number' || rc=$?
    case "$rc" in
      0) out="$_IGH_DEP_OUT" ;;
      4) # blocked_by exists but blocking does not (partial rollout):
         # documented degradation — report no forward edges, loudly.
         echo "note: dependencies 'blocking' endpoint unavailable;" \
              "reporting \"blocks\": []" >&2
         out="" ;;
      *) exit 3 ;;
    esac
  fi
  for m in $out; do
    [ -z "$blocks" ] || blocks+=", "
    blocks+="$m"
  done
  printf '{"blockedBy": [%s], "blocks": [%s]}\n' "$bb" "$blocks"
}

# ── block ───────────────────────────────────────────────────────────────────
cmd_block() {
  local n="${1:-}" m=""
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in --on) m="$2"; shift 2 ;; *) shift ;; esac
  done
  if [ -z "$n" ] || [ -z "$m" ]; then
    echo "Usage: issues-gh.sh block <number> --on <number>" >&2; exit 2
  fi
  if [ "$n" = "$m" ]; then
    echo "Error: issue #$n cannot block itself" >&2; exit 1
  fi
  # Both ends must exist BEFORE any dependencies call: a 404 from those
  # endpoints is ambiguous (missing issue vs missing feature) and these
  # views are what disambiguate it. Blocker existence also keeps new edges
  # non-dangling, mirroring the file backend.
  local rc=0 n_json m_json
  _igh_view "$n" labels || rc=$?
  case "$rc" in 1) exit 1 ;; 3) exit 3 ;; esac
  n_json="$_IGH_VIEW_JSON"
  rc=0
  _igh_view "$m" labels || rc=$?
  case "$rc" in 1) exit 1 ;; 3) exit 3 ;; esac
  m_json="$_IGH_VIEW_JSON"
  # R2 is enforced HERE, script-side — never delegated to vendor duplicate
  # handling: read both directions first.
  _igh_blockers_of "$n" "$n_json" || exit 3
  local n_blockers="$_IGH_BLOCKERS"
  _igh_blockers_of "$m" "$m_json" || exit 3
  local m_blockers="$_IGH_BLOCKERS"
  if printf '%s\n' "$n_blockers" | grep -qxF -- "$m"; then
    exit 0   # idempotent re-add: edge already recorded, no write
  fi
  if printf '%s\n' "$m_blockers" | grep -qxF -- "$n"; then
    echo "Error: cycle — issue #$m is already blocked by #$n" >&2
    exit 1
  fi
  if [ "$_igh_deps_mode" = "labels" ]; then
    # GHES fallback: the edge is a label on the blocked issue. Creation is
    # best-effort (the label may already exist); a real permission failure
    # persists into the add and surfaces there as exit 3.
    gh label create "blocked-by-$m" \
      --description "Blocked by issue #$m (autocoder dependency edge)" \
      --color D93F0B >/dev/null 2>&1 || true
    gh issue edit "$n" --add-label "blocked-by-$m" >/dev/null || exit 3
  else
    local issue_id
    issue_id=$(gh api "repos/{owner}/{repo}/issues/$m" --jq .id) || exit 3
    gh api -X POST "repos/{owner}/{repo}/issues/$n/dependencies/blocked_by" \
      -F "issue_id=$issue_id" >/dev/null || exit 3
  fi
}

# ── unblock ─────────────────────────────────────────────────────────────────
cmd_unblock() {
  local n="${1:-}" m=""
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in --on) m="$2"; shift 2 ;; *) shift ;; esac
  done
  if [ -z "$n" ] || [ -z "$m" ]; then
    echo "Usage: issues-gh.sh unblock <number> --on <number>" >&2; exit 2
  fi
  local rc=0
  _igh_view "$n" labels || rc=$?
  case "$rc" in 1) exit 1 ;; 3) exit 3 ;; esac
  _igh_blockers_of "$n" "$_IGH_VIEW_JSON" || exit 3
  if ! printf '%s\n' "$_IGH_BLOCKERS" | grep -qxF -- "$m"; then
    echo "Error: issue #$n is not blocked by #$m" >&2
    exit 1   # absent edge: clean negative
  fi
  if [ "$_igh_deps_mode" = "labels" ]; then
    gh issue edit "$n" --remove-label "blocked-by-$m" >/dev/null || exit 3
  else
    local issue_id
    issue_id=$(printf '%s\n' "$_IGH_BB_PAIRS" \
      | awk -v m="$m" '$1 == m { print $2; exit }')
    [ -n "$issue_id" ] || exit 3   # pairs/numbers disagree: parse error
    gh api -X DELETE \
      "repos/{owner}/{repo}/issues/$n/dependencies/blocked_by/$issue_id" \
      >/dev/null || exit 3
  fi
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
  deps)          shift; cmd_deps "$@" ;;
  block)         shift; cmd_block "$@" ;;
  unblock)       shift; cmd_unblock "$@" ;;
  "")            echo "Usage: issues-gh.sh <verb> [args...]" >&2; exit 2 ;;
  *)             echo "Unknown verb: $1" >&2; exit 2 ;;
esac
