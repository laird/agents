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

echo "=== every tests/test_*.sh sources the prelude on line 2 ==="
missing=""
for t in "$ROOT"/tests/test_*.sh; do
  sed -n 2p "$t" | grep -q '^source .*/lib/private-event-logs\.sh"' || missing="$missing $(basename "$t")"
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

echo "=== a failed mktemp falls back to /tmp, never an empty path ==="
got=$(env -u AUTOCODER_ISSUE_EVENTS -u AUTOCODER_MERGE_EVENTS TMPDIR="$TMP/no-such-dir" bash -c '
  source "$1"; printf "%s" "$AUTOCODER_ISSUE_EVENTS"' _ "$PRELUDE")
case "$got" in /tmp/test-issue-events.*) ok "fell back to /tmp"; rm -f -- "$got" ;; *) bad "issue log is '$got'" ;; esac

echo "=== a log the caller exported is kept ==="
got=$(AUTOCODER_ISSUE_EVENTS="$TMP/mine.jsonl" AUTOCODER_MERGE_EVENTS="$TMP/m.jsonl" bash -c '
  source "$1"; printf "%s %s" "$AUTOCODER_ISSUE_EVENTS" "$AUTOCODER_MERGE_EVENTS"' _ "$PRELUDE")
[ "$got" = "$TMP/mine.jsonl $TMP/m.jsonl" ] && ok "inherited paths kept" || bad "inherited paths replaced: $got"

echo "=== the merge job's context variables are dropped (#327) ==="
JOB_VARS="AUTOCODER_GATE_RETEST_FILES AUTOCODER_LANDING_REPO AUTOCODER_LANDING_BATCH AUTOCODER_LANDING_MEMBERS AUTOCODER_STAGE_TIMINGS_FILE AUTOCODER_SCRIPTS_DIR AUTOCODER_MERGE_ATTEMPT"
got=$(env $(for v in $JOB_VARS; do printf '%s=leak ' "$v"; done) TMPDIR="$TMP" bash -c '
  source "$1"; for v in $2; do [ -z "${!v+set}" ] || printf "%s " "$v"; done' _ "$PRELUDE" "$JOB_VARS")
[ -z "$got" ] && ok "the prelude drops every merge-job variable" || bad "still set after the prelude: $got"
got=$(env $(for v in $JOB_VARS; do printf '%s=leak ' "$v"; done) bash -c '
  source "$1"; for v in $2; do [ -z "${!v+set}" ] || printf "%s " "$v"; done' _ "$ROOT/tests/lib/merge-job-env.sh" "$JOB_VARS")
[ -z "$got" ] && ok "merge-job-env.sh drops every merge-job variable" || bad "merge-job-env.sh left: $got"
grep -q '^source "$ROOT/tests/lib/merge-job-env.sh"' "$ROOT/tests/run-shell-suite.sh" \
  && ok "run-shell-suite.sh drops them for the whole suite (pytest files too)" || bad "run-shell-suite.sh does not source merge-job-env.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
