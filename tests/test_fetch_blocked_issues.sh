#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_fetch_blocked_issues.sh — fetch-blocked-issues.sh must find the
# blocked issues (#145).
#
# It listed `--state open`, the claimable queue, which every backend builds by
# EXCLUDING the blocking labels, and then filtered that list for blocking
# labels. It always found none, so /review-blocked said "No blocked issues
# found!" on repos with dozens. Its --label / --priority / issue-number filters
# were also dead: the script exported them after the Python that reads them.
#
# Runs the real script against the real GitHub backend with `gh` stubbed.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/plugins/autocoder/scripts/fetch-blocked-issues.sh"

check() {  # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS + 1))
  else echo "FAIL: $1 — expected $2, got $3"; FAIL=$((FAIL + 1)); fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo"

cat > "$TMP/issues.json" <<'EOF'
[
  {"number": 1,  "title": "claimable",            "body": "", "labels": [{"name":"P1"}], "state": "OPEN"},
  {"number": 2,  "title": "working",              "body": "", "labels": [{"name":"working"}], "state": "OPEN"},
  {"number": 3,  "title": "needs-design P1",      "body": "", "labels": [{"name":"needs-design"},{"name":"P1"}], "state": "OPEN"},
  {"number": 4,  "title": "awaiting-integration", "body": "", "labels": [{"name":"awaiting-integration"}], "state": "OPEN"},
  {"number": 6,  "title": "merging",              "body": "", "labels": [{"name":"merging"}], "state": "OPEN"},
  {"number": 7,  "title": "needs-clarification",  "body": "", "labels": [{"name":"needs-clarification"},{"name":"P2"}], "state": "OPEN"},
  {"number": 8,  "title": "needs-feedback",       "body": "", "labels": [{"name":"needs-feedback"}], "state": "OPEN"},
  {"number": 9,  "title": "needs-approval",       "body": "", "labels": [{"name":"needs-approval"},{"name":"P1"}], "state": "OPEN"},
  {"number": 10, "title": "too-complex",          "body": "", "labels": [{"name":"too-complex"}], "state": "OPEN"},
  {"number": 11, "title": "future",               "body": "", "labels": [{"name":"future"}], "state": "OPEN"},
  {"number": 12, "title": "proposal",             "body": "", "labels": [{"name":"proposal"}], "state": "OPEN"}
]
EOF

cat > "$TMP/bin/gh" <<STUB
#!/bin/bash
case "\$1 \$2" in
  "issue list") cat "$TMP/issues.json"; exit 0 ;;
  "label list") printf '%s\n' needs-approval needs-design needs-clarification too-complex future proposal; exit 0 ;;
  "label create") exit 0 ;;
esac
echo "MOCK: unhandled gh call: \$*" >&2
exit 1
STUB
chmod +x "$TMP/bin/gh"

cd "$TMP/repo" || exit 1
git init -q .
echo '{"issueSource": "github"}' > .autocoder.json

run() {
  # BASH_ENV="" keeps ~/.bashenv from putting a real gh ahead of the stub.
  BASH_ENV="" PATH="$TMP/bin:$PATH" TMPDIR="$TMP" bash "$SCRIPT" "$@" 2>"$TMP/stderr"
}
numbers() { jq -c '[.issues[].number] | sort'; }

OUT=$(run); RC=$?
check "exits 0" 0 "$RC"
check "lists every human-decision blocked issue, not claimable/working/merge locks" \
  "[3,7,8,9,10,11,12]" "$(echo "$OUT" | numbers)"
check "total matches" 7 "$(echo "$OUT" | jq .total)"

check "--label filters" "[3]" "$(run --label needs-design | numbers)"
check "--priority filters" "[3,9]" "$(run --priority P1 | numbers)"
check "--label + --priority filters" "[9]" "$(run --label needs-approval --priority P1 | numbers)"
check "issue number filters" "[7]" "$(run 7 | numbers)"

check "leaves no temp file behind" "" "$(ls "$TMP" | grep fetch-blocked-issues)"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
