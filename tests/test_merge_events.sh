#!/bin/bash
# tests/test_merge_events.sh — every merge attempt keeps its log and appends one
# structured event (#184).
#
# A relaunch for the same issue used to truncate the job log and drop its exit file,
# so the history of bounces, retries and conflicting files was lost. This drives the
# real detached launcher through two conflicting attempts and a landing, and expects
# three logs (two archived plus the current one) and three "attempt" events.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ISSUE=18401

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export AUTOCODER_MERGE_EVENTS="$TMP/events.jsonl"
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE

mkdir -p "$TMP/issues"/{open,working,blocked,closed}
printf -- '---\nnumber: %s\ntitle: Events\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$ISSUE" > "$TMP/issues/open/${ISSUE}.md"
python3 "$ISSUES_PY" claim "$ISSUE" >/dev/null

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email t@example.com; git config user.name T
git remote add origin "$TMP/origin.git"
echo base > README.md; mkdir -p src; echo base > src/a.sh; echo base > src/b.sh
git add -A; git commit -q -m init; git branch -M master; git push -q origin master master:master-green
git checkout -q -b feature/code master
echo change > src/a.sh; echo change > src/b.sh
git add -A; git commit -q -m fix; git push -q origin feature/code
git clone -q "$TMP/origin.git" "$TMP/sibling"
git -C "$TMP/sibling" config user.email s@example.com; git -C "$TMP/sibling" config user.name S
clash() { (cd "$TMP/sibling" && git pull -q origin master && for f in "$@"; do echo "sibling $RANDOM" > "$f"; done && git add -A && git commit -q -m clash && git push -q origin master); }

source "$SCRIPT_DIR/repo-id-fns.sh"
STATE="$AUTOCODER_TMP/autocoder-merge-$(autocoder_repo_id "$TMP/worker")-${ISSUE}"
launch() {  # one detached attempt, waited to completion
  bash "$SCRIPT_DIR/merge-launch.sh" --feature feature/code --issue "$ISSUE" --integration master \
    --test-cmd true --own-issue >/dev/null 2>&1 || { bad "launch failed"; return 1; }
  for _ in $(seq 1 120); do [ -s "${STATE}.exit" ] && return 0; sleep 0.5; done
  bad "attempt did not finish"; return 1
}
events() { python3 -c '
import json, sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["event"] == "attempt":
        print(e["attempt"], e["outcome"], ",".join(e["files"]))' "$AUTOCODER_MERGE_EVENTS" 2>/dev/null; }

# ── attempt 1: conflict on a and b ──────────────────────────────────────────
clash src/a.sh src/b.sh
launch
eq "attempt 1 exits 1" "1" "$(cat "${STATE}.exit" 2>/dev/null)"

# ── attempt 2: master moved again; the conflict is now on a only ────────────
(cd "$TMP/sibling" && git pull -q origin master && git checkout -q HEAD -- . )
git fetch -q origin
git rebase -q -X ours origin/master 2>/dev/null || { git checkout -q --ours . 2>/dev/null; git add -A; GIT_EDITOR=true git rebase --continue >/dev/null 2>&1; }
echo "change again" > src/a.sh; git commit -qam "fix again"; git push -qf origin feature/code
clash src/a.sh
launch
eq "attempt 2 exits 1" "1" "$(cat "${STATE}.exit" 2>/dev/null)"

# ── attempt 3: rebased cleanly onto master; lands ───────────────────────────
git fetch -q origin
git rebase -q -X theirs origin/master >/dev/null 2>&1 || { git checkout -q --theirs . ; git add -A; GIT_EDITOR=true git rebase --continue >/dev/null 2>&1; }
echo "final" > src/b.sh; git commit -qam "final"; git push -qf origin feature/code
launch
eq "attempt 3 exits 0" "0" "$(cat "${STATE}.exit" 2>/dev/null)"

# ── every attempt's log kept ────────────────────────────────────────────────
[ -s "${STATE}.1.log" ] && ok "attempt 1 log archived" || bad "no ${STATE}.1.log"
[ -s "${STATE}.2.log" ] && ok "attempt 2 log archived" || bad "no ${STATE}.2.log"
[ -s "${STATE}.log" ] && ok "attempt 3 is the current log" || bad "no current log"
eq "attempt 1 exit archived" "1" "$(cat "${STATE}.1.exit" 2>/dev/null)"
grep -q "Merge conflict" "${STATE}.1.log" && ok "archived log 1 is attempt 1's (conflict)" || bad "log 1 content"

# ── one structured event per attempt ────────────────────────────────────────
EV=$(events)
eq "three attempt events, in order, with files" "1 conflict src/a.sh,src/b.sh
2 conflict src/a.sh
3 landed " "$EV"
python3 - "$AUTOCODER_MERGE_EVENTS" <<'PY' && ok "events carry ts, repo, issue, branch, duration, exit" || bad "event fields"
import json, sys
need = {"ts", "repo", "issue", "branch", "attempt", "outcome", "files", "gate_tests_failed", "duration_s", "exit"}
evs = [json.loads(l) for l in open(sys.argv[1])]
sys.exit(0 if evs and all(need <= set(e) and e["issue"] == 18401 and e["branch"] == "feature/code" for e in evs) else 1)
PY
LANDED=$(python3 -c 'import json,sys; print([json.loads(l) for l in open(sys.argv[1])][-1].get("landed") or "")' "$AUTOCODER_MERGE_EVENTS")
[ "$LANDED" = "$(git -C "$TMP/origin.git" rev-parse master)" ] && ok "landed event names the landed commit" || bad "landed=$LANDED"

# ── a relaunch with nothing to do is "skipped", not "landed" ────────────────
launch
LAST=$(python3 -c 'import json,sys; e=[json.loads(l) for l in open(sys.argv[1])][-1]; print(e["attempt"], e["outcome"], e["landed"])' "$AUTOCODER_MERGE_EVENTS")
eq "attempt 4 on a closed issue records skipped" "4 skipped None" "$LAST"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
