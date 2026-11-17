#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_sweep_abandoned_claims.sh — sweep-abandoned-claims.sh (#205)
# releases a `working` claim at once when its owner process is dead on this
# host and no branch exists for the issue, and leaves every other claim alone.

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
export ISSUE_SOURCE=github
export FAKE_GH_DIR="$TMP/gh-issues"
export AUTOCODER_SWEEP_HOST=testhost

# Scripts dir with a fake issues-gh.sh: issues are JSON files; `list --state
# working` returns the ones labelled working; `release` drops that label.
GH_DIR="$TMP/gh-scripts"
mkdir -p "$GH_DIR"
cp "$SCRIPT_DIR"/{sweep-abandoned-claims.sh,claim-owner.sh,claimed-issue-numbers.sh,git-net-fns.sh,issue-fns.sh,issue-deps.sh,issue-config.sh} "$GH_DIR/"
cat > "$GH_DIR/issues-gh.sh" <<'EOF'
#!/bin/bash
verb="$1"; shift
VERB="$verb" python3 - "$@" <<'PY'
import glob, json, os, sys
store = os.environ["FAKE_GH_DIR"]
verb, args = os.environ["VERB"], sys.argv[1:]
path = lambda n: os.path.join(store, f"{n}.json")
load = lambda n: json.load(open(path(n)))
def save(i): json.dump(i, open(path(i["number"]), "w"))
if verb == "list":
    issues = [json.load(open(p)) for p in sorted(glob.glob(f"{store}/*.json"))]
    if "working" in args:
        issues = [i for i in issues if any(l["name"] == "working" for l in i["labels"])]
    print(json.dumps(issues))
elif verb == "get":
    print(json.dumps(load(args[0])))
elif verb == "comment":
    i = load(args[0]); i["comments"].append({"body": args[args.index("--body") + 1]}); save(i)
elif verb == "release":
    i = load(args[0]); i["labels"] = [l for l in i["labels"] if l["name"] != "working"]; save(i)
else:
    sys.exit(2)
PY
EOF
chmod +x "$GH_DIR/issues-gh.sh"

# A clone with an origin: issue-4 has a remote branch, issue-5 a local one.
git init -q --bare "$TMP/origin.git"
REPO="$TMP/repo"
git init -q "$REPO"
cd "$REPO" || exit 1
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git remote add origin "$TMP/origin.git"
git push -q origin HEAD:refs/heads/feature/issue-4
git branch feature/issue-5

# add_issue <num> <marker-body>... — open, labelled working, with comments.
add_issue() {
  local num="$1"; shift
  python3 - "$num" "$@" > "$FAKE_GH_DIR/$num.json" <<'PY'
import json, sys
n, comments = int(sys.argv[1]), sys.argv[2:]
print(json.dumps({"number": n, "title": f"Issue {n}", "body": "Body.", "state": "OPEN",
                  "labels": [{"name": "bug"}, {"name": "working"}],
                  "comments": [{"body": c} for c in comments]}))
PY
}
has_working() {
  python3 -c 'import json,sys; i=json.load(open(sys.argv[1])); print("yes" if any(l["name"]=="working" for l in i["labels"]) else "no")' \
    "$FAKE_GH_DIR/$1.json"
}
comment_count() {
  python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["comments"]))' "$FAKE_GH_DIR/$1.json"
}

# A pid that is certainly dead, and one that is alive (this shell).
sleep 0 & DEAD=$!; wait "$DEAD"
LIVE=$$
LIVE_START=$(bash -c "source '$SCRIPT_DIR/claim-owner.sh'; _co_start $LIVE")
NOW_MS=$(( $(date +%s) * 1000 ))
OLD_MS=$(( NOW_MS - 600000 ))   # past the 120 s grace period

mkdir -p "$FAKE_GH_DIR"
add_issue 1 "🔒 claim testhost-$DEAD $OLD_MS start=1700000000 wt=/w/a b"                 # dead, no branch
add_issue 2 "🔒 claim testhost-$LIVE $OLD_MS start=$LIVE_START wt=/w"                     # live owner
add_issue 3 "🔒 claim otherhost-$DEAD $OLD_MS wt=/w"                                     # another host
add_issue 4 "🔒 claim testhost-$DEAD $OLD_MS wt=/w"                                      # remote branch
add_issue 5 "🔒 claim testhost-$DEAD $OLD_MS wt=/w"                                      # local branch
add_issue 6 "🔒 [autocoder-claim] Starting fix for issue #6 — lock established"           # no marker
add_issue 7 "🔒 claim testhost-$LIVE $OLD_MS start=1000 wt=/w"                            # pid reused
add_issue 8 "🔒 claim testhost-$DEAD $OLD_MS wt=/w" "🔒 claim testhost-$LIVE $OLD_MS wt=/w" # one live of two
add_issue 9 "🔒 claim my-worker $OLD_MS"                                                   # custom id
add_issue 10 "🔒 claim testhost-$DEAD $OLD_MS"                                             # old marker format

add_issue 11 "🔒 claim testhost-$DEAD $NOW_MS wt=/w"                                      # too young to judge
add_issue 12 "🔒 claim testhost-$DEAD $OLD_MS wt=/w" \
             "🔒 [autocoder-claim] Starting fix for issue #12 — lock established"        # re-claimed via /fix
add_issue 13 "🔒 claim testhost-$LIVE $OLD_MS wt=/w" "🔓 **Releasing claim** …" \
             "🔒 claim testhost-$DEAD $OLD_MS wt=/w"                                    # only the newest claim counts
add_issue 15 "🔒 claim testhost-$DEAD $OLD_MS wt=/w" "🚫 **Blocked - Requires Human Input**" \
             "🔒 claim testhost-$LIVE $OLD_MS wt=/w"                                    # blocked, then live re-claim
add_issue 16 "🔒 claim testhost-$DEAD $OLD_MS wt=/w" "Releasing stale 'working' label: no commits" \
             "🔒 [autocoder-claim] Starting fix for issue #16 — lock established"        # stale-released, re-claimed
add_issue 17 "🔒 claim testhost-$LIVE $OLD_MS wt=/w" "🎨 **Blocked — Needs Design**" \
             "🔒 claim testhost-$DEAD $OLD_MS wt=/w"                                    # design-blocked, dead re-claim

# ── dry run changes nothing ───────────────────────────────────────────────
OUT=$(bash "$GH_DIR/sweep-abandoned-claims.sh" --dry-run 2>&1)
assert_eq "dry run reports #1" "1" "$(grep -c '^released #1:' <<< "$OUT")"
assert_eq "dry run keeps the label" "yes" "$(has_working 1)"
assert_eq "dry run posts nothing" "1" "$(comment_count 1)"

# ── real sweep ────────────────────────────────────────────────────────────
OUT=$(bash "$GH_DIR/sweep-abandoned-claims.sh" 2>&1)
echo "$OUT" | sed 's/^/    /'
assert_eq "dead owner, no branch: released" "no" "$(has_working 1)"
assert_eq "dead owner, no branch: comment posted" "2" "$(comment_count 1)"
assert_eq "release comment names the owner" "1" \
  "$(python3 -c 'import json,sys; print(int(sys.argv[2] in json.load(open(sys.argv[1]))["comments"][-1]["body"]))' "$FAKE_GH_DIR/1.json" "testhost-$DEAD")"
assert_eq "live owner: kept"                 "yes" "$(has_working 2)"
assert_eq "live owner: no comment"           "1"   "$(comment_count 2)"
assert_eq "other host: kept"                 "yes" "$(has_working 3)"
assert_eq "remote branch: kept"              "yes" "$(has_working 4)"
assert_eq "local branch: kept"               "yes" "$(has_working 5)"
assert_eq "no claim marker: kept"            "yes" "$(has_working 6)"
assert_eq "reused pid (start mismatch): released" "no" "$(has_working 7)"
assert_eq "one live marker of two: kept"     "yes" "$(has_working 8)"
assert_eq "non host-pid id: kept"            "yes" "$(has_working 9)"
assert_eq "old marker format, dead: released" "no" "$(has_working 10)"
assert_eq "claim younger than the grace period: kept" "yes" "$(has_working 11)"
assert_eq "re-claim with no owner marker: kept" "yes" "$(has_working 12)"
assert_eq "markers before a release are ignored" "no" "$(has_working 13)"
assert_eq "🚫 block resets markers: live re-claim kept" "yes" "$(has_working 15)"
assert_eq "stale release resets markers: /fix re-claim kept" "yes" "$(has_working 16)"
assert_eq "🎨 block resets markers: dead re-claim released" "no" "$(has_working 17)"
assert_eq "kept lines give a reason" "1" "$(grep -c '^kept #3: owner otherhost-.* is on another host' <<< "$OUT")"

# ── an unreachable remote releases nothing ────────────────────────────────
add_issue 14 "🔒 claim testhost-$DEAD $OLD_MS wt=/w"
bash "$GH_DIR/sweep-abandoned-claims.sh" --remote nosuchremote >/dev/null 2>&1; RC=$?
assert_eq "unreachable remote exits 1" "1" "$RC"
assert_eq "unreachable remote: dead claim kept" "yes" "$(has_working 14)"

# ── an unreadable list is an error, not a silent no-op ───────────────────
mv "$GH_DIR/issues-gh.sh" "$GH_DIR/issues-gh.sh.off"
printf '#!/bin/bash\nexit 3\n' > "$GH_DIR/issues-gh.sh"; chmod +x "$GH_DIR/issues-gh.sh"
bash "$GH_DIR/sweep-abandoned-claims.sh" >/dev/null 2>&1; RC=$?
assert_eq "unreadable list exits 1" "1" "$RC"

echo ""
echo "Tests: $FAIL failed, $PASS passed"
[ "$FAIL" -eq 0 ]
