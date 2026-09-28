#!/bin/bash
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
  {"number": 1, "title": "unlabeled",            "body": "", "labels": [], "state": "OPEN"},
  {"number": 2, "title": "already working",      "body": "", "labels": [{"name":"working"}], "state": "OPEN"},
  {"number": 3, "title": "needs-design",         "body": "", "labels": [{"name":"needs-design"}], "state": "OPEN"},
  {"number": 4, "title": "awaiting-integration", "body": "", "labels": [{"name":"awaiting-integration"}], "state": "OPEN"},
  {"number": 5, "title": "P0 bug, no blockers",  "body": "", "labels": [{"name":"P0"},{"name":"bug"}], "state": "OPEN"}
]
EOF

cat > "$TMP/bin/gh" <<STUB
#!/bin/bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  cat "$TMP/issues.json"
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

# ── blocked: positive blocking labels, awaiting-integration excluded ──────
OUT=$(run_backend list --state blocked)
assert_numbers "list --state blocked selects only #3, not #4 (awaiting-integration)" "[3]" "$OUT"

# ── any-claimable: true when an unblocked issue exists ─────────────────────
assert_exit "any-claimable is true (0) when #1/#5 are unblocked" 0 run_backend any-claimable

# ── --limit applies AFTER filtering, not to the raw fetch ──────────────────
OUT=$(run_backend list --state open --limit 1)
assert_numbers "list --state open --limit 1 returns exactly one filtered result" "[1]" "$OUT"

# ── the approval gate (AUTOCODER_REQUIRED_LABEL) narrows open further ──────
OUT=$(AUTOCODER_REQUIRED_LABEL=swarm run_backend list --state open)
assert_numbers "list --state open with a required label excludes unapproved #1 and #5" "[]" "$OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
