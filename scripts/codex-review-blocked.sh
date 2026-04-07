#!/bin/bash
# Review blocked issues without spawning a nested sandboxed Codex session.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel)

LOCAL_FETCH_SCRIPT="$REPO_ROOT/plugins/autocoder/scripts/fetch-blocked-issues.sh"
SHARED_FETCH_SCRIPT="$SCRIPT_DIR/../plugins/autocoder/scripts/fetch-blocked-issues.sh"

if [ -x "$LOCAL_FETCH_SCRIPT" ]; then
  FETCH_SCRIPT="$LOCAL_FETCH_SCRIPT"
elif [ -x "$SHARED_FETCH_SCRIPT" ]; then
  FETCH_SCRIPT="$SHARED_FETCH_SCRIPT"
else
  echo "❌ Could not find fetch-blocked-issues.sh in repo-local or shared runtime paths" >&2
  exit 1
fi

TMP_JSON=$(mktemp)
"$FETCH_SCRIPT" > "$TMP_JSON"

python3 - "$TMP_JSON" <<'PYTHON_SCRIPT'
import json
import sys
from collections import Counter

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

issues = data.get("issues", [])
summary = data.get("summary", {})
total = data.get("total", len(issues))

print("== Codex Blocked Issue Review ==")
print(f"Total blocked issues: {total}")

priority_counts = Counter()
for issue in issues:
    labels = {label["name"] for label in issue.get("labels", [])}
    for priority in ("P0", "P1", "P2", "P3"):
        if priority in labels:
            priority_counts[priority] += 1
            break
    else:
        priority_counts["unprioritized"] += 1

if total:
    print("By priority:")
    for key in ("P0", "P1", "P2", "P3", "unprioritized"):
        if priority_counts.get(key):
            print(f"  {key}: {priority_counts[key]}")

blocking_order = ["needs-approval", "needs-design", "needs-clarification", "too-complex", "future", "proposal"]
print("By blocking label:")
for label in blocking_order:
    bucket = summary.get(label, {})
    label_total = sum(bucket.values())
    if not label_total:
        continue
    breakdown = ", ".join(f"{priority}: {count}" for priority, count in bucket.items())
    print(f"  {label}: {label_total} ({breakdown})")

rank = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}

def sort_key(issue):
    labels = {label["name"] for label in issue.get("labels", [])}
    priority = min((rank[p] for p in rank if p in labels), default=9)
    blocking = next((label for label in blocking_order if label in labels), "zzz")
    return (priority, blocking, issue.get("number", 0))

top_issues = sorted(issues, key=sort_key)[:3]
if top_issues:
    print("Recommended next reviews:")
    for issue in top_issues:
        labels = {label["name"] for label in issue.get("labels", [])}
        priority = next((p for p in ("P0", "P1", "P2", "P3") if p in labels), "unprioritized")
        blocking = next((label for label in blocking_order if label in labels), "blocked")
        print(f"  #{issue['number']} [{priority}, {blocking}] {issue['title']}")
PYTHON_SCRIPT

rm -f "$TMP_JSON"
