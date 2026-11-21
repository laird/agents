#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_issue_list_decomposed.sh: the claimable queue leaves out decomposed parents (#296).
#
# claim-issue.sh and fix-loop-gate.sh never claim a `decomposed` parent: its work is
# the sub-tasks. `issue_list --state open` used to list one anyway, so the idle
# sentinel's claimable probe (and monitor-workers) woke a manager over an issue no
# worker could take. Runs the file backend in a throwaway repo with a poisoned `gh`.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../plugins/autocoder/scripts" && pwd)"

ok()   { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }

unset ISSUE_SOURCE ISSUE_BACKEND ISSUE_DIR
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ISSUES_DIR="$TMP/.issues"
mkdir -p "$ISSUES_DIR/open" "$ISSUES_DIR/working" "$ISSUES_DIR/blocked" "$ISSUES_DIR/closed"
git -C "$TMP" init -q
cat > "$TMP/.autocoder.json" <<JSON
{ "issueSource": "file", "issueDir": "$ISSUES_DIR" }
JSON
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<GH
#!/bin/bash
echo "REAL gh INVOKED FROM TEST: \$*" >> "$TMP/gh-was-called"
exit 97
GH
chmod +x "$TMP/bin/gh"

run() { (cd "$TMP" && PATH="$TMP/bin:$PATH" bash -c "source '$SCRIPT_DIR/issue-fns.sh'; $1") 2>/dev/null; }

issue() {  # issue <bucket> <number> <labels> <body>
  printf -- '---\nnumber: %s\ntitle: Issue %s\nlabels: [%s]\nstatus: %s\n---\n%b\n' \
    "$2" "$2" "$3" "$1" "$4" > "$ISSUES_DIR/$1/$(printf '%03d' "$2").md"
}

# The agents-ui case: #526 is a decomposed parent; its last sub-tasks wait on a human
# (#545 needs-clarification) or on that sub-task (#546). Nothing is claimable.
issue open    526 "P2, decomposed"            "Split into sub-tasks."
issue blocked 545 "P2, subtask, needs-clarification" "Sub-task of #526"
issue open    546 "P2, subtask"               "Sub-task of #526\nDepends on: #545"

OPEN=$(run "issue_list --state open | jq -c '[.[].number]'")
check "a decomposed parent is not in the open queue" "$OPEN" "[]"
OUT=$(run "issue_any_claimable; echo rc=\$?")
check "issue_any_claimable agrees there is nothing to claim" "$OUT" "rc=1"
ALL=$(run "issue_list --state all | jq -c '[.[].number] | sort'")
check "--state all still lists the parent" "$ALL" "[526,545,546]"
LBL=$(run "issue_list --state all --label decomposed | jq -c '[.[].number]'")
check "a caller can still find decomposed parents by label" "$LBL" "[526]"

# A claimable issue beside the parent is still listed, and only it.
issue open 600 "P3" "Plain work."
OPEN=$(run "issue_list --state open | jq -c '[.[].number]'")
check "other open work stays in the queue" "$OPEN" "[600]"
OPEN=$(run "issue_list | jq -c '[.[].number]'")
check "list with no --state drops the parent too" "$OPEN" "[600]"
OUT=$(run "issue_any_claimable; echo rc=\$?")
check "issue_any_claimable sees the real work" "$OUT" "rc=0"

# The filter passes anything that is not an issue array through untouched. Source it
# in the temp repo (#301): .autocoder.json is gitignored, so a CI checkout has no issue
# source and sourcing issue-fns.sh from the repo itself exits before the filter runs.
OUT=$(run "printf 'not json' | _ifns_drop_decomposed")
check "non-JSON input passes through" "$OUT" "not json"
OUT=$(run "printf '[{\"number\":1,\"labels\":[\"decomposed\"]},{\"number\":2,\"labels\":[\"P1\"]}]' | _ifns_drop_decomposed | jq -c '[.[].number]'")
check "labels given as bare strings are matched too" "$OUT" "[2]"

[ -f "$TMP/gh-was-called" ] && bad "gh was invoked: $(cat "$TMP/gh-was-called")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
