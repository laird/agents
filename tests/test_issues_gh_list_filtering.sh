#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_issues_gh_list_filtering.sh — guards the GitHub backend's
# open/working/blocked label filtering.
#
# #2783: `list --state open|working|blocked` used to build a `gh issue list
# --search '...'` query, which hits GitHub's index-backed /search/issues
# endpoint. That index lags real-time label writes under label churn, so the
# gate repeatedly handed out issues a fresh direct read already showed
# `working`. The fix replaced `--search` with a direct `gh issue list
# --state open --json ...` read, filtered client-side with jq — this test
# exercises that filtering against a fixed, fully-labeled issue set so a
# regression (e.g. reintroducing an index-backed query, or a jq filter typo
# that lets a blocking label slip through) is caught without needing a live
# GitHub search index at all.
#
# Also guards the historical `no:label` bug this file used to test directly:
# `no:label "X"` is a valueless qualifier meaning "no labels at all", not
# "excludes label X" — if that shape regressed back in (e.g. testing
# `.labels == []` instead of set membership), every real, labeled issue
# would be wrongly excluded. Covered here by issue #5 below, which carries
# unrelated labels and must still appear in `open`.

PASS=0; FAIL=0
BACKEND="plugins/autocoder/scripts/issues-gh.sh"

assert_numbers() {
  local label="$1" expected="$2" actual_json="$3"
  local actual
  actual=$(printf '%s' "$actual_json" | jq -c '[.[].number] | sort')
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — expected $expected, got $actual"; FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local label="$1" expected_code="$2"; shift 2
  "$@" >/dev/null 2>&1
  local actual_code=$?
  if [ "$actual_code" -eq "$expected_code" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — expected exit $expected_code, got $actual_code"; FAIL=$((FAIL + 1))
  fi
}

# ── Stub `gh` so no network/token/live search-index behavior is involved ───
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Fixed fixture: unlabeled, working, each single blocking label,
# awaiting-integration, and a real-world "unlabeled but has other labels"
# issue (regression guard for the old no:label bug — see file header).
cat > "$TMP/issues.json" <<'EOF'
[
  {"number": 1,  "title": "unlabeled",            "body": "", "labels": [], "state": "OPEN"},
  {"number": 2,  "title": "already working",      "body": "", "labels": [{"name":"working"}], "state": "OPEN"},
  {"number": 3,  "title": "needs-design",         "body": "", "labels": [{"name":"needs-design"}], "state": "OPEN"},
  {"number": 4,  "title": "awaiting-integration", "body": "", "labels": [{"name":"awaiting-integration"}], "state": "OPEN"},
  {"number": 5,  "title": "P0 bug, no blockers",  "body": "", "labels": [{"name":"P0"},{"name":"bug"}], "state": "OPEN"},
  {"number": 6,  "title": "merging",              "body": "", "labels": [{"name":"merging"}], "state": "OPEN"},
  {"number": 7,  "title": "needs-clarification",  "body": "", "labels": [{"name":"needs-clarification"}], "state": "OPEN"},
  {"number": 8,  "title": "needs-feedback",       "body": "", "labels": [{"name":"needs-feedback"}], "state": "OPEN"},
  {"number": 9,  "title": "needs-approval",       "body": "", "labels": [{"name":"needs-approval"}], "state": "OPEN"},
  {"number": 10, "title": "too-complex",          "body": "", "labels": [{"name":"too-complex"}], "state": "OPEN"},
  {"number": 11, "title": "future",               "body": "", "labels": [{"name":"future"}], "state": "OPEN"},
  {"number": 12, "title": "proposal",             "body": "", "labels": [{"name":"proposal"}], "state": "OPEN"}
]
EOF
# Only lock labels, nothing a worker may claim.
cat > "$TMP/issues_locked.json" <<'EOF'
[
  {"number": 2, "title": "already working", "body": "", "labels": [{"name":"working"}], "state": "OPEN"},
  {"number": 6, "title": "merging",         "body": "", "labels": [{"name":"merging"}], "state": "OPEN"}
]
EOF

cat > "$TMP/bin/gh" <<STUB
#!/bin/bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  # GH_TRUNCATE=1 models real gh paging: return only the first --limit issues,
  # 30 when no --limit is passed (gh's own default). See #140.
  if [ -n "\${GH_TRUNCATE:-}" ]; then
    lim=30
    while [ \$# -gt 0 ]; do [ "\$1" = "--limit" ] && lim="\$2"; shift; done
    jq --argjson n "\$lim" '.[0:\$n]' "\${GH_FIXTURE:-$TMP/issues.json}"
    exit 0
  fi
  cat "\${GH_FIXTURE:-$TMP/issues.json}"
  exit 0
fi
echo "MOCK: unhandled gh call: \$*" >&2
exit 1
STUB
chmod +x "$TMP/bin/gh"

run_backend() {
  # BASH_ENV="" prevents ~/.bashenv (which prepends ~/bin) from shadowing the stub.
  BASH_ENV="" PATH="$TMP/bin:$PATH" "$BACKEND" "$@"
}

# ── open: excludes every blocking label, keeps unrelated-labeled issues ────
OUT=$(run_backend list --state open)
assert_numbers "list --state open excludes all blocking labels, keeps #1 and #5" "[1,5]" "$OUT"

# ── working: only issues actually carrying the working label ──────────────
OUT=$(run_backend list --state working)
assert_numbers "list --state working selects only #2" "[2]" "$OUT"

# ── blocked: every human-decision label, but not the merge-pipeline locks ─
# `awaiting-integration` (#4) and `merging` (#6) keep an issue out of the
# claimable queue without being blocked on a human, so /review-blocked must
# not surface them.
OUT=$(run_backend list --state blocked)
assert_numbers "list --state blocked selects the human-decision labels, not #4/#6" "[3,7,8,9,10,11,12]" "$OUT"

# ── any-claimable: true when an unblocked issue exists, false otherwise ───
assert_exit "any-claimable is true (0) when #1/#5 are unblocked" 0 run_backend any-claimable
GH_FIXTURE="$TMP/issues_locked.json" assert_exit "any-claimable is false (1) when only working/merging issues remain" 1 run_backend any-claimable

# ── --limit applies AFTER filtering, not to the raw fetch ──────────────────
OUT=$(run_backend list --state open --limit 1)
assert_numbers "list --state open --limit 1 returns exactly one filtered result" "[1]" "$OUT"

# ── the approval gate (AUTOCODER_REQUIRED_LABEL) narrows open further ──────
OUT=$(AUTOCODER_REQUIRED_LABEL=swarm run_backend list --state open)
assert_numbers "list --state open with a required label excludes unapproved #1 and #5" "[]" "$OUT"

# ── #140: no bucket may inherit gh's default page size of 30 ──────────────
# Without an explicit --limit, `gh issue list` returns 30 issues, so a swarm
# with a larger backlog never saw the rest: an unblocked P0 past the page was
# invisible and workers reported IDLE_NO_WORK_AVAILABLE. Fixture: 40 claimed
# issues, then an unblocked P0 (#41) and a needs-design issue (#42), both past
# gh's default page.
jq -n '[range(1;41) | {number: ., title: "claimed", body: "", labels: [{name:"working"}], state: "OPEN"}]
       + [{number: 41, title: "unblocked P0 past page 1", body: "", labels: [{name:"P0"}], state: "OPEN"},
          {number: 42, title: "blocked past page 1", body: "", labels: [{name:"needs-design"}], state: "OPEN"}]' \
  > "$TMP/issues_many.json"

OUT=$(GH_TRUNCATE=1 GH_FIXTURE="$TMP/issues_many.json" run_backend list --state open)
assert_numbers "#140: list --state open sees an unblocked P0 beyond gh's default 30" "[41]" "$OUT"
OUT=$(GH_TRUNCATE=1 GH_FIXTURE="$TMP/issues_many.json" run_backend list --state working)
COUNT=$(printf '%s' "$OUT" | jq length)
if [ "$COUNT" = "40" ]; then echo "PASS: #140: list --state working reports all 40 claims"; PASS=$((PASS + 1))
else echo "FAIL: #140: list --state working reports all 40 claims — got $COUNT"; FAIL=$((FAIL + 1)); fi
OUT=$(GH_TRUNCATE=1 GH_FIXTURE="$TMP/issues_many.json" run_backend list --state blocked)
assert_numbers "#140: list --state blocked sees a blocked issue beyond gh's default 30" "[42]" "$OUT"
GH_TRUNCATE=1 GH_FIXTURE="$TMP/issues_many.json" assert_exit "#140: any-claimable finds the P0 beyond gh's default 30" 0 run_backend any-claimable
for st in closed all; do
  OUT=$(GH_TRUNCATE=1 GH_FIXTURE="$TMP/issues_many.json" run_backend list --state "$st")
  COUNT=$(printf '%s' "$OUT" | jq length)
  if [ "$COUNT" = "42" ]; then echo "PASS: #140: list --state $st is not capped at 30"; PASS=$((PASS + 1))
  else echo "FAIL: #140: list --state $st is not capped at 30 — got $COUNT"; FAIL=$((FAIL + 1)); fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
