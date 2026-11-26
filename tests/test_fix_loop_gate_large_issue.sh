#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_fix_loop_gate_large_issue.sh — the claim race check must still
# decide a winner when the issue JSON is too big to put in the environment
# (#423). Passing it as ISSUE_JSON made python die with "Argument list too
# long" after the claim comment was posted, and the gate left `working` on.

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

GH_DIR="$TMP/gh-scripts"
mkdir -p "$GH_DIR"
cp "$SCRIPT_DIR"/{fix-loop-gate.sh,claim-owner.sh,issue-fns.sh,issue-deps.sh,issue-config.sh} "$GH_DIR/"
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

reset_issues() {
  rm -rf "$FAKE_GH_DIR" "$FAKE_GH_LOG" "$WORK_JSON"
  mkdir -p "$FAKE_GH_DIR"
}

# add_issue <num> <comment-bytes> <label>...
add_issue() {
  local num="$1" nbytes="$2"; shift 2
  python3 - "$FAKE_GH_DIR/$num.json" "$num" "$nbytes" "$@" <<'PY'
import json, sys
path, n, nbytes = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
labels = sys.argv[4:]
body = "x" * nbytes
json.dump({"number": n, "title": f"Issue {n}", "body": "Body.",
           "labels": [{"name": l} for l in labels], "state": "OPEN",
           "comments": [{"body": body}]}, open(path, "w"))
PY
}

has_working() {
  python3 -c 'import json,sys; i=json.load(open(sys.argv[1])); print("yes" if any(l["name"]=="working" for l in i["labels"]) else "no")' \
    "$FAKE_GH_DIR/$1.json"
}

# One comment bigger than MAX_ARG_STRLEN (32 pages). The race check used to
# pass the whole issue as one environment variable, and the kernel rejects
# that exec. The pad is not an environment variable for the same reason.
issue_bytes=$(( $(getconf PAGE_SIZE) * 32 + 4096 ))

reset_issues
add_issue 1 "$issue_bytes" bug P1
ERR="$TMP/gate.err"
AUTOCODER_WORKER_ID=me AUTOCODER_WORK_JSON="$WORK_JSON" \
  bash "$GH_DIR/fix-loop-gate.sh" >"$TMP/gate.out" 2>"$ERR"
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "--- gate stderr ---"
  cat "$ERR"
fi
assert_eq "large issue: gate exits 0" "0" "$RC"
assert_eq "large issue: work plan names #1" \
  '{"phase":"fix","issue":1,"priority":"P1"}' "$(cat "$WORK_JSON" 2>/dev/null)"
assert_eq "large issue: #1 labelled working" "yes" "$(has_working 1)"
if grep -q "Argument list too long" "$ERR"; then
  echo "FAIL: large issue: race check still hit argument list too long"
  FAIL=$((FAIL + 1))
else
  echo "PASS: large issue: race check did not hit argument list too long"
  PASS=$((PASS + 1))
fi

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
