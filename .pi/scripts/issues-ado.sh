#!/bin/bash
# issues-ado.sh — Azure DevOps backend implementing the uniform 9-verb CLI.
#
# Counterpart to issues-gh.sh, issues-file.py, and issues-jira.sh. All backends
# honor the same contract:
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
#   1 — clean negative (no claimable, race lost, work item not found)
#   2 — usage error
#   3 — backend error (curl failure, auth failure, parse error, config missing)
#
# Output schema for list/get matches the other backends' gh-compatible shape
# (number, title, body, state OPEN|CLOSED, labels[{name}], comments[]).
#
# Identifier mapping:
#   Azure DevOps work items have org-wide integer IDs, so `number` IS the work
#   item id directly — no prefix juggling (unlike Jira's PROJ-N keys).
#
# Model mapping:
#   - "labels"  → work-item **Tags** (System.Tags, a "; "-joined string).
#   - "state"   → System.State, classified via a done-state set that covers the
#     default Agile/Basic/Scrum/CMMI processes (Closed/Done/Resolved/Removed/
#     Completed). Override the state `close` writes with ADO_CLOSED_STATE.
#   - create uses work-item type $Task by default (present in every default
#     process); override with ADO_WORKITEM_TYPE.
#
# Configuration (env wins over .autocoder.json's `ado` object; the PAT is
# env-only and never read from JSON / committed):
#   ADO_ORG_URL   e.g. https://dev.azure.com/myorg   (json: ado.orgUrl)
#   ADO_ORG       org name, if ADO_ORG_URL unset      (json: ado.org)
#   ADO_PROJECT   project name or id                  (json: ado.project)
#   ADO_PAT       personal access token (Basic auth, empty user) — env only
#
# Notes:
#   - claim is BEST-EFFORT (like the github/jira backends): Azure DevOps tag
#     edits are not atomic single-writer ops, so concurrent claims can race.
#   - Unlike Jira/GitHub, WIQL's `[System.Tags] NOT CONTAINS 'x'` already
#     matches work items that have NO tags, so the claimable query needs no
#     special "empty" clause. A test asserts an untagged item stays claimable.

# NOT `set -e`: network failures must map to specific exit codes (1 vs 3), which
# is clearer with explicit checks than an errexit trap firing mid-pipeline.

API_VERSION="7.0"
COMMENTS_API_VERSION="7.0-preview.3"

# Tags that gate claimability; same taxonomy as the other backends.
ADO_BLOCKING_TAGS='working needs-design needs-clarification needs-feedback needs-approval too-complex future proposal awaiting-integration'
ADO_BLOCKED_TAGS='needs-design needs-clarification needs-feedback needs-approval too-complex future proposal'
# States treated as "done" across the default processes.
ADO_DONE_STATES="Closed Done Resolved Removed Completed"

# ── config resolution ───────────────────────────────────────────────────────
_ado_cfg() {
  local key="$1" root json
  root=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print substr($0, 10); exit}')
  [ -n "$root" ] || root="$(pwd)"
  json="${root}/.autocoder.json"
  [ -f "$json" ] || return 0
  python3 - "$json" "$key" <<'PY' 2>/dev/null
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path)).get("ado", {}) or {}
    v = d.get(key, "")
    print(v if v is not None else "")
except Exception:
    print("")
PY
}

# The approved-work gate: when a required label is configured, only work items
# carrying it as a tag are claimable. See issue-approval-lib.sh.
_iado_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=issue-approval-lib.sh
source "${_iado_DIR}/issue-approval-lib.sh"
REQUIRED_LABEL="$(required_issue_label)"

ADO_ORG_URL="${ADO_ORG_URL:-$(_ado_cfg orgUrl)}"
if [ -z "$ADO_ORG_URL" ]; then
  _ado_org="${ADO_ORG:-$(_ado_cfg org)}"
  [ -n "$_ado_org" ] && ADO_ORG_URL="https://dev.azure.com/${_ado_org}"
fi
ADO_PROJECT="${ADO_PROJECT:-$(_ado_cfg project)}"
ADO_PAT="${ADO_PAT:-}"

_ado_require_config() {
  local missing=""
  [ -n "$ADO_ORG_URL" ] || missing="$missing ADO_ORG_URL(or ADO_ORG)"
  [ -n "$ADO_PROJECT" ] || missing="$missing ADO_PROJECT"
  [ -n "$ADO_PAT" ]     || missing="$missing ADO_PAT"
  if [ -n "$missing" ]; then
    echo "issues-ado.sh: missing configuration:$missing" >&2
    echo "  Set them in the environment, or add an \"ado\" object to .autocoder.json" >&2
    echo "  ({\"orgUrl\":\"https://dev.azure.com/myorg\",\"project\":\"MyProject\"}). The PAT is env-only." >&2
    exit 3
  fi
}

# ── low-level HTTP ──────────────────────────────────────────────────────────
# Sets _ADO_BODY and _ADO_CODE. Returns non-zero only on transport failure.
# Usage: _ado_request METHOD PATH [DATA] [CONTENT_TYPE]
#   PATH is appended to "<org>/<project>" and must include ?api-version=...
_ado_request() {
  local method="$1" path="$2" data="${3:-}" ctype="${4:-application/json}"
  local url="${ADO_ORG_URL%/}/${ADO_PROJECT}${path}"
  local args=(-sS -X "$method" -H "Accept: application/json" -u ":${ADO_PAT}" -w $'\n%{http_code}')
  if [ -n "$data" ]; then
    args+=(-H "Content-Type: ${ctype}" --data "$data")
  fi
  local raw
  raw=$(curl "${args[@]}" "$url" 2>/dev/null) || { _ADO_BODY=""; _ADO_CODE="000"; return 1; }
  _ADO_CODE="${raw##*$'\n'}"
  _ADO_BODY="${raw%$'\n'*}"
  return 0
}

# Request that treats HTTP >= 400 as a backend error (exit 3).
_ado_request_ok() {
  if ! _ado_request "$@"; then
    echo "issues-ado.sh: request to Azure DevOps failed (network/curl error)" >&2
    exit 3
  fi
  if [ "$_ADO_CODE" -ge 400 ] 2>/dev/null; then
    echo "issues-ado.sh: Azure DevOps returned HTTP $_ADO_CODE for $1 $2" >&2
    [ -n "$_ADO_BODY" ] && echo "  $_ADO_BODY" >&2
    exit 3
  fi
}

# ── WIQL builders ────────────────────────────────────────────────────────────
_ado_done_in() {   # -> 'Closed','Done',...
  local out="" s
  for s in $ADO_DONE_STATES; do [ -n "$out" ] && out="$out, "; out="$out'$s'"; done
  printf '%s' "$out"
}
_ado_not_tags() {  # AND [System.Tags] NOT CONTAINS 'x' ... for each blocking tag
  local out="" t
  for t in $ADO_BLOCKING_TAGS; do out="$out AND [System.Tags] NOT CONTAINS '$t'"; done
  printf '%s' "$out"
}
_ado_required_tag() { # AND [System.Tags] CONTAINS 'swarm', or nothing
  [ -n "$REQUIRED_LABEL" ] || return 0
  printf " AND [System.Tags] CONTAINS '%s'" "$REQUIRED_LABEL"
}
_ado_blocked_or() { # ([System.Tags] CONTAINS 'a' OR ...)
  local out="" t
  for t in $ADO_BLOCKED_TAGS; do [ -n "$out" ] && out="$out OR "; out="$out[System.Tags] CONTAINS '$t'"; done
  printf '(%s)' "$out"
}

_ado_state_wiql() {
  local done_in; done_in=$(_ado_done_in)
  case "$1" in
    # Gated at the single definition of "claimable" that both `list --state
    # open` and any-claimable share.
    open)    printf "SELECT [System.Id] FROM WorkItems WHERE [System.State] NOT IN (%s)%s%s" \
               "$done_in" "$(_ado_not_tags)" "$(_ado_required_tag)" ;;
    working) printf "SELECT [System.Id] FROM WorkItems WHERE [System.State] NOT IN (%s) AND [System.Tags] CONTAINS 'working'" "$done_in" ;;
    blocked) printf "SELECT [System.Id] FROM WorkItems WHERE [System.State] NOT IN (%s) AND %s" "$done_in" "$(_ado_blocked_or)" ;;
    closed)  printf "SELECT [System.Id] FROM WorkItems WHERE [System.State] IN (%s)" "$done_in" ;;
    all)     printf "SELECT [System.Id] FROM WorkItems WHERE [System.Id] > 0" ;;
    *)       echo "Unknown state: $1" >&2; exit 2 ;;
  esac
}

# Run a WIQL query; leaves the matched ids (space-separated) in _ADO_IDS.
_ado_wiql_ids() {
  local wiql="$1"
  local payload
  payload=$(WIQL="$wiql" python3 -c 'import json,os; print(json.dumps({"query": os.environ["WIQL"]}))')
  _ado_request_ok POST "/_apis/wit/wiql?api-version=${API_VERSION}" "$payload"
  _ADO_IDS=$(printf '%s' "$_ADO_BODY" | python3 -c 'import json,sys; print(" ".join(str(w["id"]) for w in json.load(sys.stdin).get("workItems",[])))' 2>/dev/null) || exit 3
}

# ── list ─────────────────────────────────────────────────────────────────────
cmd_list() {
  local label="" state="open" limit=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) label="$2"; shift 2 ;;
      --state) state="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *)       shift ;;
    esac
  done
  local wiql; wiql=$(_ado_state_wiql "$state")
  [ -n "$label" ] && wiql="$wiql AND [System.Tags] CONTAINS '$label'"
  _ado_wiql_ids "$wiql"

  # Apply --limit client-side (WIQL has no reliable TOP in the body).
  local ids="$_ADO_IDS"
  if [ -n "$limit" ] && [ -n "$ids" ]; then
    ids=$(printf '%s' "$ids" | tr ' ' '\n' | head -n "$limit" | tr '\n' ' ')
  fi
  if [ -z "${ids// }" ]; then echo "[]"; return 0; fi

  local batch
  batch=$(IDS="$ids" python3 -c '
import json, os
ids = [int(x) for x in os.environ["IDS"].split()]
print(json.dumps({"ids": ids, "fields": ["System.Id","System.Title","System.Description","System.Tags","System.State"]}))')
  _ado_request_ok POST "/_apis/wit/workitemsbatch?api-version=${API_VERSION}" "$batch"
  DONE="$ADO_DONE_STATES" RESP="$_ADO_BODY" python3 - <<'PY' || exit 3
import json, os
done = set(os.environ["DONE"].split())
try:
    data = json.loads(os.environ["RESP"])
except Exception:
    print("issues-ado.sh: could not parse workitemsbatch response", file=__import__("sys").stderr)
    raise SystemExit(3)
out = []
for it in data.get("value", []):
    f = it.get("fields", {}) or {}
    tags = [t.strip() for t in (f.get("System.Tags") or "").split(";") if t.strip()]
    out.append({
        "number": it.get("id"),
        "title": f.get("System.Title") or "",
        "body": f.get("System.Description") or "",
        "labels": [{"name": t} for t in tags],
        "state": "CLOSED" if (f.get("System.State") in done) else "OPEN",
    })
print(json.dumps(out))
PY
}

# ── get ──────────────────────────────────────────────────────────────────────
cmd_get() {
  local id="$1"
  if ! _ado_request GET "/_apis/wit/workitems/${id}?api-version=${API_VERSION}"; then
    echo "issues-ado.sh: request to Azure DevOps failed (network/curl error)" >&2; exit 3
  fi
  if [ "$_ADO_CODE" = "404" ]; then
    echo "issues-ado.sh: work item $id not found" >&2; exit 1
  fi
  if [ "$_ADO_CODE" -ge 400 ] 2>/dev/null; then
    echo "issues-ado.sh: Azure DevOps returned HTTP $_ADO_CODE for GET $id" >&2; exit 3
  fi
  local wi_body="$_ADO_BODY"
  # Comments live behind a separate (preview) endpoint.
  local comments_json='{"comments":[]}'
  if _ado_request GET "/_apis/wit/workItems/${id}/comments?api-version=${COMMENTS_API_VERSION}"; then
    [ "$_ADO_CODE" -lt 400 ] 2>/dev/null && comments_json="$_ADO_BODY"
  fi
  DONE="$ADO_DONE_STATES" WI="$wi_body" CMT="$comments_json" python3 - <<'PY' || exit 3
import json, os
done = set(os.environ["DONE"].split())
try:
    it = json.loads(os.environ["WI"])
    cm = json.loads(os.environ["CMT"])
except Exception:
    print("issues-ado.sh: could not parse work item response", file=__import__("sys").stderr)
    raise SystemExit(3)
f = it.get("fields", {}) or {}
tags = [t.strip() for t in (f.get("System.Tags") or "").split(";") if t.strip()]
comments = [{"body": c.get("text") or ""} for c in (cm.get("comments") or [])]
print(json.dumps({
    "number": it.get("id"),
    "title": f.get("System.Title") or "",
    "body": f.get("System.Description") or "",
    "labels": [{"name": t} for t in tags],
    "state": "CLOSED" if (f.get("System.State") in done) else "OPEN",
    "comments": comments,
}))
PY
}

# ── tag edits (read-modify-write, since System.Tags is one string) ──────────
_ado_edit_tags() {
  # _ado_edit_tags ID "add:a add:b remove:c"
  local id="$1" ops="$2"
  _ado_request_ok GET "/_apis/wit/workitems/${id}?fields=System.Tags&api-version=${API_VERSION}"
  local newtags
  newtags=$(OPS="$ops" RESP="$_ADO_BODY" python3 - <<'PY'
import json, os
try:
    cur = (json.loads(os.environ["RESP"]).get("fields", {}) or {}).get("System.Tags") or ""
except Exception:
    cur = ""
tags = [t.strip() for t in cur.split(";") if t.strip()]
for op in os.environ["OPS"].split():
    action, _, val = op.partition(":")
    if not val:
        continue
    if action == "add" and val not in tags:
        tags.append(val)
    elif action == "remove" and val in tags:
        tags.remove(val)
print("; ".join(tags))
PY
)
  local patch
  patch=$(V="$newtags" python3 -c 'import json,os; print(json.dumps([{"op":"add","path":"/fields/System.Tags","value":os.environ["V"]}]))')
  _ado_request_ok PATCH "/_apis/wit/workitems/${id}?api-version=${API_VERSION}" "$patch" "application/json-patch+json" >/dev/null
}

_ado_set_state() {
  local id="$1" state="$2" patch
  patch=$(V="$state" python3 -c 'import json,os; print(json.dumps([{"op":"add","path":"/fields/System.State","value":os.environ["V"]}]))')
  _ado_request_ok PATCH "/_apis/wit/workitems/${id}?api-version=${API_VERSION}" "$patch" "application/json-patch+json" >/dev/null
}

# ── update ───────────────────────────────────────────────────────────────────
cmd_update() {
  local id="$1"; shift
  local ops="" status="" assignee=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --add-label)    ops="$ops add:$2";    shift 2 ;;
      --remove-label) ops="$ops remove:$2"; shift 2 ;;
      --status)       status="$2";          shift 2 ;;
      --assignee)     assignee="$2";        shift 2 ;;
      *)              shift ;;
    esac
  done
  if [ -n "$status" ]; then
    case "$status" in
      closed)  _ado_set_state "$id" "${ADO_CLOSED_STATE:-Closed}" ;;
      open)    _ado_set_state "$id" "${ADO_OPEN_STATE:-Active}" ;;
      working) ops="$ops add:working" ;;
    esac
  fi
  [ -n "$ops" ] && _ado_edit_tags "$id" "$ops"
  if [ -n "$assignee" ]; then
    local patch
    patch=$(V="$assignee" python3 -c 'import json,os; print(json.dumps([{"op":"add","path":"/fields/System.AssignedTo","value":os.environ["V"]}]))')
    _ado_request_ok PATCH "/_apis/wit/workitems/${id}?api-version=${API_VERSION}" "$patch" "application/json-patch+json" >/dev/null
  fi
}

# ── comment ──────────────────────────────────────────────────────────────────
cmd_comment() {
  local id="$1"; shift
  local body=""
  while [[ $# -gt 0 ]]; do case "$1" in --body) body="$2"; shift 2 ;; *) shift ;; esac; done
  local payload
  payload=$(T="$body" python3 -c 'import json,os; print(json.dumps({"text": os.environ["T"]}))')
  _ado_request_ok POST "/_apis/wit/workItems/${id}/comments?api-version=${COMMENTS_API_VERSION}" "$payload" >/dev/null
}

# ── close ────────────────────────────────────────────────────────────────────
cmd_close() {
  local id="$1"; shift
  local comment=""
  while [[ $# -gt 0 ]]; do case "$1" in --comment) comment="$2"; shift 2 ;; *) shift ;; esac; done
  if [ -n "$comment" ]; then
    local payload
    payload=$(T="$comment" python3 -c 'import json,os; print(json.dumps({"text": os.environ["T"]}))')
    _ado_request_ok POST "/_apis/wit/workItems/${id}/comments?api-version=${COMMENTS_API_VERSION}" "$payload" >/dev/null
  fi
  _ado_set_state "$id" "${ADO_CLOSED_STATE:-Closed}"
}

# ── create ───────────────────────────────────────────────────────────────────
cmd_create() {
  local title="" body="" tags=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --body)  body="$2"; shift 2 ;;
      --label) tags="$tags${tags:+; }$2"; shift 2 ;;
      *)       shift ;;
    esac
  done
  local patch
  patch=$(TITLE="$title" BODY="$body" TAGS="$tags" python3 - <<'PY'
import json, os
ops = [
    {"op": "add", "path": "/fields/System.Title", "value": os.environ["TITLE"]},
    {"op": "add", "path": "/fields/System.Description", "value": os.environ["BODY"]},
]
if os.environ.get("TAGS"):
    ops.append({"op": "add", "path": "/fields/System.Tags", "value": os.environ["TAGS"]})
print(json.dumps(ops))
PY
)
  local wtype="${ADO_WORKITEM_TYPE:-Task}"
  # The work-item type goes in the path as $Type and must be URL-escaped ($ -> %24).
  _ado_request_ok POST "/_apis/wit/workitems/%24${wtype}?api-version=${API_VERSION}" "$patch" "application/json-patch+json"
  RESP="$_ADO_BODY" python3 - <<'PY' || exit 3
import json, os
try:
    it = json.loads(os.environ["RESP"])
except Exception:
    print("issues-ado.sh: could not parse create response", file=__import__("sys").stderr)
    raise SystemExit(3)
print(json.dumps({"number": it.get("id")}))
PY
}

# ── claim / release (best-effort) ────────────────────────────────────────────
# Gate the claim itself, not just the queue: work items reach a worker by id
# from paths the queue never filters (manager dispatch, /fix N, a resumed
# loop). Exit 1 is the clean negative callers already handle.
cmd_claim() {
  if [ -n "$REQUIRED_LABEL" ]; then
    _ado_request_ok GET "/_apis/wit/workitems/${1}?fields=System.Tags&api-version=${API_VERSION}"
    local tags
    tags=$(printf '%s' "$_ADO_BODY" | python3 -c \
      'import json,sys; print(" ".join(t.strip() for t in ((json.load(sys.stdin).get("fields",{}) or {}).get("System.Tags") or "").split(";") if t.strip()))' 2>/dev/null) || exit 3
    if ! issue_labels_approved "$tags"; then
      issue_approval_refusal "$1" "$REQUIRED_LABEL"
      exit 1
    fi
  fi
  _ado_edit_tags "$1" "add:working"
}
cmd_release() { _ado_edit_tags "$1" "remove:working"; }

# ── any-claimable ────────────────────────────────────────────────────────────
cmd_any_claimable() {
  _ado_wiql_ids "$(_ado_state_wiql open)"
  [ -n "${_ADO_IDS// }" ]
}

# ── dispatch ─────────────────────────────────────────────────────────────────
verb="${1:-}"
case "$verb" in
  "")            echo "Usage: issues-ado.sh <verb> [args...]" >&2; exit 2 ;;
  list|get|update|comment|close|create|claim|release|any-claimable) ;;
  *)             echo "Unknown verb: $verb" >&2; exit 2 ;;
esac

_ado_require_config

case "$verb" in
  list)          shift; cmd_list "$@" ;;
  get)           shift; cmd_get "$@" ;;
  update)        shift; cmd_update "$@" ;;
  comment)       shift; cmd_comment "$@" ;;
  close)         shift; cmd_close "$@" ;;
  create)        shift; cmd_create "$@" ;;
  claim)         shift; cmd_claim "$@" ;;
  release)       shift; cmd_release "$@" ;;
  any-claimable) cmd_any_claimable ;;
esac
