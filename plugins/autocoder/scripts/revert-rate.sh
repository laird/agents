#!/usr/bin/env bash
# revert-rate.sh — the share of landed issues the sentinel had to revert (#250, #168).
#
# A revert counts only when its commit carries the sentinel's `Autocoder-Reverts:` trailer
# (main-sentinel.sh make_revert). A commit whose message merely says "revert" is not one.
# A landed issue is a non-merge commit whose subject starts with the issue number:
# `#N: ...`, `#N review ...`, `Issue #N: ...` (merge-to-integration.sh squash) or the old
# `Fix #N: ...`. Several commits for one issue count once.
#
# Usage: revert-rate.sh [--last N | --since DATE] [--ref REV] [--json]
#   --last N     the window is the newest N landed issues (default 50)
#   --since DATE the window is every commit since DATE (anything `git log --since` takes)
#   --ref REV    history to read (default origin/HEAD, else HEAD)
#   --json       {window, landed, reverts, rate, reverted_issues} instead of one line
#
# With --last, a revert counts only if the issue it names is one of the N. With --since,
# every sentinel revert made in the window counts, even of an issue that landed before
# it, so the rate can exceed 1. rate is reverts / landed, or null when nothing landed.
# Exit status: 0, 1 when the history cannot be read, 2 on a usage error.

LAST="" SINCE="" REF="" JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --last|--since|--ref)
      [ $# -ge 2 ] || { echo "revert-rate: $1 needs a value" >&2; exit 2; }
      case "$1" in --last) LAST="$2" ;; --since) SINCE="$2" ;; --ref) REF="$2" ;; esac
      shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "revert-rate: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -n "$LAST" ] && [ -n "$SINCE" ]; then
  echo "revert-rate: give --last or --since, not both" >&2; exit 2
fi
if [ -z "$SINCE" ]; then
  LAST="${LAST:-50}"
  case "$LAST" in ''|*[!0-9]*|0) echo "revert-rate: --last takes a positive whole number" >&2; exit 2 ;; esac
fi
if [ -z "$REF" ]; then
  if git rev-parse -q --verify origin/HEAD >/dev/null 2>&1; then REF=origin/HEAD; else REF=HEAD; fi
fi
case "$REF" in -*) echo "revert-rate: --ref must name a revision" >&2; exit 2 ;; esac
git rev-parse -q --verify "${REF}^{commit}" >/dev/null 2>&1 \
  || { echo "revert-rate: cannot read revision '$REF'" >&2; exit 1; }

LOG_ARGS=(log --no-merges
  --format='%H%x1f%s%x1f%(trailers:key=Autocoder-Reverts,valueonly,separator=%x1d)%x1f%(trailers:key=Autocoder-Reverts-Issue,valueonly,separator=%x1d)%x1e')
[ -n "$SINCE" ] && LOG_ARGS+=("--since=$SINCE")
LOG=$(git "${LOG_ARGS[@]}" "$REF" --) || { echo "revert-rate: git log failed on '$REF'" >&2; exit 1; }

printf '%s' "$LOG" | python3 -c '
import json, re, sys
last, since, ref, as_json = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
limit = int(last) if last else None
issue_re = re.compile(r"^(?:Fix |Issue )?#(\d+)\b")
landed = []
revert_at = []   # (position in the walk, reverted issue numbers) per sentinel revert
end = None       # position of the oldest commit of a window issue (None: whole walk)
for pos, rec in enumerate(sys.stdin.read().split("\x1e")):
    parts = rec.strip("\n").split("\x1f")
    if len(parts) != 4:
        continue
    _sha, subject, rev, rev_issue = parts
    if any(v.strip() for v in rev.split("\x1d")):
        nums = {int(v) for v in (x.strip().lstrip("#") for x in rev_issue.split("\x1d")) if v.isdigit()}
        revert_at.append((pos, nums))
        continue
    m = issue_re.match(subject)
    if not m:
        continue
    n = int(m.group(1))
    if n not in landed:
        if limit is not None and len(landed) == limit:
            break  # the (N+1)th issue: the window is full
        landed.append(n)
    end = pos
# With --last, a revert counts only when it is newer than the oldest issue commit in the window
# commit and, when it names its issue, that issue is one of the landed issues in the window:
# a revert of an older issue says nothing about the issues in the window.
if limit is not None:
    in_window = set(landed)
    revert_at = [r for r in revert_at
                 if end is not None and r[0] < end and (not r[1] or r[1] & in_window)]
reverts = len(revert_at)
reverted = set().union(*(r[1] for r in revert_at)) if revert_at else set()
window = {"ref": ref}
if limit is not None:
    window["last"] = limit
else:
    window["since"] = since
rate = round(reverts / len(landed), 4) if landed else None
out = {"window": window, "landed": len(landed), "reverts": reverts,
       "rate": rate, "reverted_issues": sorted(reverted)}
if as_json:
    print(json.dumps(out, separators=(",", ":")))
    sys.exit(0)
scope = f"newest {limit} landed issues" if limit is not None else f"since {since}"
pct = "n/a" if rate is None else f"{rate * 100:.1f}%"
line = f"Revert rate on {ref} ({scope}): {reverts} sentinel revert(s) / {len(landed)} landed issue(s) = {pct}"
if reverted:
    line += "; reverted: " + ", ".join(f"#{i}" for i in sorted(reverted))
print(line)
' "$LAST" "$SINCE" "$REF" "$JSON"
