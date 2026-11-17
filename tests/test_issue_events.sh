#!/bin/bash
# tests/test_issue_events.sh — the issue lifecycle is recorded as it happens (#190).
#
# Drives one issue through a fake repo with the real verbs: claim → commit → a gate
# attempt that conflicts → a gate attempt that lands → a deploy, and expects
# issue-events.jsonl to hold those steps in order. Then the label-driven events:
# a blocking label is an escalation, a decomposed label carries its children, and
# dropping `working` is a release.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
ISSUE=19001

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export AUTOCODER_SPOT_CHECK_RATE=0
export ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export AUTOCODER_MERGE_EVENTS="$TMP/merge-events.jsonl"
export AUTOCODER_ISSUE_EVENTS="$TMP/issue-events.jsonl"
export CLAUDE_CODE_SHIP_BRANCH=master
export AUTOCODER_WORKER="swarm:3"
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE

mkdir -p "$TMP/issues"/{open,working,blocked,closed}
for n in "$ISSUE" 19002 19003; do
  printf -- '---\nnumber: %s\ntitle: Events\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$n" > "$TMP/issues/open/${n}.md"
done

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email t@example.com; git config user.name T
git remote add origin "$TMP/origin.git"
echo base > README.md; mkdir -p src; echo base > src/a.sh
git add -A; git commit -q -m init; git branch -M master; git push -q origin master master:master-green
git clone -q "$TMP/origin.git" "$TMP/sibling"
git -C "$TMP/sibling" config user.email s@example.com; git -C "$TMP/sibling" config user.name S

# Sourced from inside the fake repo, so its (absent) .autocoder.json decides the backend.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/issue-fns.sh"
source "$SCRIPT_DIR/repo-id-fns.sh"
REPO_ID=$(autocoder_repo_id "$TMP/worker")
STATE="$AUTOCODER_TMP/autocoder-merge-${REPO_ID}-${ISSUE}"

launch() {  # one detached attempt, waited to completion
  bash "$SCRIPT_DIR/merge-launch.sh" --feature feature/code --issue "$ISSUE" --integration master \
    --test-cmd true --own-issue >/dev/null 2>&1 || { bad "launch failed"; return 1; }
  for _ in $(seq 1 120); do [ -s "${STATE}.exit" ] && return 0; sleep 0.5; done
  bad "attempt did not finish"; return 1
}
# The issue's timeline: events for <issue>, ordered by ts (stable, so ties keep file order).
timeline() { python3 -c '
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1])]
evs = [e for e in evs if str(e["issue"]) == sys.argv[2]]
evs.sort(key=lambda e: e["ts"])
for e in evs:
    d = e["detail"]
    print(e["event"] + (":" + d["outcome"] if "outcome" in d else ""))' "$AUTOCODER_ISSUE_EVENTS" "$1" 2>/dev/null; }

# ── claim, commit ───────────────────────────────────────────────────────────
git checkout -q -b feature/code master
issue_claim "$ISSUE" >/dev/null || bad "claim failed"
sleep 1   # the commit's second is later than the claim's, as in real use
echo change > src/a.sh; git commit -qam fix; git push -q origin feature/code
FIRST=$(git rev-parse HEAD)

# ── attempt 1: a sibling landed a clash first → conflict ────────────────────
(cd "$TMP/sibling" && echo "sibling" > src/a.sh && git commit -qam clash && git push -q origin master)
launch
eq "attempt 1 exits 1" "1" "$(cat "${STATE}.exit" 2>/dev/null)"

# ── attempt 2: rebased onto master → lands ──────────────────────────────────
git fetch -q origin
git rebase -q -X theirs origin/master >/dev/null 2>&1 || { git checkout -q --theirs . ; git add -A; GIT_EDITOR=true git rebase --continue >/dev/null 2>&1; }
echo "final" > src/a.sh; git commit -qam final; git push -qf origin feature/code
launch
eq "attempt 2 exits 0" "0" "$(cat "${STATE}.exit" 2>/dev/null)"
LANDED_SHA=$(git -C "$TMP/origin.git" rev-parse master)

# ── deploy the landed tip ───────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"/statuses"*) ;; *deployments*) echo 42 ;; esac
EOF
chmod +x "$TMP/bin/gh"
git clone -q "$TMP/origin.git" "$TMP/deployer"
echo '{"environments": [{"name": "plain", "requires": "integration"}]}' > "$TMP/deployer/.autocoder.json"
echo .autocoder.json >> "$TMP/deployer/.git/info/exclude"
(cd "$TMP/deployer" && git checkout -q master && PATH="$TMP/bin:$PATH" \
  bash "$SCRIPT_DIR/deploy.sh" --env plain --integration master >/dev/null 2>&1) \
  && ok "deploy ran" || bad "deploy failed"

# ── the issue's timeline, in order ──────────────────────────────────────────
eq "claim → commit → conflicted gate → landed gate, in order" "claimed
first-commit
gate-queued
gate-start
gate-end:conflict
gate-queued
gate-start
gate-end:landed
landed" "$(timeline "$ISSUE" | grep -v '^released$')"

python3 - "$AUTOCODER_ISSUE_EVENTS" "$ISSUE" "$FIRST" "$LANDED_SHA" "$REPO_ID" <<'PY' && ok "fields: v, repo, worker, branch, first-commit sha, landed sha, deployed" || bad "event fields"
import json, sys
path, issue, first, landed, repo = sys.argv[1:]
evs = [json.loads(l) for l in open(path)]
mine = [e for e in evs if str(e["issue"]) == issue]
need = {"v", "ts", "repo", "issue", "worker", "branch", "event", "detail"}
assert all(set(e) == need and e["v"] == 1 for e in evs), "field set"
assert all(e["repo"] == repo for e in mine), [e["repo"] for e in mine]
assert all(e["worker"] == "swarm:3" for e in mine), [e["worker"] for e in mine]
assert all(e["branch"] == "feature/code" for e in mine), [(e["event"], e["branch"]) for e in mine]
by = {}
for e in mine:
    by.setdefault(e["event"], []).append(e)
assert len(by["first-commit"]) == 1, "first-commit written once"
assert by["first-commit"][0]["detail"]["sha"] == first
assert [e["detail"]["attempt"] for e in by["gate-end"]] == [1, 2]
assert by["landed"][0]["detail"]["sha"] == landed
dep = [e for e in evs if e["event"] == "deployed"]
assert len(dep) == 1 and dep[0]["issue"] is None, dep
assert dep[0]["detail"] == {"environment": "plain", "sha": landed, "deployment": "42"}, dep[0]["detail"]
assert dep[0]["ts"] >= by["landed"][0]["ts"]
PY

# ── label-driven events ─────────────────────────────────────────────────────
issue_claim 19002 >/dev/null
AUTOCODER_EVENT_REASON="needs a decision" issue_update 19002 --add-label needs-design >/dev/null 2>&1
issue_update 19002 --remove-label working >/dev/null 2>&1
issue_claim 19003 >/dev/null
AUTOCODER_EVENT_CHILDREN="19010 19011" issue_update 19003 --add-label decomposed >/dev/null 2>&1
issue_update 19003 --remove-label working --add-label awaiting-integration >/dev/null 2>&1
eq "blocking label → escalated, dropping working → released" "claimed
escalated
released" "$(timeline 19002)"
eq "decomposed recorded; a hand-off to awaiting-integration is not a release" "claimed
decomposed" "$(timeline 19003)"
python3 - "$AUTOCODER_ISSUE_EVENTS" <<'PY' && ok "escalated carries label and reason; decomposed carries children" || bad "label event detail"
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1])]
esc = [e for e in evs if e["event"] == "escalated"][0]["detail"]
assert esc == {"label": "needs-design", "reason": "needs a decision"}, esc
dec = [e for e in evs if e["event"] == "decomposed"][0]["detail"]
assert dec == {"children": [19010, 19011]}, dec
PY

# ── a failed verb records nothing ───────────────────────────────────────────
before=$(wc -l < "$AUTOCODER_ISSUE_EVENTS")
issue_claim 19999 >/dev/null 2>&1 && bad "claiming a missing issue succeeded"
eq "a failed claim writes no event" "$before" "$(wc -l < "$AUTOCODER_ISSUE_EVENTS")"

# ── an unwritable log never fails the verb ──────────────────────────────────
AUTOCODER_ISSUE_EVENTS=/proc/nope/events.jsonl issue_update 19002 --add-label working >/dev/null 2>&1 \
  && ok "verb succeeds when the log cannot be written" || bad "an unwritable log failed the verb"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
