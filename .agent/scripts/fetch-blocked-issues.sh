#!/bin/bash
# Fetch all blocked issues with filtering options
# Usage: fetch-blocked-issues.sh [--label LABEL] [--priority PRIORITY] [issue_number]

set -e

FILTER_LABEL=""
FILTER_PRIORITY=""
ISSUE_NUMBER=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --label)
      FILTER_LABEL="$2"
      shift 2
      ;;
    --priority)
      FILTER_PRIORITY="$2"
      shift 2
      ;;
    [0-9]*)
      ISSUE_NUMBER="$1"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Ensure blocking labels exist
EXISTING_LABELS=$(gh label list --json name --jq '.[].name' 2>/dev/null || echo "")

for label in "needs-approval:Architectural decisions, major changes, security implications:e99695" "needs-design:Requirements unclear, multiple approaches, needs design:fbca04" "needs-clarification:Incomplete information, missing context, questions needed:d4c5f9" "too-complex:Beyond autonomous capability, requires deep expertise:b60205"; do
  IFS=':' read -r name desc color <<< "$label"
  if ! echo "$EXISTING_LABELS" | grep -qFx "$name"; then
    gh label create "$name" --description "$desc" --color "$color" 2>/dev/null || true
  fi
done

# Fetch all open issues
gh issue list --state open --json number,title,labels,body,comments --limit 200 > /tmp/all-issues.json

# Filter and process blocked issues
python3 << 'PYTHON_SCRIPT'
import json
import sys
import os

with open('/tmp/all-issues.json') as f:
    issues = json.load(f)

blocking_labels = ['needs-approval', 'needs-design', 'needs-clarification', 'too-complex']
priorities = ['P0', 'P1', 'P2', 'P3']

# Filter to blocked issues only
blocked = [i for i in issues
          if any(l['name'] in blocking_labels for l in i.get('labels', []))]

# Apply command-line filters
filter_label = os.environ.get('FILTER_LABEL', '')
filter_priority = os.environ.get('FILTER_PRIORITY', '')
issue_number = os.environ.get('ISSUE_NUMBER', '')

if issue_number:
    blocked = [i for i in blocked if str(i['number']) == issue_number]
elif filter_label:
    blocked = [i for i in blocked
              if any(l['name'] == filter_label for l in i.get('labels', []))]
    if filter_priority:
        blocked = [i for i in blocked
                  if any(l['name'] == filter_priority for l in i.get('labels', []))]
elif filter_priority:
    blocked = [i for i in blocked
              if any(l['name'] == filter_priority for l in i.get('labels', []))]

# Group by blocking label and priority for summary
summary = {}
for label in blocking_labels:
    summary[label] = {}
    for priority in priorities:
        count = len([i for i in blocked
                    if any(l['name'] == label for l in i.get('labels', []))
                    and any(l['name'] == priority for l in i.get('labels', []))])
        if count > 0:
            summary[label][priority] = count

# Sort blocked issues by priority (P0 > P1 > P2 > P3)
def priority_sort_key(issue):
    labels = [l['name'] for l in issue.get('labels', [])]
    if 'P0' in labels: return 0
    if 'P1' in labels: return 1
    if 'P2' in labels: return 2
    if 'P3' in labels: return 3
    return 4

blocked_sorted = sorted(blocked, key=priority_sort_key)

# Output JSON
result = {
    'summary': summary,
    'issues': blocked_sorted,
    'total': len(blocked_sorted)
}

print(json.dumps(result, indent=2))
PYTHON_SCRIPT

# Export environment variables for Python script
export FILTER_LABEL
export FILTER_PRIORITY
export ISSUE_NUMBER
