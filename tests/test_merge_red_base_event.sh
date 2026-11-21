#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255
# tests/test_merge_red_base_event.sh — every "attempt" line in merge-events.jsonl carries
# red_base (#285): true when origin/<integration> failed alone on the same gate command,
# for both a red-base landing and a red-base refusal; false for a clean landing and for a
# failure this change caused (the base passes alone). A UI can then tell a refusal on a red
# base from a change that broke the gate without parsing the free-text reason.

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
export AUTOCODER_MERGE_EVENTS="$TMP/events.jsonl"
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE
mkdir -p "$TMP/issues"/{open,working,blocked,closed}

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email t@example.com; git config user.name T
git remote add origin "$TMP/origin.git"
# master-green exists, so a red base may land (the default once a sentinel proved green).
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
attempt() {  # <issue>: "<outcome> red_base=<json value>" for that issue's attempt line
  python3 - "$AUTOCODER_MERGE_EVENTS" "$1" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["event"] == "attempt" and e["issue"] == int(sys.argv[2]):
        print(e["outcome"], "red_base=" + json.dumps(e.get("red_base", "missing")))
PY
}

run_one 28501 ok.txt true
eq "clean landing: red_base false" "landed red_base=false" "$(attempt 28501)"

run_one 28502 bad.txt 'test ! -f bad.txt'
eq "change broke the gate (base passes alone): red_base false" "gate-failed red_base=false" "$(attempt 28502)"

run_one 28503 other.txt 'echo "FAIL shared"; false'
eq "red base, landed anyway (parked): red_base true" "parked red_base=true" "$(attempt 28503)"

AUTOCODER_MERGE_ON_RED_BASE=0 run_one 28504 more.txt 'echo "FAIL shared"; false'
case "$(attempt 28504)" in
  "gate-failed red_base=true"|"escalated red_base=true") ok "red base, refused: red_base true" ;;
  *) bad "red base, refused — got '$(attempt 28504)'" ;;
esac

python3 - "$AUTOCODER_MERGE_EVENTS" <<'PY' && ok "red_base is a JSON boolean on every attempt line and absent elsewhere" || bad "red_base typing: $(cat "$AUTOCODER_MERGE_EVENTS")"
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1])]
att = [e for e in evs if e["event"] == "attempt"]
sys.exit(0 if len(att) == 4 and all(isinstance(e["red_base"], bool) for e in att)
         and all("red_base" not in e for e in evs if e["event"] != "attempt") else 1)
PY

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
