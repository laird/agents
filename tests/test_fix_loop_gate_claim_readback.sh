#!/bin/bash
# tests/test_fix_loop_gate_claim_readback.sh — on a best-effort backend
# (GitHub, Jira, ADO) `issue_claim` is a label-add every racer "wins".
# fix-loop-gate.sh must settle the race itself by posting a claim comment and
# reading it back, so the loser moves to the next candidate before a Claude
# session starts instead of after.

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
cp "$SCRIPT_DIR"/{fix-loop-gate.sh,issue-fns.sh,issue-config.sh} "$GH_DIR/"
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

# ── 1. Uncontested: claim kept, work plan written, one claim comment ──────
reset_issues
add_issue 1 bug P1; add_issue 2 bug P1
RC=$(run_gate)
assert_eq "uncontested: gate exits 0" "0" "$RC"
assert_eq "uncontested: work plan names #1" \
  '{"phase":"fix","issue":1,"priority":"P1"}' "$(work_plan)"
assert_eq "uncontested: #1 labelled working" "yes" "$(has_working 1)"
assert_eq "uncontested: #2 untouched" "no" "$(has_working 2)"
comments_of 1 | grep -qE '^🔒 claim me [0-9]{13}$'
assert_eq "uncontested: claim comment names the worker id" "0" "$?"
comments_of 1 | grep -qF '[autocoder-claim]'
assert_eq "uncontested: comment cannot trip /fix's [autocoder-claim] count" "1" "$?"

# ── 2. A competitor's earlier claim → leave #1 to it, claim #2 ────────────
reset_issues
add_issue 1 bug P1; add_issue 2 bug P1; add_issue 3 bug P1
seed_comment 1 "🔒 claim rival $(( $(now_ms) - 1000 ))"
RC=$(run_gate)
assert_eq "lost race: gate exits 0" "0" "$RC"
assert_eq "lost race: work plan names the second issue" \
  '{"phase":"fix","issue":2,"priority":"P1"}' "$(work_plan)"
assert_eq "lost race: #1 keeps the winner's working label" "yes" "$(has_working 1)"
assert_eq "lost race: #3 untouched" "no" "$(has_working 3)"
assert_eq "lost race: the shared label is never released" "0" \
  "$(grep -c '^release' "$FAKE_GH_LOG")"

# ── 2b. A competitor's later claim loses to ours ──────────────────────────
reset_issues
add_issue 1 bug P1
seed_comment 1 "🔒 claim rival $(( $(now_ms) + 60000 ))"
run_gate >/dev/null
assert_eq "later rival: gate keeps #1" \
  '{"phase":"fix","issue":1,"priority":"P1"}' "$(work_plan)"

# ── 2c. A claim older than the window is a settled race, not a rival ──────
reset_issues
add_issue 1 bug P1
seed_comment 1 "🔒 claim rival $(( $(now_ms) - 600000 ))"
run_gate >/dev/null
assert_eq "stale rival: gate keeps #1" \
  '{"phase":"fix","issue":1,"priority":"P1"}' "$(work_plan)"

# ── 3. Every candidate lost → exit 1, no work plan, labels left alone ─────
reset_issues
add_issue 1 bug P1; add_issue 2 enhancement P2
seed_comment 1 "🔒 claim rival $(( $(now_ms) - 1000 ))"
seed_comment 2 "🔒 claim rival $(( $(now_ms) - 1000 ))"
RC=$(run_gate)
assert_eq "all lost: gate exits 1" "1" "$RC"
assert_eq "all lost: no work plan" "" "$(work_plan)"
assert_eq "all lost: both claims tried" "2" "$(grep -c '^claim' "$FAKE_GH_LOG")"
assert_eq "all lost: nothing released" "0" "$(grep -c '^release' "$FAKE_GH_LOG")"

# ── 4. Two workers on one queue claim two different issues ────────────────
reset_issues
add_issue 1 bug P1; add_issue 2 bug P1
# Worker B snapshots before A's label lands (search-index lag), so both
# label #1; only the read-back separates them.
AUTOCODER_WORKER_ID=a AUTOCODER_WORK_JSON="$TMP/a.json" bash "$GH_DIR/fix-loop-gate.sh" 2>/dev/null
set_unlabelled() {
  python3 - "$FAKE_GH_DIR/1.json" <<'PY'
import json, sys
p = sys.argv[1]; i = json.load(open(p))
i["labels"] = [l for l in i["labels"] if l["name"] != "working"]
json.dump(i, open(p, "w"))
PY
}
set_unlabelled
AUTOCODER_WORKER_ID=b AUTOCODER_WORK_JSON="$TMP/b.json" bash "$GH_DIR/fix-loop-gate.sh" 2>/dev/null
assert_eq "two workers: A keeps #1" '{"phase":"fix","issue":1,"priority":"P1"}' "$(cat "$TMP/a.json")"
assert_eq "two workers: B moves to #2" '{"phase":"fix","issue":2,"priority":"P1"}' "$(cat "$TMP/b.json")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
