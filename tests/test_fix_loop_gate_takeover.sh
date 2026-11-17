#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_fix_loop_gate_takeover.sh — pins #203 (sub-task of #179): the gate
# takes over a `working` issue whose every claim is abandoned, instead of backing
# off from it forever, and still respects a live claim.
#
# Abandoned (claim-takeover-fns.sh): no feature/issue-N branch, and either the
# owner named in a #202 marker is dead on this host (pid gone or reused), or the
# owner cannot be checked from here (another host, no pid, a pre-#202 marker) and
# the claim is older than the grace period (AUTOCODER_CLAIM_GRACE_S, 7200 s).

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — want '$want', got '$got'"; FAIL=$((FAIL + 1))
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init --quiet
# Every "worker" here runs from this one worktree, so resuming this worktree's own
# claim (#182, tests/test_fix_loop_gate_resume.sh) would make later workers resume
# the first one's issue. These tests are about claim races, so resume is off.
export AUTOCODER_RESUME_OWN_CLAIM=0
export ISSUE_SOURCE=github
export FAKE_GH_DIR="$TMP/gh-issues"
export FAKE_GH_LOG="$TMP/gh-calls.log"
WORK_JSON="$TMP/work.json"

# A scripts dir whose issues-gh.sh keeps issues as JSON files with the real
# backend's list/get shapes (number, title, body, labels[{name}], state,
# comments[{body}]). Like the real one, `claim` and `release` only edit the
# shared `working` label.
GH_DIR="$TMP/gh-scripts"
mkdir -p "$GH_DIR"
cp "$SCRIPT_DIR"/{fix-loop-gate.sh,claim-owner.sh,claim-takeover-fns.sh,issue-fns.sh,issue-deps.sh,issue-config.sh} "$GH_DIR/"
cat > "$GH_DIR/issues-gh.sh" <<'EOF'
#!/bin/bash
verb="$1"; shift
echo "$verb $*" >> "$FAKE_GH_LOG"
VERB="$verb" python3 - "$@" <<'PY'
import glob, json, os, sys

store = os.environ["FAKE_GH_DIR"]
verb, args = os.environ["VERB"], sys.argv[1:]
path = lambda n: os.path.join(store, f"{n}.json")

def load(n):
    with open(path(n)) as f:
        return json.load(f)

def save(issue):
    with open(path(issue["number"]), "w") as f:
        json.dump(issue, f)

def set_working(n, on):
    issue = load(n)
    names = [l["name"] for l in issue["labels"] if l["name"] != "working"]
    issue["labels"] = [{"name": x} for x in names + (["working"] if on else [])]
    save(issue)

if verb == "list":
    issues = [json.load(open(p)) for p in sorted(glob.glob(f"{store}/*.json"))]
    print(json.dumps([{k: i[k] for k in ("number", "title", "body", "labels", "state")}
                      for i in issues]))
elif verb == "get":
    print(json.dumps(load(args[0])))
elif verb == "comment":
    issue = load(args[0])
    issue["comments"].append({"body": args[args.index("--body") + 1]})
    save(issue)
elif verb == "claim":
    set_working(args[0], True)
elif verb == "release":
    set_working(args[0], False)
else:
    sys.exit(2)
PY
EOF
chmod +x "$GH_DIR/issues-gh.sh"

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

reset_issues() {
  rm -rf "$FAKE_GH_DIR" "$FAKE_GH_LOG" "$WORK_JSON"
  mkdir -p "$FAKE_GH_DIR"
}

# add_issue <num> <label>... — open, unclaimed, no comments.
add_issue() {
  local num="$1"; shift
  python3 - "$num" "$@" > "$FAKE_GH_DIR/$num.json" <<'PY'
import json, sys
n, labels = int(sys.argv[1]), sys.argv[2:]
print(json.dumps({"number": n, "title": f"Issue {n}", "body": "Body.",
                  "labels": [{"name": l} for l in labels], "state": "OPEN",
                  "comments": []}))
PY
}

# seed_comment <num> <body> — a comment a competitor already posted.
seed_comment() {
  python3 - "$FAKE_GH_DIR/$1.json" "$2" <<'PY'
import json, sys
p, body = sys.argv[1], sys.argv[2]
issue = json.load(open(p))
issue["comments"].append({"body": body})
json.dump(issue, open(p, "w"))
PY
}

has_working() {
  python3 -c 'import json,sys; i=json.load(open(sys.argv[1])); print("yes" if any(l["name"]=="working" for l in i["labels"]) else "no")' \
    "$FAKE_GH_DIR/$1.json"
}

comments_of() {
  python3 -c 'import json,sys; [print(c["body"]) for c in json.load(open(sys.argv[1]))["comments"]]' \
    "$FAKE_GH_DIR/$1.json"
}

# run_gate [scripts-dir] — prints the gate's exit code.
run_gate() {
  local dir="${1:-$GH_DIR}"
  AUTOCODER_WORKER_ID=me AUTOCODER_WORK_JSON="$WORK_JSON" \
    bash "$dir/fix-loop-gate.sh" 2>/dev/null
  echo $?
}

work_plan() { cat "$WORK_JSON" 2>/dev/null; }


HOST=$(hostname)
# shellcheck source=../plugins/autocoder/scripts/claim-owner.sh
source "$SCRIPT_DIR/claim-owner.sh"
git -C "$REPO" config user.email t@example.com; git -C "$REPO" config user.name T
git -C "$REPO" commit -q --allow-empty -m base
# A reachable origin: only a definite "no such branch" counts as no evidence.
git init -q --bare "$TMP/origin.git"
git -C "$REPO" remote add origin "$TMP/origin.git"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
dead_pid() { sleep 0 & local p=$!; wait "$p"; echo "$p"; }
ms_ago() { echo $(( $(now_ms) - $1 * 1000 )); }
plan_issue() { jq -r .issue "$WORK_JSON" 2>/dev/null; }
takeover_noted() { comments_of "$1" | grep -q 'Taking over an abandoned claim' && echo yes || echo no; }
# working_issue <num> <prio> <claim-marker-body> — held by someone, per that marker.
working_issue() { add_issue "$1" bug "$2" working; seed_comment "$1" "$3"; }

# ── 1. Dead owner on this host, no branch: taken over, with a comment ──────
reset_issues
P=$(dead_pid)
working_issue 7 P1 "🔒 claim ${HOST}-${P} $(ms_ago 10) start=$(date +%s) wt=/somewhere/wt-9"
RC=$(run_gate)
assert_eq "dead owner: the gate exits 0" "0" "$RC"
assert_eq "dead owner: the plan is #7" "7" "$(plan_issue)"
assert_eq "dead owner: a takeover comment names it" "yes" "$(takeover_noted 7)"
comments_of 7 | grep -q "${HOST}-${P}" && ok "the takeover comment names the old owner" || bad "old owner not named"
comments_of 7 | grep -qE "^🔒 claim me [0-9]+" && ok "the taker posted its own claim marker" || bad "no claim marker from the taker"

# ── 2. Live owner on this host: respected, nothing posted ───────────────────
reset_issues
working_issue 8 P1 "🔒 claim ${HOST}-$$ $(ms_ago 600) start=$(_co_start $$) wt=$REPO"
RC=$(run_gate)
assert_eq "live owner: the gate idles (exit 1)" "1" "$RC"
assert_eq "live owner: no comment posted" "1" "$(comments_of 8 | wc -l | tr -d ' ')"

# ── 3. The owner's pid now belongs to a different process: abandoned ────────
reset_issues
working_issue 9 P1 "🔒 claim ${HOST}-$$ $(ms_ago 10) start=$(( $(_co_start $$) - 86400 )) wt=$REPO"
run_gate >/dev/null
assert_eq "reused pid (start time differs): taken over" "9" "$(plan_issue)"

# ── 4. Another host's claim: judged by age and branch only ──────────────────
reset_issues
working_issue 10 P1 "🔒 claim otherhost-4242 $(ms_ago 1800) start=1 wt=/x"
assert_eq "other host, 30 min in (no push yet): respected" "1" "$(run_gate)"
reset_issues
working_issue 10 P1 "🔒 claim otherhost-4242 $(ms_ago 8000) start=1 wt=/x"
run_gate >/dev/null
assert_eq "other host, past the grace period, no branch: taken over" "10" "$(plan_issue)"

# ── 5. Any branch is evidence of work: respected ────────────────────────────
reset_issues
P=$(dead_pid)
working_issue 11 P1 "🔒 claim ${HOST}-${P} $(ms_ago 600) start=1 wt=/x"
git -C "$REPO" branch -q feature/issue-11
assert_eq "dead owner but feature/issue-11 exists: respected" "1" "$(run_gate)"
git -C "$REPO" branch -q -D feature/issue-11

# ── 6. A pre-#202 marker names the gate's own (always dead) pid: grace rule ─
reset_issues
P=$(dead_pid)
working_issue 12 P1 "🔒 claim ${HOST}-${P} $(ms_ago 30)"
assert_eq "old marker, young: respected despite the dead pid" "1" "$(run_gate)"
reset_issues
working_issue 12 P1 "🔒 claim ${HOST}-${P} $(ms_ago 8000)"
run_gate >/dev/null
assert_eq "old marker, past the grace period: taken over" "12" "$(plan_issue)"

# ── 6b. Origin cannot be asked: the claim stands ────────────────────────────
reset_issues
working_issue 19 P1 "🔒 claim otherhost-4242 $(ms_ago 8000) start=1 wt=/x"
git -C "$REPO" remote set-url origin "$TMP/no-such-origin.git"
assert_eq "origin unreachable: respected (no evidence is not proof of none)" "1" "$(run_gate)"
git -C "$REPO" remote set-url origin "$TMP/origin.git"
# ...and a branch on origin is evidence too.
git -C "$REPO" push -q origin HEAD:refs/heads/feature/issue-19
assert_eq "feature/issue-19 on origin: respected" "1" "$(run_gate)"

# ── 6c. Dead pid, but the claim's worktree still holds THIS claim ───────────
# (an owner pid that was only ever short-lived: the gate's parent shell)
reset_issues
P=$(dead_pid)
WT2="$TMP/wt2"; git -C "$REPO" worktree add -q --detach "$WT2"
REC="$(git -C "$WT2" rev-parse --absolute-git-dir)/autocoder-worker-state"
CMS=$(ms_ago 10)
working_issue 20 P1 "🔒 claim ${HOST}-${P} ${CMS} start=1 wt=$WT2"
echo "20 ${CMS} -" > "$REC"
assert_eq "dead pid but its worktree records this claim: respected" "1" "$(run_gate)"
echo "20 123 -" > "$REC"
run_gate >/dev/null
assert_eq "a record of the same issue but a different claim does not count" "20" "$(plan_issue)"
# A leftover record cannot keep a dead claim alive past the grace period.
reset_issues
CMS=$(ms_ago 8000)
working_issue 21 P1 "🔒 claim ${HOST}-${P} ${CMS} start=1 wt=$WT2"
echo "21 ${CMS} -" > "$REC"
run_gate >/dev/null
assert_eq "a matching record past the grace period: taken over" "21" "$(plan_issue)"
git -C "$REPO" worktree remove --force "$WT2"

# ── 7. Every claim must be abandoned ─────────────────────────────────────────
reset_issues
P=$(dead_pid)
working_issue 13 P1 "🔒 claim ${HOST}-${P} $(ms_ago 20) start=1 wt=/x"
seed_comment 13 "🔒 claim ${HOST}-$$ $(ms_ago 10) start=$(_co_start $$) wt=$REPO"
assert_eq "one dead and one live claim: respected" "1" "$(run_gate)"

# ── 8. A fresh issue goes before a takeover at the same priority ─────────────
reset_issues
P=$(dead_pid)
working_issue 14 P1 "🔒 claim ${HOST}-${P} $(ms_ago 10) start=1 wt=/x"
add_issue 15 bug P1
run_gate >/dev/null
assert_eq "same priority: the fresh #15 is claimed first" "15" "$(plan_issue)"
assert_eq "...and #14 is left alone this tick" "no" "$(takeover_noted 14)"
# ...but an abandoned P0 beats a fresh P2.
reset_issues
working_issue 16 P0 "🔒 claim ${HOST}-${P} $(ms_ago 10) start=1 wt=/x"
add_issue 17 bug P2
run_gate >/dev/null
assert_eq "an abandoned P0 is taken before a fresh P2" "16" "$(plan_issue)"

# ── 9. The abandoned claim cannot win the race it is being taken from ───────
# (#1 already shows it: that dead claim was 10 s old, inside the 120 s race
# window, and earlier than ours. Without the exclusion the taker would lose.)
reset_issues
P=$(dead_pid)
working_issue 18 P1 "🔒 claim ${HOST}-${P} $(ms_ago 5) start=1 wt=/x"
AUTOCODER_CLAIM_WINDOW_S=3600 run_gate >/dev/null
assert_eq "a dead claim inside the race window does not beat the taker" "18" "$(plan_issue)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
