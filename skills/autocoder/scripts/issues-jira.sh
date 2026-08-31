#!/bin/bash
# issues-jira.sh — Jira backend implementing the uniform 9-verb CLI.
#
# Counterpart to issues-gh.sh and issues-file.py. All three backends honor the
# same contract:
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
#   3 — backend error (curl failure, auth failure, parse error, config missing)
#
# Output schema for list/get matches issues-gh.sh / issues-file.py's to_gh_json
# shape (number, title, body, state OPEN|CLOSED, labels[{name}], comments[]).
#
# Identifier mapping:
#   Jira issues are keyed PROJ-123. The 9-verb contract, and the swarm manifest
#   (swarm-manifest-lib.sh does int(number)), treat the identifier as an
#   integer. So the backend exposes the numeric suffix as `number` and
#   reconstructs the full key from JIRA_PROJECT. Callers may pass either the
#   bare number (123) or the full key (PROJ-123); both resolve to the same
#   issue. This mirrors how issues-gh.sh scopes numbers to a single repo — the
#   Jira backend scopes them to a single project.
#
# Configuration (env wins over .autocoder.json's `jira` object; secrets are
# env-only and never read from the JSON):
#   JIRA_BASE_URL     e.g. https://acme.atlassian.net   (json: jira.baseUrl)
#   JIRA_PROJECT      project key, e.g. ENG             (json: jira.project)
#   JIRA_EMAIL        account email (Cloud basic auth)  — env only
#   JIRA_API_TOKEN    API token / password              — env only
#   JIRA_AUTH_HEADER  full Authorization header value, e.g. "Bearer <PAT>",
#                     for Jira Server/DC personal access tokens. Overrides the
#                     email+token basic auth when set.                — env only
#
# Notes:
#   - Issue lifecycle (create/get/update/comment/transitions/assignee) uses
#     REST API v2 so `description` is a plain string on both read and write.
#     API v3 would require Atlassian Document Format (ADF) for every body,
#     which buys nothing here and complicates round-tripping. Those v2
#     endpoints are NOT removed.
#   - Search uses POST /rest/api/3/search/jql: Atlassian REMOVED
#     POST /rest/api/2/search from Jira Cloud (HTTP 410, CHANGE-2046). The new
#     endpoint requires an explicit `fields` list to return field data,
#     paginates via `nextPageToken` (no startAt), and returns NO `total` —
#     so any-claimable checks for a non-empty first page (maxResults=1)
#     instead of reading a count. v3 also returns `description` as an ADF
#     document object; the list reshape flattens it back to the plain string
#     consumers of `body` have always received.
#   - claim is BEST-EFFORT (like the github backend): Jira label edits are not
#     atomic single-writer operations, so concurrent claims can both succeed.
#   - The claimable JQL excludes blocking labels AND includes label-less issues
#     via an explicit `labels is EMPTY` clause. `labels not in (...)` alone does
#     NOT match issues whose label field is empty — the same class of bug as
#     GitHub's `no:label` (#57). See tests/test_issues_jira.sh.

# NOTE: deliberately NOT `set -e`. This backend makes network calls whose
# failures must be mapped to specific exit codes (1 vs 3), which is far clearer
# with explicit checks than with an errexit trap firing mid-pipeline.

# ── blocking labels ─────────────────────────────────────────────────────────
# Same set as issues-gh.sh. `working` = claimed; the rest gate on a human
# decision. `awaiting-integration` = finished, waiting to merge — excluded from
# the claimable queue but NOT surfaced by `list --state blocked` (it is not a
# human-decision gate). Jira labels cannot contain spaces, which every label
# here already satisfies.
JIRA_BLOCKING_LABELS='working needs-design needs-clarification needs-feedback needs-approval too-complex future proposal awaiting-integration'
JIRA_BLOCKED_LABELS='needs-design needs-clarification needs-feedback needs-approval too-complex future proposal'

# ── config resolution ───────────────────────────────────────────────────────
_jira_cfg() {
  # Read a value from .autocoder.json's `jira` object. Non-secret keys only.
  local key="$1"
  local root
  root=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print substr($0, 10); exit}')
  [ -n "$root" ] || root="$(pwd)"
  local json="${root}/.autocoder.json"
  [ -f "$json" ] || return 0
  python3 - "$json" "$key" <<'PY' 2>/dev/null
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path)).get("jira", {}) or {}
    v = d.get(key, "")
    print(v if v is not None else "")
except Exception:
    print("")
PY
}

# The approved-work gate: when a required label is configured, only issues
# carrying it are claimable. See issue-approval-lib.sh.
_ijira_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=issue-approval-lib.sh
source "${_ijira_DIR}/issue-approval-lib.sh"
REQUIRED_LABEL="$(required_issue_label)"

JIRA_BASE_URL="${JIRA_BASE_URL:-$(_jira_cfg baseUrl)}"
JIRA_PROJECT="${JIRA_PROJECT:-$(_jira_cfg project)}"
JIRA_EMAIL="${JIRA_EMAIL:-}"
JIRA_API_TOKEN="${JIRA_API_TOKEN:-}"
JIRA_AUTH_HEADER="${JIRA_AUTH_HEADER:-}"

_jira_require_config() {
  local missing=""
  [ -n "$JIRA_BASE_URL" ] || missing="$missing JIRA_BASE_URL"
  [ -n "$JIRA_PROJECT" ]  || missing="$missing JIRA_PROJECT"
  if [ -z "$JIRA_AUTH_HEADER" ] && { [ -z "$JIRA_EMAIL" ] || [ -z "$JIRA_API_TOKEN" ]; }; then
    missing="$missing JIRA_EMAIL+JIRA_API_TOKEN(or JIRA_AUTH_HEADER)"
  fi
  if [ -n "$missing" ]; then
    echo "issues-jira.sh: missing configuration:$missing" >&2
    echo "  Set them in the environment, or add a \"jira\" object to .autocoder.json" >&2
    echo "  ({\"baseUrl\":\"https://acme.atlassian.net\",\"project\":\"ENG\"}). Secrets are env-only." >&2
    exit 3
  fi
}

# ── low-level HTTP ──────────────────────────────────────────────────────────
# Sets _JIRA_BODY and _JIRA_CODE. Returns non-zero only on transport failure
# (curl could not complete the request at all).
_jira_request() {
  local method="$1" path="$2" data="${3:-}"
  local url="${JIRA_BASE_URL%/}${path}"
  local args=(-sS -X "$method" -H "Accept: application/json" -w $'\n%{http_code}')
  if [ -n "$JIRA_AUTH_HEADER" ]; then
    args+=(-H "Authorization: ${JIRA_AUTH_HEADER}")
  else
    args+=(--user "${JIRA_EMAIL}:${JIRA_API_TOKEN}")
  fi
  if [ -n "$data" ]; then
    args+=(-H "Content-Type: application/json" --data "$data")
  fi
  local raw
  raw=$(curl "${args[@]}" "$url" 2>/dev/null) || { _JIRA_BODY=""; _JIRA_CODE="000"; return 1; }
  # The status code is the final line courtesy of -w '\n%{http_code}'.
  _JIRA_CODE="${raw##*$'\n'}"
  _JIRA_BODY="${raw%$'\n'*}"
  return 0
}

# Perform a request and treat any HTTP >= 400 as a backend error (exit 3).
# Usage: _jira_request_ok METHOD PATH [DATA]   → leaves body in _JIRA_BODY.
_jira_request_ok() {
  if ! _jira_request "$@"; then
    echo "issues-jira.sh: request to Jira failed (network/curl error)" >&2
    exit 3
  fi
  if [ "$_JIRA_CODE" -ge 400 ] 2>/dev/null; then
    echo "issues-jira.sh: Jira returned HTTP $_JIRA_CODE for $1 $2" >&2
    [ -n "$_JIRA_BODY" ] && echo "  $_JIRA_BODY" >&2
    exit 3
  fi
}

# ── key/number helpers ──────────────────────────────────────────────────────
# Accept "123" or "PROJ-123"; emit the full "PROJ-123" key.
_jira_key() {
  local id="$1"
  case "$id" in
    *-*) printf '%s' "$id" ;;
    *)   printf '%s-%s' "$JIRA_PROJECT" "$id" ;;
  esac
}

# ── JQL builders ────────────────────────────────────────────────────────────
# Render a space-separated label list as a JQL `(a, b, c)` tuple of quoted vals.
_jira_label_tuple() {
  local out="" l
  for l in $1; do
    [ -n "$out" ] && out="$out, "
    out="$out\"$l\""
  done
  printf '(%s)' "$out"
}

# The claimable/open filter. Excludes every blocking label, and — critically —
# still returns issues that carry NO labels at all via the explicit
# `labels is EMPTY` disjunct. Without it, `labels not in (...)` silently drops
# unlabeled issues and the autocoder loop idles forever (cf. GitHub #57).
# Gated here rather than at each call site: this is the single definition of
# "claimable" that both `list --state open` and any-claimable share. Note the
# required label also cancels the `labels is EMPTY` disjunct -- an unlabeled
# issue cannot carry the approval label, so it must not slip through.
_jira_open_jql() {
  local tuple
  tuple=$(_jira_label_tuple "$JIRA_BLOCKING_LABELS")
  if [ -n "$REQUIRED_LABEL" ]; then
    printf 'project = "%s" AND statusCategory != Done AND labels = "%s" AND labels not in %s' \
      "$JIRA_PROJECT" "$REQUIRED_LABEL" "$tuple"
    return 0
  fi
  printf 'project = "%s" AND statusCategory != Done AND (labels is EMPTY OR labels not in %s)' \
    "$JIRA_PROJECT" "$tuple"
}

_jira_state_jql() {
  case "$1" in
    open)    _jira_open_jql ;;
    working) printf 'project = "%s" AND statusCategory != Done AND labels = "working"' "$JIRA_PROJECT" ;;
    blocked) printf 'project = "%s" AND statusCategory != Done AND labels in %s' \
               "$JIRA_PROJECT" "$(_jira_label_tuple "$JIRA_BLOCKED_LABELS")" ;;
    closed)  printf 'project = "%s" AND statusCategory = Done' "$JIRA_PROJECT" ;;
    all)     printf 'project = "%s"' "$JIRA_PROJECT" ;;
    *)       echo "Unknown state: $1" >&2; exit 2 ;;
  esac
}

# ── list ─────────────────────────────────────────────────────────────────────
cmd_list() {
  local label="" state="open" limit="50"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) label="$2"; shift 2 ;;
      --state) state="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *)       shift ;;
    esac
  done
  local jql
  jql=$(_jira_state_jql "$state")
  [ -n "$label" ] && jql="$jql AND labels = \"$label\""

  # POST /rest/api/3/search/jql (v2 search is removed, HTTP 410). The new
  # contract: `fields` must be listed explicitly to get field data back, and
  # pagination is a nextPageToken loop — no startAt, no total. Pages are
  # accumulated (one JSON array per line) in a temp file until either the
  # requested limit is reached or the server stops returning a token.
  local pages token="" fetched=0 page_meta page_count
  pages=$(mktemp)
  while :; do
    local payload
    payload=$(JQL="$jql" LIMIT="$limit" FETCHED="$fetched" TOKEN="$token" python3 - <<'PY'
import json, os
remaining = int(os.environ["LIMIT"]) - int(os.environ["FETCHED"])
req = {
    "jql": os.environ["JQL"],
    "maxResults": min(remaining, 100),
    "fields": ["summary", "description", "labels", "status"],
}
if os.environ.get("TOKEN"):
    req["nextPageToken"] = os.environ["TOKEN"]
print(json.dumps(req))
PY
)
    _jira_request_ok POST "/rest/api/3/search/jql" "$payload"
    # Append this page's issues to the accumulator and read back
    # "<count> <nextPageToken>". The response is passed via an env var, NOT
    # stdin: a `python3 - <<'PY'` heredoc already binds stdin to the script
    # source, so a piped body would be swallowed.
    page_meta=$(RESP="$_JIRA_BODY" python3 - "$pages" <<'PY'
import json, os, sys
try:
    data = json.loads(os.environ["RESP"])
except Exception:
    print("issues-jira.sh: could not parse Jira search response", file=sys.stderr)
    raise SystemExit(3)
issues = data.get("issues", []) or []
with open(sys.argv[1], "a") as fh:
    fh.write(json.dumps(issues) + "\n")
print(len(issues), data.get("nextPageToken") or "")
PY
) || { rm -f "$pages"; exit 3; }
    page_count="${page_meta%% *}"
    token="${page_meta#* }"
    [ "$token" = "$page_meta" ] && token=""
    fetched=$((fetched + page_count))
    # Stop on: limit reached, no further page, or an empty page (safety net
    # against a server that keeps handing back tokens).
    if [ "$fetched" -ge "$limit" ] || [ -z "$token" ] || [ "$page_count" -eq 0 ]; then
      break
    fi
  done

  # Reshape the accumulated pages into the gh-compatible array.
  LIMIT="$limit" python3 - "$pages" <<'PY' || { rm -f "$pages"; exit 3; }
import json, os, sys

def flatten_adf(desc):
    # v3 search returns `description` as an ADF document object; consumers of
    # `body` expect the plain string that v2 (and the v2 CRUD paths, which are
    # unchanged) always delivered. Walk the node tree collecting text values;
    # top-level blocks (paragraphs) are joined with newlines. Tolerates None,
    # plain strings, and malformed nodes.
    if desc is None:
        return ""
    if isinstance(desc, str):
        return desc
    if not isinstance(desc, dict):
        return ""
    def text_of(node):
        if not isinstance(node, dict):
            return ""
        if node.get("type") == "text":
            return node.get("text") or ""
        return "".join(text_of(c) for c in (node.get("content") or []))
    return "\n".join(text_of(b) for b in (desc.get("content") or []))

out = []
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        for it in json.loads(line):
            f = it.get("fields", {}) or {}
            key = it.get("key", "")
            num = key.rsplit("-", 1)[-1]
            try:
                num = int(num)
            except ValueError:
                pass
            cat = (((f.get("status") or {}).get("statusCategory") or {}).get("key") or "").lower()
            out.append({
                "number": num,
                "title": f.get("summary") or "",
                "body": flatten_adf(f.get("description")),
                "labels": [{"name": l} for l in (f.get("labels") or [])],
                "state": "CLOSED" if cat == "done" else "OPEN",
            })
print(json.dumps(out[:int(os.environ["LIMIT"])]))
PY
  rm -f "$pages"
}

# ── get ──────────────────────────────────────────────────────────────────────
cmd_get() {
  local key
  key=$(_jira_key "$1")
  # 404 on a get is "not found" → exit 1, distinct from a real backend error.
  if ! _jira_request GET "/rest/api/2/issue/${key}?fields=summary,description,labels,status,comment"; then
    echo "issues-jira.sh: request to Jira failed (network/curl error)" >&2
    exit 3
  fi
  if [ "$_JIRA_CODE" = "404" ]; then
    echo "issues-jira.sh: issue $key not found" >&2
    exit 1
  fi
  if [ "$_JIRA_CODE" -ge 400 ] 2>/dev/null; then
    echo "issues-jira.sh: Jira returned HTTP $_JIRA_CODE for GET $key" >&2
    exit 3
  fi
  RESP="$_JIRA_BODY" python3 - <<'PY' || exit 3
import json, os
try:
    it = json.loads(os.environ["RESP"])
except Exception:
    print("issues-jira.sh: could not parse Jira issue response", file=sys.stderr)
    raise SystemExit(3)
f = it.get("fields", {}) or {}
key = it.get("key", "")
num = key.rsplit("-", 1)[-1]
try:
    num = int(num)
except ValueError:
    pass
cat = (((f.get("status") or {}).get("statusCategory") or {}).get("key") or "").lower()
comments = ((f.get("comment") or {}).get("comments")) or []
print(json.dumps({
    "number": num,
    "title": f.get("summary") or "",
    "body": f.get("description") or "",
    "labels": [{"name": l} for l in (f.get("labels") or [])],
    "state": "CLOSED" if cat == "done" else "OPEN",
    "comments": [{"body": c.get("body") or ""} for c in comments],
}))
PY
}

# ── label edits ──────────────────────────────────────────────────────────────
_jira_edit_labels() {
  # _jira_edit_labels KEY "add:l1 add:l2 remove:l3"
  local key="$1" ops="$2"
  local payload
  payload=$(OPS="$ops" python3 - <<'PY'
import json, os
ops = os.environ["OPS"].split()
labels = []
for op in ops:
    action, _, val = op.partition(":")
    if val:
        labels.append({action: val})
print(json.dumps({"update": {"labels": labels}}))
PY
)
  _jira_request_ok PUT "/rest/api/2/issue/${key}" "$payload" >/dev/null
}

# ── transitions ──────────────────────────────────────────────────────────────
# Move an issue to a target status category (done | new | indeterminate) by
# finding a matching transition. Best-effort: if no transition matches, warn but
# do not fail the whole verb — label state (the load-bearing signal for this
# workflow) is applied separately.
_jira_transition_to_category() {
  local key="$1" target="$2"
  _jira_request_ok GET "/rest/api/2/issue/${key}/transitions"
  local tid
  tid=$(TARGET="$target" RESP="$_JIRA_BODY" python3 - <<'PY'
import json, os
target = os.environ["TARGET"].lower()
try:
    data = json.loads(os.environ["RESP"])
except Exception:
    raise SystemExit(0)
for t in data.get("transitions", []):
    cat = (((t.get("to") or {}).get("statusCategory") or {}).get("key") or "").lower()
    if cat == target:
        print(t.get("id", ""))
        break
PY
)
  if [ -z "$tid" ]; then
    echo "issues-jira.sh: no transition to statusCategory '$target' available for $key" >&2
    return 1
  fi
  _jira_request_ok POST "/rest/api/2/issue/${key}/transitions" "{\"transition\":{\"id\":\"${tid}\"}}" >/dev/null
}

# ── update ───────────────────────────────────────────────────────────────────
cmd_update() {
  local key
  key=$(_jira_key "$1"); shift
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
      closed)  _jira_transition_to_category "$key" done || exit 3 ;;
      open)    _jira_transition_to_category "$key" new  || exit 3 ;;
      working) ops="$ops add:working" ;;
    esac
  fi

  [ -n "$ops" ] && _jira_edit_labels "$key" "$ops"

  if [ -n "$assignee" ]; then
    # Cloud wants accountId; Server/DC wants name. Send both keys; Jira ignores
    # the one it does not recognise.
    _jira_request_ok PUT "/rest/api/2/issue/${key}/assignee" \
      "{\"accountId\":\"${assignee}\",\"name\":\"${assignee}\"}" >/dev/null
  fi
}

# ── comment ──────────────────────────────────────────────────────────────────
cmd_comment() {
  local key
  key=$(_jira_key "$1"); shift
  local body=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --body) body="$2"; shift 2 ;; *) shift ;; esac
  done
  local payload
  payload=$(BODY="$body" python3 -c 'import json,os; print(json.dumps({"body": os.environ["BODY"]}))')
  _jira_request_ok POST "/rest/api/2/issue/${key}/comment" "$payload" >/dev/null
}

# ── close ────────────────────────────────────────────────────────────────────
cmd_close() {
  local key
  key=$(_jira_key "$1"); shift
  local comment=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --comment) comment="$2"; shift 2 ;; *) shift ;; esac
  done
  if [ -n "$comment" ]; then
    local payload
    payload=$(BODY="$comment" python3 -c 'import json,os; print(json.dumps({"body": os.environ["BODY"]}))')
    _jira_request_ok POST "/rest/api/2/issue/${key}/comment" "$payload" >/dev/null
  fi
  _jira_transition_to_category "$key" done || exit 3
}

# ── create ───────────────────────────────────────────────────────────────────
cmd_create() {
  local title="" body="" labels=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --body)  body="$2"; shift 2 ;;
      --label) labels="$labels $2"; shift 2 ;;
      *)       shift ;;
    esac
  done
  local payload
  payload=$(PROJECT="$JIRA_PROJECT" TITLE="$title" BODY="$body" LABELS="$labels" python3 - <<'PY'
import json, os
fields = {
    "project": {"key": os.environ["PROJECT"]},
    "summary": os.environ["TITLE"],
    "description": os.environ["BODY"],
    "issuetype": {"name": os.environ.get("JIRA_ISSUE_TYPE", "Task")},
}
labels = os.environ.get("LABELS", "").split()
if labels:
    fields["labels"] = labels
print(json.dumps({"fields": fields}))
PY
)
  _jira_request_ok POST "/rest/api/2/issue" "$payload"
  RESP="$_JIRA_BODY" python3 - <<'PY' || exit 3
import json, os
try:
    it = json.loads(os.environ["RESP"])
except Exception:
    print("issues-jira.sh: could not parse create response", file=sys.stderr)
    raise SystemExit(3)
key = it.get("key", "")
num = key.rsplit("-", 1)[-1]
try:
    num = int(num)
except ValueError:
    pass
print(json.dumps({"number": num}))
PY
}

# ── claim (best-effort) ──────────────────────────────────────────────────────
cmd_claim() {
  local key
  key=$(_jira_key "$1")
  # Gate the claim itself, not just the queue: issues reach a worker by number
  # from paths the queue never filters (manager dispatch, /fix N, a resumed
  # loop). Exit 1 is the clean negative callers already handle.
  if [ -n "$REQUIRED_LABEL" ]; then
    _jira_request_ok GET "/rest/api/2/issue/${key}?fields=labels"
    local labels
    labels=$(printf '%s' "$_JIRA_BODY" | python3 -c \
      'import json,sys; print(" ".join(json.load(sys.stdin).get("fields",{}).get("labels") or []))' 2>/dev/null) || exit 3
    if ! issue_labels_approved "$labels"; then
      issue_approval_refusal "$1" "$REQUIRED_LABEL"
      exit 1
    fi
  fi
  _jira_edit_labels "$key" "add:working"
  # Best-effort: Jira has no atomic single-writer label edit. See header note.
}

# ── release ──────────────────────────────────────────────────────────────────
cmd_release() {
  local key
  key=$(_jira_key "$1")
  _jira_edit_labels "$key" "remove:working"
}

# ── any-claimable ────────────────────────────────────────────────────────────
cmd_any_claimable() {
  # The v3 search/jql response has no `total` (removed with the old API), and
  # this verb never needed a count — only existence. Ask for a single result
  # with the cheapest field set and test whether the first page is non-empty.
  local payload
  payload=$(JQL="$(_jira_open_jql)" python3 - <<'PY'
import json, os
print(json.dumps({"jql": os.environ["JQL"], "maxResults": 1, "fields": ["id"]}))
PY
)
  _jira_request_ok POST "/rest/api/3/search/jql" "$payload"
  local count
  count=$(printf '%s' "$_JIRA_BODY" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("issues") or []))' 2>/dev/null) || exit 3
  [ "${count:-0}" -gt 0 ] 2>/dev/null
}

# ── dispatch ─────────────────────────────────────────────────────────────────
verb="${1:-}"
case "$verb" in
  "")            echo "Usage: issues-jira.sh <verb> [args...]" >&2; exit 2 ;;
  list|get|update|comment|close|create|claim|release|any-claimable) ;;
  *)             echo "Unknown verb: $verb" >&2; exit 2 ;;
esac

_jira_require_config

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
