#!/usr/bin/env bash
# issue-events-lib.sh — an append-only record of each issue's lifecycle (#190).
#
# WHY THIS EXISTS:
#   A per-issue timeline (opened → claimed → first commit → each gate attempt → landed →
#   deployed → released, with the time each stage took) had no record to read. A UI had
#   to piece it together from issue comments, label events, git history and the merge
#   job's temp files, and every UI repeated that guesswork. The verbs that move an issue
#   through its life now append one line each, at the moment they act.
#
# FORMAT (version 1): one JSON object per line in
#   ${AUTOCODER_ISSUE_EVENTS:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/issue-events.jsonl}
#   {"v": 1, "ts": "<ISO-8601 UTC>", "repo": "<repo id>", "issue": <n>|null,
#    "worker": "<id>"|null, "branch": "<branch>"|null, "event": "<event>", "detail": {...}}
#   Events and their detail keys are listed in scripts/README.md ("Issue lifecycle"), which is
#   the contract readers (agents-ui) build on. It sits next to merge-events.jsonl (#184),
#   which keeps the per-attempt merge detail; gate-end here carries the same outcome.
#
# ROTATION: lines older than AUTOCODER_ISSUE_EVENTS_DAYS (default 30) are dropped when
#   the file passes 1 MiB, as merge-events-lib.sh does.
#
# Recording is best effort: a failure here never fails or delays the verb that called it.

_iev_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if ! declare -F autocoder_repo_id >/dev/null && [ -f "${_iev_DIR}/repo-id-fns.sh" ]; then
  # shellcheck source=repo-id-fns.sh
  source "${_iev_DIR}/repo-id-fns.sh"
fi

issue_events_file() {
  printf '%s\n' "${AUTOCODER_ISSUE_EVENTS:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/issue-events.jsonl}"
}

# issue_event <event> <issue|-> [key=value ...]
#   Reserved keys set the top-level fields instead of detail: repo=, worker=, branch=,
#   ts= (an ISO-8601 time the event happened, when that was earlier than now).
#   Defaults: repo from autocoder_repo_id (else the checkout's dir name), worker from
#   AUTOCODER_WORKER (else the checkout's dir name), branch from AUTOCODER_EVENT_BRANCH
#   (else the current branch). A merge job sets both shell variables, since it runs in a
#   throwaway worktree on a branch of its own.
#   Detail keys named in ISSUE_EVENT_INT_KEYS are written as numbers; children= takes a
#   space- or comma-separated list of issue numbers.
issue_event() {
  [ $# -ge 2 ] || return 0
  local f top repo worker branch
  f=$(issue_events_file)
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  top=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if declare -F autocoder_repo_id >/dev/null; then
    repo=$(autocoder_repo_id "${top:-$PWD}" 2>/dev/null || true)
  fi
  [ -n "${repo:-}" ] || repo=$(basename "${top:-$PWD}")
  worker="${AUTOCODER_WORKER:-$(basename "${top:-$PWD}")}"
  branch="${AUTOCODER_EVENT_BRANCH:-$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)}"
  python3 - "$f" "repo=$repo" "worker=$worker" "branch=$branch" "$@" <<'PY' 2>/dev/null || true
import datetime, json, os, re, sys, time
path, args = sys.argv[1], sys.argv[2:]
top = {}
for a in args[:3]:
    k, _, v = a.partition("=")
    top[k] = v or None
event, issue, rest = args[3], args[4], args[5:]
try:
    issue = int(issue)
except ValueError:
    issue = None
ev = {"v": 1, "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
      "repo": top["repo"], "issue": issue, "worker": top["worker"], "branch": top["branch"],
      "event": event, "detail": {}}
ints = {"attempt", "duration_s", "exit", "push_retries"}
for a in rest:
    k, _, v = a.partition("=")
    if k in ("repo", "worker", "branch"):
        ev[k] = v or None
    elif k == "ts":
        if v:
            ev["ts"] = v
    elif k == "children":
        ev["detail"][k] = [int(x) for x in re.split(r"[\s,#]+", v) if x.isdigit()]
    elif k in ints:
        try:
            ev["detail"][k] = int(v)
        except ValueError:
            ev["detail"][k] = None
    else:
        ev["detail"][k] = v if v != "" else None
line = json.dumps(ev, separators=(",", ":")) + "\n"
# One write() of an O_APPEND line: concurrent writers do not interleave.
# 0600 and O_NOFOLLOW: the log names branches and escalation reasons.
fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
try:
    os.write(fd, line.encode())
finally:
    os.close(fd)
if os.path.isfile(path) and os.path.getsize(path) > 1 << 20:
    try:
        import fcntl
        lock = open(path + ".lock", "w")
        fcntl.flock(lock, fcntl.LOCK_EX)
    except Exception:
        lock = None
    days = int(os.environ.get("AUTOCODER_ISSUE_EVENTS_DAYS", "30") or 30)
    cutoff = time.time() - days * 86400
    keep = []
    with open(path) as fh:
        for l in fh:
            try:
                ts = datetime.datetime.strptime(json.loads(l)["ts"], "%Y-%m-%dT%H:%M:%SZ")
                if ts.replace(tzinfo=datetime.timezone.utc).timestamp() >= cutoff:
                    keep.append(l)
            except Exception:
                pass
    import tempfile
    tfd, tmp = tempfile.mkstemp(prefix=".issue-events.", dir=os.path.dirname(path) or ".")
    with os.fdopen(tfd, "w") as fh:
        fh.writelines(keep)
    os.replace(tmp, path)
PY
}

# issue_event_seen <event> <issue> [repo] — 0 when the log already holds that event
#   for that issue (and repo, when given).
issue_event_seen() {
  local f
  f=$(issue_events_file)
  [ -f "$f" ] || return 1
  python3 -c '
import json, sys
path, event, issue = sys.argv[1], sys.argv[2], sys.argv[3]
repo = sys.argv[4] if len(sys.argv) > 4 else None
for l in open(path):
    try:
        e = json.loads(l)
    except ValueError:
        continue
    if e.get("event") == event and str(e.get("issue")) == issue and (repo is None or e.get("repo") == repo):
        sys.exit(0)
sys.exit(1)' "$f" "$@" 2>/dev/null
}

# _issue_events_after_update <issue> <update args...>
#   Called by issue_update after the backend succeeded. Label edits that are lifecycle
#   steps become events: dropping `working` is a release (unless the same call hands the
#   issue to `merging`/`awaiting-integration`), a blocking label is an escalation, and
#   `decomposed` records the split (children from AUTOCODER_EVENT_CHILDREN).
_issue_events_after_update() {
  local issue="$1"; shift
  local add=() rm_working=0 handoff=0 l
  while [ $# -gt 0 ]; do
    case "$1" in
      --add-label)    add+=("${2:-}"); shift 2 || shift ;;
      --add-label=*)  add+=("${1#--add-label=}"); shift ;;
      --remove-label) [ "${2:-}" = working ] && rm_working=1; shift 2 || shift ;;
      --remove-label=working) rm_working=1; shift ;;
      *) shift ;;
    esac
  done
  for l in "${add[@]+"${add[@]}"}"; do
    case "$l" in
      merging|awaiting-integration) handoff=1 ;;
      needs-clarification|needs-design|needs-approval|too-complex|future)
        issue_event escalated "$issue" label="$l" reason="${AUTOCODER_EVENT_REASON:-}" ;;
      decomposed)
        issue_event decomposed "$issue" children="${AUTOCODER_EVENT_CHILDREN:-}" ;;
    esac
  done
  # A merge job dropping `working` is bookkeeping on an issue it owns, not a worker
  # giving the issue up: it sets AUTOCODER_EVENT_NO_RELEASE.
  if [ "$rm_working" -eq 1 ] && [ "$handoff" -eq 0 ] && [ -z "${AUTOCODER_EVENT_NO_RELEASE:-}" ]; then
    issue_event released "$issue"
  fi
  return 0
}

# _issue_events_flag_value <flag> <args...> — the value given to <flag>, or nothing.
_issue_events_flag_value() {
  local flag="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      "$flag") printf '%s' "${2:-}"; return 0 ;;
      "$flag"=*) printf '%s' "${1#"$flag"=}"; return 0 ;;
    esac
    shift
  done
}
