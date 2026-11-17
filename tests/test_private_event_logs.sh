#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_private_event_logs.sh — every test keeps its events out of the real logs (#255).
#
# A test run on its own, outside run-shell-suite.sh, used to append fake claim,
# release and merge events to ~/.local/state/autocoder/*-events.jsonl, which
# /retro reads. tests/lib/private-event-logs.sh points both logs elsewhere; this
# checks that every test sources it and that it does what it says.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRELUDE="$ROOT/tests/lib/private-event-logs.sh"
LIB="$ROOT/plugins/autocoder/scripts"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== every tests/test_*.sh sources the prelude ==="
missing=""
for t in "$ROOT"/tests/test_*.sh; do
  grep -q 'lib/private-event-logs\.sh' "$t" || missing="$missing $(basename "$t")"
done
if [ -z "$missing" ]; then
  ok "all tests source tests/lib/private-event-logs.sh"
else
  bad "missing the prelude:$missing"
  echo "    add as line 2: source \"\$(dirname \"\${BASH_SOURCE[0]}\")/lib/private-event-logs.sh\""
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"

echo "=== a standalone run writes events to private files, not under HOME ==="
out=$(env -u AUTOCODER_ISSUE_EVENTS -u AUTOCODER_MERGE_EVENTS -u XDG_STATE_HOME \
        HOME="$FAKE_HOME" TMPDIR="$TMP" bash -c '
  source "$1"
  source "$2/issue-events-lib.sh"
  issue_event claim 7
  printf "%s\n%s\n" "$AUTOCODER_ISSUE_EVENTS" "$AUTOCODER_MERGE_EVENTS"
' _ "$PRELUDE" "$LIB")
issue_log=$(sed -n 1p <<<"$out"); merge_log=$(sed -n 2p <<<"$out")
case "$issue_log" in "$TMP"/test-issue-events.*) ok "issue log is a private temp file" ;; *) bad "issue log is '$issue_log'" ;; esac
case "$merge_log" in "$TMP"/test-merge-events.*) ok "merge log is a private temp file" ;; *) bad "merge log is '$merge_log'" ;; esac
if grep -q '"claim"' "$issue_log" 2>/dev/null; then ok "the event went to the private log"; else bad "no claim event in '$issue_log'"; fi
if [ -z "$(find "$FAKE_HOME" -name '*events.jsonl' 2>/dev/null)" ]; then
  ok "nothing written under HOME"
else
  bad "event log written under HOME: $(find "$FAKE_HOME" -name '*events.jsonl')"
fi

echo "=== a log the caller exported is kept ==="
got=$(AUTOCODER_ISSUE_EVENTS="$TMP/mine.jsonl" AUTOCODER_MERGE_EVENTS="$TMP/m.jsonl" bash -c '
  source "$1"; printf "%s %s" "$AUTOCODER_ISSUE_EVENTS" "$AUTOCODER_MERGE_EVENTS"' _ "$PRELUDE")
[ "$got" = "$TMP/mine.jsonl $TMP/m.jsonl" ] && ok "inherited paths kept" || bad "inherited paths replaced: $got"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
