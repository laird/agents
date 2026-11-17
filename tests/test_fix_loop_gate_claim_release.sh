#!/bin/bash
# tests/test_fix_loop_gate_claim_release.sh — fix-loop-gate.sh must release a
# claim it took but could not hand off (#204). Between `issue_claim` and writing
# the work plan the gate can hit an error or be killed; the claim it leaves names
# the long-lived owner, so nothing would ever reclaim it. The release must never
# strip a `working` label a race winner owns.

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
export AUTOCODER_RESUME_OWN_CLAIM=0
export ISSUE_SOURCE=github
export FAKE_GH_DIR="$TMP/gh-issues"
export FAKE_GH_LOG="$TMP/gh-calls.log"
WORK_JSON="$TMP/work.json"
# A work-plan path that cannot be written: the injected failure after the claim.
BAD_JSON="$TMP/no-such-dir/work.json"

# Fake GitHub backend: issues as JSON files. FAKE_GET_FAIL=1 makes every `get`
# fail; FAKE_GET_FAIL_ONCE=<file> fails only the first; FAKE_GET_SLEEP_ONCE=<file> makes the first `get` touch <file> and sleep,
# so the test can signal the gate while it holds a claim.
GH_DIR="$TMP/gh-scripts"
mkdir -p "$GH_DIR"
cp "$SCRIPT_DIR"/{fix-loop-gate.sh,claim-owner.sh,worker-state-fns.sh,issue-fns.sh,issue-deps.sh,issue-config.sh} "$GH_DIR/"
cat > "$GH_DIR/issues-gh.sh" <<'EOF'
#!/bin/bash
verb="$1"; shift
echo "$verb $*" >> "$FAKE_GH_LOG"
if [ "$verb" = get ]; then
  [ "${FAKE_GET_FAIL:-0}" = 1 ] && exit 1
  if [ -n "${FAKE_GET_FAIL_ONCE:-}" ] && [ ! -e "$FAKE_GET_FAIL_ONCE" ]; then
    touch "$FAKE_GET_FAIL_ONCE"; exit 1
  fi
  if [ -n "${FAKE_GET_SLEEP_ONCE:-}" ] && [ ! -e "$FAKE_GET_SLEEP_ONCE" ]; then
    touch "$FAKE_GET_SLEEP_ONCE"; sleep 2
  fi
fi
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
  rm -rf "$FAKE_GH_DIR" "$FAKE_GH_LOG" "$WORK_JSON" "$TMP/slept"
  mkdir -p "$FAKE_GH_DIR"
  rm -f "$REPO/.git/autocoder-worker-state"
}

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

release_comments() {
  python3 -c 'import json,sys; print(sum(c["body"].startswith("🔓 **Releasing claim**") for c in json.load(open(sys.argv[1]))["comments"]))' \
    "$FAKE_GH_DIR/$1.json"
}

# run_gate <work-json> — prints the gate's exit code.
run_gate() {
  AUTOCODER_WORKER_ID=me AUTOCODER_WORK_JSON="$1" bash "$GH_DIR/fix-loop-gate.sh" 2>/dev/null
  echo $?
}

# ── 1. Error after the claim → label removed, release comment posted ──────
reset_issues
add_issue 1 bug P1
RC=$(run_gate "$BAD_JSON")
[ "$RC" -ne 0 ]; assert_eq "error after claim: gate exits non-zero" "0" "$?"
assert_eq "error after claim: no working label" "no" "$(has_working 1)"
assert_eq "error after claim: one release comment" "1" "$(release_comments 1)"
assert_eq "error after claim: no worker-state record left" "no" \
  "$([ -f "$REPO/.git/autocoder-worker-state" ] && echo yes || echo no)"

# The released issue is claimable again on the next tick.
RC=$(run_gate "$WORK_JSON")
assert_eq "after release: next tick claims it" '{"phase":"fix","issue":1,"priority":"P1"}' \
  "$(cat "$WORK_JSON" 2>/dev/null)"

# ── 2. A lost race leaves the winner's label in place ─────────────────────
# #1 is lost to an earlier rival; the gate moves to #2 and then fails.
reset_issues
add_issue 1 bug P1; add_issue 2 bug P1
seed_comment 1 "🔒 claim rival $(( $(now_ms) - 1000 ))"
RC=$(run_gate "$BAD_JSON")
assert_eq "lost race then error: winner keeps #1's label" "yes" "$(has_working 1)"
assert_eq "lost race then error: no release comment on #1" "0" "$(release_comments 1)"
assert_eq "lost race then error: #2 released" "no" "$(has_working 2)"
assert_eq "lost race then error: #2 has a release comment" "1" "$(release_comments 2)"

# Every candidate lost: an ordinary idle exit releases nothing.
reset_issues
add_issue 1 bug P1
seed_comment 1 "🔒 claim rival $(( $(now_ms) - 1000 ))"
RC=$(run_gate "$WORK_JSON")
assert_eq "all lost: idle exit" "1" "$RC"
assert_eq "all lost: winner's label kept" "yes" "$(has_working 1)"
assert_eq "all lost: nothing released" "0" "$(grep -c '^release' "$FAKE_GH_LOG")"

# ── 3. A rival who won after our read-back is not stripped ────────────────
# The race read-back fails, so the gate keeps the claim (as it always has). At
# release time the read-back works and shows the rival's earlier claim is live.
reset_issues
add_issue 1 bug P1
seed_comment 1 "🔒 claim rival $(( $(now_ms) - 1000 ))"
FAKE_GET_FAIL_ONCE="$TMP/failed-once"
RC=$(FAKE_GET_FAIL_ONCE="$FAKE_GET_FAIL_ONCE" run_gate "$BAD_JSON")
assert_eq "rival live at release: label kept" "yes" "$(has_working 1)"
assert_eq "rival live at release: no release comment" "0" "$(release_comments 1)"

# ── 4. Read-back fails at release → claim left alone ──────────────────────
reset_issues
add_issue 1 bug P1
RC=$(FAKE_GET_FAIL=1 run_gate "$BAD_JSON")
assert_eq "unreadable at release: label kept" "yes" "$(has_working 1)"
assert_eq "unreadable at release: nothing released" "0" "$(grep -c '^release' "$FAKE_GH_LOG")"

# ── 5. A signal while holding the claim → released ────────────────────────
reset_issues
add_issue 1 bug P1
AUTOCODER_WORKER_ID=me AUTOCODER_WORK_JSON="$WORK_JSON" FAKE_GET_SLEEP_ONCE="$TMP/slept" \
  bash "$GH_DIR/fix-loop-gate.sh" 2>/dev/null &
GATE=$!
for _ in $(seq 1 50); do [ -e "$TMP/slept" ] && break; sleep 0.1; done
kill -TERM "$GATE"
wait "$GATE"; RC=$?
assert_eq "killed after claim: exit status 143" "143" "$RC"
assert_eq "killed after claim: no working label" "no" "$(has_working 1)"
assert_eq "killed after claim: one release comment" "1" "$(release_comments 1)"
assert_eq "killed after claim: no work plan" "no" "$([ -f "$WORK_JSON" ] && echo yes || echo no)"

# ── 6. A successful hand-off releases nothing ─────────────────────────────
reset_issues
add_issue 1 bug P1
RC=$(run_gate "$WORK_JSON")
assert_eq "hand-off: exit 0" "0" "$RC"
assert_eq "hand-off: label kept" "yes" "$(has_working 1)"
assert_eq "hand-off: no release comment" "0" "$(release_comments 1)"

# ── 7. File backend: an error after the atomic claim moves it back ────────
FILE_REPO="$TMP/file-repo"
mkdir -p "$FILE_REPO"/.issues/{open,working,blocked,closed}
( cd "$FILE_REPO" && git init --quiet )
cat > "$FILE_REPO/.issues/open/001.md" <<'EOF'
---
number: 1
title: Issue 1
labels: [bug, P1]
status: open
---
Body.
EOF
( cd "$FILE_REPO" && ISSUE_SOURCE=file ISSUE_DIR_PATH="$FILE_REPO/.issues" \
    AUTOCODER_WORK_JSON="$BAD_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>/dev/null )
assert_eq "file backend: issue back in open/" "yes" \
  "$([ -f "$FILE_REPO/.issues/open/001.md" ] && echo yes || echo no)"
assert_eq "file backend: not left in working/" "no" \
  "$([ -f "$FILE_REPO/.issues/working/001.md" ] && echo yes || echo no)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
