#!/bin/bash
# tests/test_issues_gh_search.sh — guards the GitHub backend's blocking-label
# search syntax.
#
# `no:label` is a valueless GitHub qualifier meaning "issue has no labels at
# all". Writing `no:label "working"` therefore matches only unlabeled issues,
# so every labeled issue is filtered out and the autocoder loop idles forever.
# Per-label exclusion must use `-label:"working"`.

PASS=0; FAIL=0
BACKEND="plugins/autocoder/scripts/issues-gh.sh"

# `--` terminates grep's option parsing: the needles start with `-`.
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — '$needle' not in captured search"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "FAIL: $label — '$needle' present in captured search"; FAIL=$((FAIL + 1))
  else
    echo "PASS: $label"; PASS=$((PASS + 1))
  fi
}

# ── Stub `gh` so we can capture the search string the backend emits ────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
# Record the --search argument, then emit output shaped like the real gh so
# the caller's --jq/length handling does not error.
prev=""
for a in "$@"; do
  [ "$prev" = "--search" ] && printf '%s' "$a" > "$GH_SEARCH_CAPTURE"
  prev="$a"
done
if printf '%s\n' "$@" | grep -q -- '--jq'; then echo 0; else echo '[]'; fi
STUB
chmod +x "$TMP/bin/gh"

capture_search() {
  # Runs the backend with the stubbed gh and echoes the captured search string.
  # BASH_ENV="" prevents ~/.bashenv (which prepends ~/bin) from shadowing the stub.
  export GH_SEARCH_CAPTURE="$TMP/search.txt"
  : > "$GH_SEARCH_CAPTURE"
  BASH_ENV="" PATH="$TMP/bin:$PATH" "$BACKEND" "$@" >/dev/null 2>&1
  cat "$GH_SEARCH_CAPTURE"
}

BLOCKING_LABELS=(working needs-design needs-clarification needs-feedback \
                 needs-approval too-complex future proposal awaiting-integration \
                 decomposed blocked)

# ── list --state open must exclude each blocking label ─────────────────────
SEARCH=$(capture_search list --state open --limit 10)
assert_not_contains "list --state open does not use valueless no:label" "no:label" "$SEARCH"
for l in "${BLOCKING_LABELS[@]}"; do
  assert_contains "list --state open excludes $l" "-label:\"$l\"" "$SEARCH"
done

# ── any-claimable must use the same exclusion syntax ───────────────────────
SEARCH=$(capture_search any-claimable)
assert_not_contains "any-claimable does not use valueless no:label" "no:label" "$SEARCH"
assert_contains "any-claimable excludes working" '-label:"working"' "$SEARCH"

# ── blocked search still selects blocking labels (positive form) ───────────
SEARCH=$(capture_search list --state blocked --limit 10)
assert_contains "list --state blocked selects needs-design" 'label:"needs-design"' "$SEARCH"
assert_not_contains "list --state blocked does not negate needs-design" '-label:"needs-design"' "$SEARCH"

# awaiting-integration means "done, waiting to be merged" — NOT "blocked on a
# human decision". It must suppress the issue from the claimable queue without
# showing up in /review-blocked.
assert_not_contains "blocked search excludes awaiting-integration" 'awaiting-integration' "$SEARCH"

# `decomposed` is the same category: an umbrella is waiting on its own sub-tasks,
# not on a human, so it must be unclaimable without cluttering /review-blocked.
assert_not_contains "blocked search excludes decomposed" 'decomposed' "$SEARCH"

# `blocked` IS a human/prerequisite gate — it belongs in /review-blocked. NOTE
# this asserts the search STRING only: against real GitHub the whole OR-chain
# returns 0 rows (see the KNOWN DEFECT comment on BLOCKED_LABEL_SEARCH), so a
# green here does not mean /review-blocked sees anything.
assert_contains "list --state blocked selects blocked" 'label:"blocked"' "$SEARCH"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
