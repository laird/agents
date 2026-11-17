#!/usr/bin/env bash
# flaky-report.sh — list the tests the merge gate has seen flaky (#191).
#
# The gate records a "flaky" line in merge-events.jsonl (merge-events-lib.sh) whenever a
# test fails on a tree and then passes on the same tree. This groups those lines by
# <repo, test> so a worker can file and fix the flakiest tests first.
#
# Usage: flaky-report.sh [--days N] [--repo ID] [--json]
#   --days N   only sightings from the last N days (default 14)
#   --repo ID  only this repo id (as recorded; see repo-id-fns.sh)
#   --json     one JSON object per test instead of a table
#
# Reads ${AUTOCODER_MERGE_EVENTS:-${XDG_STATE_HOME:-$HOME/.local/state}/autocoder/merge-events.jsonl}.
# Exit status: 0 (also when there are no sightings), 2 on a usage error.

DAYS=14 REPO="" JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days|--repo)
      [ $# -ge 2 ] || { echo "flaky-report: $1 needs a value" >&2; exit 2; }
      if [ "$1" = --days ]; then DAYS="$2"; else REPO="$2"; fi
      shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "flaky-report: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$DAYS" in ''|*[!0-9]*) echo "flaky-report: --days takes a whole number" >&2; exit 2 ;; esac

# shellcheck source=merge-events-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/merge-events-lib.sh"
python3 - "$(merge_events_file)" "$DAYS" "$REPO" "$JSON" <<'PY'
import datetime, json, sys
path, days, repo, as_json = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4] == "1"
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
tests = {}
try:
    fh = open(path)
except OSError:
    fh = []
for line in fh:
    try:
        e = json.loads(line)
        if e.get("event") != "flaky":
            continue
        ts = datetime.datetime.strptime(e["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except Exception:
        continue
    if ts < cutoff or (repo and e.get("repo") != repo):
        continue
    key = (e.get("repo") or "", e.get("test") or "(whole gate)")
    t = tests.setdefault(key, {"repo": key[0], "test": key[1], "sightings": 0,
                               "last_seen": "", "issues": set(), "last_excerpt": ""})
    t["sightings"] += 1
    if e["ts"] >= t["last_seen"]:
        t["last_seen"], t["last_excerpt"] = e["ts"], e.get("first_failure_excerpt") or ""
    if e.get("issue") is not None:
        t["issues"].add(e["issue"])
# Most sightings first; among ties, the most recently seen first.
rows = sorted(tests.values(), key=lambda t: t["last_seen"], reverse=True)
rows.sort(key=lambda t: -t["sightings"])
if as_json:
    for t in rows:
        t["issues"] = sorted(t["issues"])
        print(json.dumps(t, separators=(",", ":")))
    sys.exit(0)
if not rows:
    print(f"No flaky tests seen in the last {days} day(s).")
    sys.exit(0)
print(f"Flaky tests seen in the last {days} day(s) (same tree failed, then passed):")
print(f"{'SIGHTINGS':>9}  {'LAST SEEN':20}  {'REPO':24}  TEST  (issues)")
def clean(x):  # test names come from test output: no terminal control characters
    return "".join(c if c.isprintable() else "?" for c in str(x))
for t in rows:
    issues = ", ".join(f"#{i}" for i in sorted(t["issues"]))
    print(f"{t['sightings']:>9}  {t['last_seen']:20}  {clean(t['repo'])[:24]:24}  {clean(t['test'])}" + (f"  ({issues})" if issues else ""))
PY
