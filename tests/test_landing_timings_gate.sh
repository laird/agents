#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255
# tests/test_landing_timings_gate.sh — merge-to-integration.sh appends landing-timings rows (#7011):
# a landing gives a green batch of one plus batched and landed; a gate that fails only on the
# change gives a red batch (cause defect) and a returned change; a red integration branch gives a
# red batch (cause red-integration), the change landing or coming back by the red-base setting.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AUTOCODER_SPOT_CHECK_RATE=0 ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export AUTOCODER_LANDING_TIMINGS="$TMP/landing.jsonl"
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE
mkdir -p "$TMP/issues"/{open,working,blocked,closed}

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email t@example.com; git config user.name T
git remote add origin "$TMP/origin.git"
echo base > README.md; git add -A; git commit -q -m init; git branch -M master; git push -q origin master master:master-green

source "$SCRIPT_DIR/repo-id-fns.sh"
run_one() {  # <issue> <file to add> <test-cmd>: one detached attempt, waited to completion
  local issue="$1" file="$2" cmd="$3" state
  printf -- '---\nnumber: %s\ntitle: T\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$issue" > "$TMP/issues/open/${issue}.md"
  python3 "$ISSUES_PY" claim "$issue" >/dev/null
  git checkout -q -b "feature/i$issue" master
  echo x > "$file"; git add -A; git commit -q -m "fix #$issue"; git push -q origin "feature/i$issue"
  state="$AUTOCODER_TMP/autocoder-merge-$(autocoder_repo_id "$TMP/worker")-${issue}"
  bash "$SCRIPT_DIR/merge-launch.sh" --feature "feature/i$issue" --issue "$issue" --integration master \
    --test-cmd "$cmd" --own-issue >/dev/null 2>&1 || { bad "launch $issue failed"; return 1; }
  for _ in $(seq 1 120); do [ -s "${state}.exit" ] && break; sleep 0.5; done
  git checkout -q master; git pull -q origin master
}
rows() {  # <issue>: "kind event|verdict cause" lines for that issue
  python3 - "$AUTOCODER_LANDING_TIMINGS" "$1" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l); n = int(sys.argv[2])
    if r["kind"] == "change" and r["issue"] == n:
        print("change", r["event"], r["cause"] or "-")
    if r["kind"] == "batch" and n in r["members"]:
        print("batch", r["verdict"], r["cause"] or "-", "gate" if r["gate_s"] is not None else "nogate")
PY
}

run_one 7101 src_ok.txt true
eq "landing: green batch, batched, landed" "batch green - gate
change batched -
change landed -" "$(rows 7101)"

run_one 7102 bad.txt 'test ! -f bad.txt'
eq "change-only failure: red batch, defect, returned" "batch red defect gate
change batched -
change returned defect" "$(rows 7102)"

run_one 7103 other.txt false
eq "red base, landed anyway: red batch (red-integration), landed" "batch red red-integration gate
change batched -
change landed -" "$(rows 7103)"

AUTOCODER_MERGE_ON_RED_BASE=0 run_one 7104 more.txt false
eq "red base, refused: red batch (red-integration), returned" "batch red red-integration gate
change batched -
change returned red-integration" "$(rows 7104)"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
