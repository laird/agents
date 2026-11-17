#!/usr/bin/env bash
# merge-events-lib.sh — an append-only record of every merge attempt (#184).
#
# WHY THIS EXISTS:
#   Merge job files are per issue (<tmp-root>/autocoder-merge-<repo>-<issue>.{log,exit,pid}, under
#   autocoder_tmp_root),
#   and each relaunch overwrote them. On agents-ui 66 job files showed one conflict
#   while the issues themselves recorded 8 conflicts and 12 escalations: the history
#   of bounces, retries and conflicting files was gone, so nothing could measure it.
#
# FORMAT: one JSON object per line in
#   ${AUTOCODER_MERGE_EVENTS:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/merge-events.jsonl}
#   {"ts": "<ISO-8601 UTC>", "repo": "<repo id>", "issue": <n>, "branch": "<feature>",
#    "attempt": <n>, "event": "attempt"|"push-retry",
#    "outcome": "landed"|"parked"|"skipped"|"conflict"|"gate-failed"|"escalated"|"failed"|"push-retry",
#    "escalated": true|false, "files": [...], "gate_tests_failed": [...],
#    "duration_s": <n>, "landed": "<sha>"|null, "push_retries": <n>, "exit": <code>|null,
#    "reason": "<text>"}
#   One "attempt" line per merge job (its final outcome) plus one "push-retry" line per
#   rejected push. Documented for readers (agents-ui) in scripts/README.md.
#
# ROTATION: lines older than AUTOCODER_MERGE_EVENTS_DAYS (default 30) are dropped when
#   the file passes 1 MiB. Rotators serialise on a lock file; appenders do not take it, so
#   a line appended mid-rotation can be lost. That is acceptable for a best-effort log.
#
# Recording is best effort: a failure here never fails or delays a merge.

merge_events_file() {
  printf '%s\n' "${AUTOCODER_MERGE_EVENTS:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/merge-events.jsonl}"
}

# merge_event key=value ...  (files= and gate_tests_failed= take newline-separated lists)
merge_event() {
  local f
  f=$(merge_events_file)
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  python3 - "$f" "$@" <<'PY' 2>/dev/null || true
import json, os, sys, time, datetime
path, args = sys.argv[1], sys.argv[2:]
ev = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
lists = {"files", "gate_tests_failed"}
ints = {"issue", "attempt", "duration_s", "push_retries", "exit"}
for a in args:
    k, _, v = a.partition("=")
    if k in lists:
        ev[k] = sorted({x for x in v.splitlines() if x.strip()})
    elif k in ints:
        try:
            ev[k] = int(v)
        except ValueError:
            ev[k] = None
    elif k == "escalated":
        ev[k] = v in ("1", "true", "yes")
    else:
        ev[k] = v if v != "" else None
for k in ("files", "gate_tests_failed"):
    ev.setdefault(k, [])
ev.setdefault("escalated", False)
line = json.dumps(ev, separators=(",", ":")) + "\n"
# One write() of an O_APPEND line: concurrent jobs do not interleave.
# 0600 and O_NOFOLLOW: the log names branches, files and failure reasons.
fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
try:
    os.write(fd, line.encode())
finally:
    os.close(fd)
# Rotate rarely: only past 1 MiB, dropping lines older than the retention window.
if os.path.getsize(path) > 1 << 20:
    try:
        import fcntl
        lock = open(path + ".lock", "w")
        fcntl.flock(lock, fcntl.LOCK_EX)
    except Exception:
        lock = None
    days = int(os.environ.get("AUTOCODER_MERGE_EVENTS_DAYS", "30") or 30)
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
    tfd, tmp = tempfile.mkstemp(prefix=".merge-events.", dir=os.path.dirname(path) or ".")
    with os.fdopen(tfd, "w") as fh:
        fh.writelines(keep)
    os.replace(tmp, path)
PY
}
