#!/bin/bash
# worker-verdict-watchdog.sh — nudge a worker whose background pre-check verdict it never saw.
#
# WHY THIS EXISTS (#7134):
#   A worker that runs its pre-check (the project's prebank, a scratch typecheck) in a
#   background shell waits for the shell's completion notification. Four times in one day
#   on one fleet that notification never reached the agent: the run had finished (PASS or
#   FAIL) or had died mid-stage, and the worker sat at an idle prompt for 35 minutes to
#   1.7 hours until a person read the log and re-prompted it. About four worker-hours of
#   idle time in a day, more than any gate inefficiency left. The worker-side rule is in
#   fix.md ("never wait on a background-job notification for a verdict you need"); this is
#   the manager-side net for the cases that slip through it.
#
# WHAT ONE TICK DOES, per pre-check log the project names (`workers.verdictLogs` globs in
# .autocoder.json, AUTOCODER_VERDICT_LOGS, or --logs):
#   1. Reads the issue number from the log's name (--issue-regex: the first run of three or
#      more digits), and keeps only the NEWEST log of each issue (an older log is superseded).
#   2. Reads the verdict: the last line matching --pattern (default: `^=== (prebank|pre-check|
#      pre-gate-check)[^:]*: (PASS|FAIL)`), its FIRST PASS or FAIL token (the rest of the line
#      may name the other word), timed by the log's mtime (the verdict line is the run's last write). No such line: the run is RUNNING while some process still
#      holds the log open, and DEAD once none does and the log is older than --dead-min.
#   3. Finds the worker: the git worktree whose checked-out branch names the issue
#      (`issue-N`, `issue/N`, or a leading `N-`), then that worktree's pane in the swarm
#      manifest (.autocoder/swarm/*.json: tmuxTarget, cmuxWorkspace or herdrPane by mux).
#   4. Decides whether the worker SAW the verdict: a tracker comment on the issue after the
#      verdict that is a READY (--ready-regex, the queue's own rule), or any comment or commit
#      on the worktree after it (the worker acted), counts as seen.
#   5. A verdict older than --stale-min that nobody saw, on a pane `worker-idle` calls IDLE,
#      is an UNREAD verdict: the pane is sent the verdict and the log path (--nudge-text), once
#      per log per --cooldown. A DEAD run is nudged the same way, to re-run in the foreground.
#      A BUSY pane, a RUNNING log, a fresh verdict, a seen one, a cooldown, or a missing
#      worktree or pane is a row that says why, never a send.
#   6. Records lifecycle events (issue-events-lib.sh): `verdict` the first time a log's verdict
#      is seen (detail: verdict, at, log; only for an issue a worktree of this repository checks
#      out, since a shared host holds other swarms' logs too) and `verdict-nudged` on each send
#      (detail: verdict, idle_s, log), so the weekly report (landing-report.py) can count worker
#      minutes idle after a verdict and the nudges it took.
#
# Usage:
#   worker-verdict-watchdog.sh [--once]     one tick (the default; the manager's cron or loop)
#   worker-verdict-watchdog.sh --loop       tick forever, sleeping --interval (default 120)
#   worker-verdict-watchdog.sh --dry-run    say what a tick WOULD send; no sends, no state, no events
#   worker-verdict-watchdog.sh --json       the rows as a JSON array (one object per judged log)
#   Options: --repo DIR (default: this checkout's main worktree), --logs GLOB (repeatable),
#            --pattern RE, --issue-regex RE, --ready-regex RE, --stale-min N (10),
#            --dead-min N (15), --cooldown N (seconds, 1800), --mux tmux|cmux|herdr
#
# Environment:
#   AUTOCODER_VERDICT_LOGS       space-separated log globs (below the config, above nothing)
#   AUTOCODER_VERDICT_PATTERN    the verdict line regex
#   AUTOCODER_VERDICT_NUDGE_TEXT the nudge; `{issue} {verdict} {log} {at}` are filled in
#   AUTOCODER_WORKER_IDLE        the idle probe (default: worker-idle.sh beside this script)
#   VERDICT_WATCHDOG_STATE_DIR   default ${XDG_STATE_HOME:-~/.local/state}/autocoder/verdict-watchdog
#
# Exit status: 0 on a completed tick (nudges or not); 2 on bad usage or an unreadable repo.
# Read-mostly: the only writes are the sends, the cooldown files and the ledger events.

set -u

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  SOURCE_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
  SOURCE_PATH="$(readlink "$SOURCE_PATH")"
  [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
# shellcheck source=mux-send-lib.sh
source "$SCRIPT_DIR/mux-send-lib.sh"

usage() { sed -n '2,/^set -u$/p' "$SOURCE_PATH" | sed '$d' | sed 's/^# \{0,1\}//'; }
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "worker-verdict-watchdog: $*" >&2; exit 2; }

MODE=once; DRY=false; JSON=false; INTERVAL=120
REPO=""; LOG_GLOBS=(); PATTERN=""; ISSUE_RE='[0-9]{3,}'; MUX="${AUTOCODER_MUX:-}"
READY_RE='^\W*(\[[^\]]*\]\s*)?(\w+:\s*)?READY\b'
STALE_MIN=""; DEAD_MIN=""; COOLDOWN="${VERDICT_WATCHDOG_COOLDOWN:-1800}"
while [ $# -gt 0 ]; do
  case "$1" in
    --once) MODE=once; shift ;;
    --loop) MODE=loop; shift ;;
    --dry-run) DRY=true; shift ;;
    --json) JSON=true; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --logs) LOG_GLOBS+=("$2"); shift 2 ;;
    --pattern) PATTERN="$2"; shift 2 ;;
    --issue-regex) ISSUE_RE="$2"; shift 2 ;;
    --ready-regex) READY_RE="$2"; shift 2 ;;
    --stale-min) STALE_MIN="$2"; shift 2 ;;
    --dead-min) DEAD_MIN="$2"; shift 2 ;;
    --cooldown) COOLDOWN="$2"; shift 2 ;;
    --mux) MUX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1' (--help lists them)" ;;
  esac
done

# ── The repository and its configuration ────────────────────────────────────
if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && REPO="$(dirname "$REPO")"
  [ -n "$REPO" ] && [ -d "$REPO" ] || die "not inside a git checkout; name the repository with --repo DIR"
fi
REPO="$(cd "$REPO" && pwd -P)" || die "cannot enter --repo $REPO"
[ -f "$REPO/.git" ] || [ -d "$REPO/.git" ] || die "--repo $REPO is not a git checkout"

config_value() { # config_value <json-expression over d> <default>
  python3 - "$REPO/.autocoder.json" "$1" "$2" <<'PY' 2>/dev/null
import json, sys
path, expr, default = sys.argv[1:]
try:
    d = json.load(open(path))
except Exception:
    print(default); sys.exit(0)
try:
    v = eval(expr, {"__builtins__": {}}, {"d": d})
except Exception:
    v = None
if v is None:
    print(default)
elif isinstance(v, list):
    print(" ".join(str(x) for x in v))
else:
    print(v)
PY
}
if [ ${#LOG_GLOBS[@]} -eq 0 ]; then
  globs="${AUTOCODER_VERDICT_LOGS:-$(config_value 'd["workers"]["verdictLogs"]' '')}"
  # shellcheck disable=SC2206  # the globs are split on spaces by design; they expand later
  LOG_GLOBS=($globs)
fi
[ ${#LOG_GLOBS[@]} -gt 0 ] || die "no pre-check logs named: set workers.verdictLogs in $REPO/.autocoder.json, AUTOCODER_VERDICT_LOGS, or --logs GLOB (#7134)"
[ -n "$PATTERN" ] || PATTERN="${AUTOCODER_VERDICT_PATTERN:-$(config_value 'd["workers"]["verdictPattern"]' '^=== (prebank|pre-check|pre-gate-check)[^:]*: (PASS|FAIL)')}"
[ -n "$STALE_MIN" ] || STALE_MIN="$(config_value 'd["workers"]["verdictStaleMin"]' 10)"
[ -n "$DEAD_MIN" ] || DEAD_MIN="$(config_value 'd["workers"]["verdictDeadMin"]' 15)"
[[ "$STALE_MIN" =~ ^[0-9]+$ ]] && [[ "$DEAD_MIN" =~ ^[0-9]+$ ]] && [[ "$COOLDOWN" =~ ^[0-9]+$ ]] || die "--stale-min, --dead-min and --cooldown take whole numbers"
WORKER_IDLE="${AUTOCODER_WORKER_IDLE:-$SCRIPT_DIR/worker-idle.sh}"
STATE_DIR="${VERDICT_WATCHDOG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/verdict-watchdog}"
# The defaults are assigned first: a `}` inside a `${var:-default}` would end the expansion at `#{issue}`.
DEFAULT_NUDGE_TEXT='Your background pre-check for #{issue} finished at {at} with {verdict} ({log}): read its block and continue. PASS: push the branch and post the READY with the block. FAIL: fix what it names and re-run. Do not wait on a background-job notification for a verdict: run the pre-check in the foreground within your tool'"'"'s ceiling, or poll the log'"'"'s verdict line on a timer (#7134).'
DEFAULT_DEAD_TEXT='Your background pre-check for #{issue} ({log}) stopped at {at} with no verdict and no live process: re-run it in the foreground (or poll its verdict line on a timer) and continue (#7134).'
NUDGE_TEXT="${AUTOCODER_VERDICT_NUDGE_TEXT:-$DEFAULT_NUDGE_TEXT}"
DEAD_TEXT="${AUTOCODER_VERDICT_DEAD_TEXT:-$DEFAULT_DEAD_TEXT}"

if [ -z "$MUX" ]; then
  if [ -n "${AUTOCODER_TMUX_SOCKET:-}" ] || [ -n "${TMUX:-}" ]; then MUX=tmux
  elif herdr_is_running 2>/dev/null; then MUX=herdr
  elif cmux_is_running 2>/dev/null; then MUX=cmux
  else MUX=tmux; fi
fi

# The tracker and the lifecycle ledger: issue_get for the READY check, issue_event for the rows the
# report reads. Sourced from the repository root so the backend is the project's (.autocoder.json).
cd "$REPO" || die "cannot enter $REPO"
# shellcheck source=issue-fns.sh
source "$SCRIPT_DIR/issue-fns.sh" 2>/dev/null || die "cannot source issue-fns.sh beside this script"

# ── Helpers ─────────────────────────────────────────────────────────────────
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
iso_of() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
log_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }

# Is any process holding the log open? fuser where it exists, else a /proc scan.
log_in_use() {
  local f="$1" p
  if command -v fuser >/dev/null 2>&1; then fuser -s "$f" 2>/dev/null; return; fi
  for p in /proc/[0-9]*/fd/*; do [ "$(readlink "$p" 2>/dev/null)" = "$f" ] && return 0; done
  return 1
}

# The worktrees of the repository: "<path>\t<branch>" per line (the branch empty when detached).
list_worktrees() {
  git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '
    /^worktree /{p=substr($0,10)} /^branch /{b=substr($0,8); sub("^refs/heads/","",b)}
    /^$/{if(p!=""){print p "\t" b}; p=""; b=""} END{if(p!="")print p "\t" b}'
}
worktree_of_issue() { # prints the worktree path whose branch names the issue, else nothing
  local n="$1" path branch
  while IFS=$'\t' read -r path branch; do
    [ -n "$branch" ] || continue
    if [[ "$branch" =~ (^|[^0-9])issue[-/]?${n}([^0-9]|$) ]] || [[ "$branch" =~ (^|/)${n}-[^/]*$ ]]; then printf '%s\n' "$path"; return 0; fi
  done < <(list_worktrees)
  return 1
}
pane_of_worktree() { # the worker's pane for this mux, from any swarm manifest of the repository
  local wt="$1" f
  for f in "$REPO"/.autocoder/swarm/*.json; do
    [ -f "$f" ] || continue
    python3 - "$f" "$wt" "$MUX" <<'PY' 2>/dev/null && return 0
import json, os, sys
path, wt, mux = sys.argv[1:]
key = {"tmux": "tmuxTarget", "cmux": "cmuxWorkspace", "herdr": "herdrPane"}.get(mux, "tmuxTarget")
d = json.load(open(path))
for w in d.get("workers", []):
    if os.path.realpath(str(w.get("worktree") or "")) == os.path.realpath(wt) and w.get(key):
        print(w[key]); sys.exit(0)
sys.exit(1)
PY
  done
  return 1
}
# Did anyone act on the issue after the verdict? A READY comment after it, any comment after it, or a
# commit on the worktree after it. Prints the reason, exit 0 = seen.
seen_since() { # seen_since <issue> <epoch> <worktree-or-empty>
  local n="$1" at="$2" wt="$3" json head_ts
  if [ -n "$wt" ]; then
    head_ts="$(git -C "$wt" log -1 --format=%ct 2>/dev/null || echo 0)"
    if [ "${head_ts:-0}" -gt "$at" ]; then echo "commit after the verdict"; return 0; fi
  fi
  json="$(issue_get "$n" 2>/dev/null)" || { echo "tracker unreadable"; return 1; }
  ISSUE_JSON="$json" python3 - "$at" "$READY_RE" <<'PY'
import datetime, json, os, re, sys
at = int(sys.argv[1]); ready = re.compile(sys.argv[2])
try:
    d = json.loads(os.environ["ISSUE_JSON"])
except Exception:
    print("tracker unreadable"); sys.exit(1)
def ts(s):
    try:
        return int(datetime.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception:
        return 0
later = [c for c in d.get("comments") or [] if ts(str(c.get("createdAt") or c.get("created_at") or "")) > at]
# The file backend folds comments into the body as `> **YYYY-MM-DD HH:MM** text` blockquotes.
for m in re.finditer(r"^> \*\*(\d{4}-\d\d-\d\d) (\d\d:\d\d)\*\* (.*)$", str(d.get("body") or ""), re.M):
    if ts(f"{m.group(1)}T{m.group(2)}:00") > at:
        later.append({"body": m.group(3)})
if any(ready.search(str(c.get("body") or "")) for c in later):
    print("READY posted after the verdict"); sys.exit(0)
if later:
    print("comment after the verdict"); sys.exit(0)
print("no READY, comment or commit since the verdict"); sys.exit(1)
PY
}
pane_idle() { # 0 idle, 1 busy, 2 unknown
  "$WORKER_IDLE" --pane "$1" ${MUX:+--mux "$MUX"} >/dev/null 2>&1
  case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}
in_cooldown() {
  local f="$STATE_DIR/nudged-$(log_key "$1")" last
  [ -f "$f" ] || return 1
  last=$(cat "$f" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - last )) -lt "$COOLDOWN" ]
}
mark_nudged() { date +%s > "$STATE_DIR/nudged-$(log_key "$1")"; }
record_verdict_once() { # one `verdict` event per log and mtime
  local n="$1" verdict="$2" f="$3" at="$4" wt="$5" marker
  marker="$STATE_DIR/seen-$(log_key "$f")-$at"
  [ -f "$marker" ] && return 0
  : > "$marker"
  AUTOCODER_WORKER="${wt:+$(basename "$wt")}" AUTOCODER_EVENT_BRANCH="$(git -C "${wt:-$REPO}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" \
    issue_event verdict "$n" verdict="$verdict" at="$(iso_of "$at")" log="$f" || true
}
fill() { # fill <template> <issue> <verdict> <log> <at>: the placeholders are quoted so braces stay literal
  local t="$1" k_issue='{issue}' k_verdict='{verdict}' k_log='{log}' k_at='{at}'
  t="${t//"$k_issue"/$2}"; t="${t//"$k_verdict"/$3}"; t="${t//"$k_log"/$4}"; t="${t//"$k_at"/$5}"
  printf '%s' "$t"
}

ROWS=()
row() { # row <issue> <verdict> <age-min> <worktree> <pane> <seen> <idle> <action> <detail>
  ROWS+=("$(python3 -c 'import json,sys; print(json.dumps(dict(zip(["issue","verdict","age_min","worktree","pane","seen","pane_idle","action","detail","log"], sys.argv[1:]))))' "$@")")
  [ "$JSON" = true ] || log "#$1 $2 ${3}m wt=${4:-none} pane=${5:-none} seen=$6 idle=$7 -> $8${9:+ ($9)}"
}

# ── One tick ─────────────────────────────────────────────────────────────────
tick() {
  local now f files=() n mtime age verdict wt pane seen idle msg at
  [ "$DRY" = true ] || mkdir -p "$STATE_DIR"
  now=$(date +%s)
  local g
  for g in "${LOG_GLOBS[@]}"; do for f in $g; do [ -f "$f" ] && files+=("$f"); done; done
  if [ ${#files[@]} -eq 0 ]; then [ "$JSON" = true ] || log "OK no pre-check log matches ${LOG_GLOBS[*]}"; return 0; fi
  # Newest first; the first log seen for an issue is its current run, the rest are superseded
  # (bash 3 has no associative arrays, so the map is "<issue>\t<log>" lines).
  local newest="" taken=" "
  while IFS= read -r f; do
    n="$(basename "$f" | grep -oE "$ISSUE_RE" | head -1)"
    [ -n "$n" ] || continue
    case "$taken" in *" $n "*) continue ;; esac
    taken="$taken$n "; newest="$newest$n	$f
"
  done < <(for f in "${files[@]}"; do printf '%s\t%s\n' "$(file_mtime "$f")" "$f"; done | sort -rn | cut -f2-)
  while IFS=$'\t' read -r n f; do
    [ -n "$n" ] || continue
    mtime="$(file_mtime "$f")"; age=$(( (now - mtime) / 60 )); at="$(iso_of "$mtime")"
    # The FIRST PASS|FAIL token of the last matching line: the verdict follows the prefix the pattern
    # anchors, and the rest of the line may name the other word (a FAIL line that says "paste the PASS block").
    verdict="$(grep -E "$PATTERN" "$f" 2>/dev/null | tail -1 | grep -oE 'PASS|FAIL' | head -1)"
    wt="$(worktree_of_issue "$n" || true)"
    pane=""; [ -n "$wt" ] && pane="$(pane_of_worktree "$wt" || true)"
    if [ -z "$verdict" ]; then
      if log_in_use "$f"; then row "$n" RUNNING "$age" "$wt" "$pane" - - WAIT "a process holds the log open" "$f"; continue; fi
      if [ "$age" -lt "$DEAD_MIN" ]; then row "$n" none "$age" "$wt" "$pane" - - WAIT "no verdict yet; dead after ${DEAD_MIN}m without a holder" "$f"; continue; fi
      verdict=DEAD; msg="$(fill "$DEAD_TEXT" "$n" DEAD "$f" "$at")"
    else
      # Recorded only for an issue a worktree of this repository checks out: a host shared with another
      # swarm holds that swarm's logs too, and their issue numbers are not this report's.
      [ "$DRY" = true ] || [ -z "$wt" ] || record_verdict_once "$n" "$verdict" "$f" "$mtime" "$wt"
      if [ "$age" -lt "$STALE_MIN" ]; then row "$n" "$verdict" "$age" "$wt" "$pane" - - WAIT "fresh; unread after ${STALE_MIN}m" "$f"; continue; fi
      msg="$(fill "$NUDGE_TEXT" "$n" "$verdict" "$f" "$at")"
    fi
    if seen="$(seen_since "$n" "$mtime" "$wt")"; then row "$n" "$verdict" "$age" "$wt" "$pane" yes - SEEN "$seen" "$f"; continue; fi
    [ -n "$wt" ] || { row "$n" "$verdict" "$age" "" "" no - REPORT "no worktree checks out a branch naming #$n" "$f"; continue; }
    [ -n "$pane" ] || { row "$n" "$verdict" "$age" "$wt" "" no - REPORT "no $MUX pane for $wt in $REPO/.autocoder/swarm/*.json" "$f"; continue; }
    pane_idle "$pane"; case $? in
      1) row "$n" "$verdict" "$age" "$wt" "$pane" no no BUSY "the pane is working; it will read the log" "$f"; continue ;;
      2) row "$n" "$verdict" "$age" "$wt" "$pane" no unknown REPORT "worker-idle could not probe the pane" "$f"; continue ;;
    esac
    if in_cooldown "$f"; then row "$n" "$verdict" "$age" "$wt" "$pane" no yes COOLDOWN "nudged within the last ${COOLDOWN}s" "$f"; continue; fi
    if [ "$DRY" = true ]; then row "$n" "$verdict" "$age" "$wt" "$pane" no yes DRY-RUN "would send: $msg" "$f"; continue; fi
    if send_agent_prompt "$MUX" "$pane" "$msg"; then
      mark_nudged "$f"
      AUTOCODER_WORKER="$(basename "$wt")" AUTOCODER_EVENT_BRANCH="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" \
        issue_event verdict-nudged "$n" verdict="$verdict" idle_s="$(( now - mtime ))" log="$f" pane="$pane" || true
      row "$n" "$verdict" "$age" "$wt" "$pane" no yes NUDGED "sent to $pane" "$f"
    else
      row "$n" "$verdict" "$age" "$wt" "$pane" no yes SEND-FAILED "send_agent_prompt returned $? (a consent dialog, or the pane is gone)" "$f"
    fi
  done < <(printf '%s' "$newest" | sort -n)
  return 0
}

run_tick() {
  ROWS=()
  tick
  if [ "$JSON" = true ]; then
    printf '[%s]\n' "$(IFS=,; printf '%s' "${ROWS[*]}")"
  fi
}

case "$MODE" in
  once) run_tick ;;
  loop) while :; do run_tick; sleep "$INTERVAL"; done ;;
esac
