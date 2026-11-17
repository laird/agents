#!/bin/bash
# tests/test_issue_spec.sh — issue-spec.sh: the spec a /fix worker builds from
# is the issue body PLUS its comment thread, minus autocoder bookkeeping (#134).
#
# Before #134, /fix read `.body` only, so a correction posted as a comment was
# structurally invisible: the worker built the stalest spec on the page. This
# asserts the helper carries comments, in order, filters only claim/start
# markers, and that both /fix mirrors actually use it.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SPEC="$ROOT/plugins/autocoder/scripts/issue-spec.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
has()    { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 — missing '$3'"; fi; }
hasnt()  { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 — unexpected '$3'"; else ok "$1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── GitHub-shaped issue: author + timestamp, bookkeeping mixed in ─────────
cat > "$TMP/gh.json" <<'EOF'
{
  "number": 1729, "title": "t", "state": "OPEN", "labels": [],
  "body": "Use onConflict=replace (the default).\n",
  "comments": [
    {"author": {"login": "laird"}, "createdAt": "2026-01-01T00:00:00Z", "body": "Triage: P1 — x"},
    {"author": {"login": "w1"}, "createdAt": "2026-01-01T00:01:00Z", "body": "🔒 claim nuc-1 1794875270199"},
    {"author": {"login": "w3"}, "createdAt": "2026-01-01T00:01:30Z", "body": "🔒 claim nuc-77 1794875270299 start=1794870000 wt=/home/u/src/agents wt-3"},
    {"author": {"login": "w1"}, "createdAt": "2026-01-01T00:02:00Z", "body": "🔒 [autocoder-claim] Starting fix for issue #1729 — lock established"},
    {"author": {"login": "w1"}, "createdAt": "2026-01-01T00:03:00Z", "body": "🤖 **Automated Fix Started**\n\nBranch: feature/issue-1729"},
    {"author": {"login": "reviewer"}, "createdAt": "2026-01-01T00:14:00Z", "body": "Correction: onConflict=replace is NOT the default. Do not recommend folderPath."},
    {"author": {"login": "w2"}, "createdAt": "2026-01-01T00:15:00Z", "body": "   "}
  ]
}
EOF
OUT=$("$SPEC" --json "$TMP/gh.json"); RC=$?
[ "$RC" -eq 0 ] && ok "formats a GitHub-shaped issue (rc 0)" || bad "formats a GitHub-shaped issue — rc $RC"
has   "body is included" "$OUT" "Use onConflict=replace (the default)."
has   "a correcting comment is included" "$OUT" "Correction: onConflict=replace is NOT the default."
has   "comment carries its author and time" "$OUT" "by reviewer at 2026-01-01T00:14:00Z"
has   "a human triage comment is kept" "$OUT" "Triage: P1"
has   "precedence rule is stated" "$OUT" "a later comment overrides the body"
hasnt "gate claim marker is filtered" "$OUT" "🔒 claim nuc-1"
hasnt "gate claim marker with owner fields is filtered (#202)" "$OUT" "🔒 claim nuc-77"
hasnt "[autocoder-claim] marker is filtered" "$OUT" "autocoder-claim"
hasnt "work-started marker is filtered" "$OUT" "Automated Fix Started"
hasnt "blank comments are dropped" "$OUT" "comment 3 by"
body_line=$(printf '%s\n' "$OUT" | grep -n "onConflict=replace (the default)" | head -1 | cut -d: -f1)
corr_line=$(printf '%s\n' "$OUT" | grep -n "Correction:" | head -1 | cut -d: -f1)
if [ -n "$body_line" ] && [ -n "$corr_line" ] && [ "$body_line" -lt "$corr_line" ]; then
  ok "body comes before comments (oldest first)"
else bad "body comes before comments — body@$body_line correction@$corr_line"; fi

# A human comment that merely MENTIONS a claim is spec, not bookkeeping.
cat > "$TMP/mention.json" <<'EOF'
{"body": "b", "comments": [{"body": "Note: the 🔒 claim comment format changed; update the parser."}]}
EOF
has "a comment that only mentions a claim is kept" "$("$SPEC" --json "$TMP/mention.json")" "claim comment format changed"
cat > "$TMP/quote.json" <<'EOF'
{"body": "b", "comments": [{"body": "The Automated Fix Started comment above was wrong; use v2."}]}
EOF
has "a comment quoting a marker phrase mid-text is kept" "$("$SPEC" --json "$TMP/quote.json")" "use v2"

# ── Jira/ADO-shaped: comment bodies only, no author or time ───────────────
echo '{"body":"spec","comments":[{"body":"narrow scope to X"}]}' > "$TMP/jira.json"
OUT=$("$SPEC" --json - < "$TMP/jira.json")
has "body-only comments are carried (stdin)" "$OUT" "narrow scope to X"
has "missing author degrades to 'unknown'" "$OUT" "comment 1 by unknown"

# ── No comments: output is exactly the body ───────────────────────────────
OUT=$(echo '{"body":"just the body\n\n","comments":[]}' | "$SPEC" --json -)
[ "$OUT" = "just the body" ] && ok "no comments → body only, no thread header" || bad "no comments → got '$OUT'"
OUT=$(echo '{"body":null}' | "$SPEC" --json -); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "null body and absent comments are tolerated" || bad "null body — rc $RC out '$OUT'"

# ── Errors ────────────────────────────────────────────────────────────────
"$SPEC" >/dev/null 2>&1; [ $? -eq 1 ] && ok "no args is a usage error" || bad "no args should exit 1"
"$SPEC" abc >/dev/null 2>&1; [ $? -eq 1 ] && ok "non-numeric issue is a usage error" || bad "non-numeric should exit 1"
echo 'not json' | "$SPEC" --json - >/dev/null 2>&1; [ $? -eq 2 ] && ok "malformed JSON exits 2" || bad "malformed JSON should exit 2"

# ── End to end on the file backend (comments fold into the body) ──────────
ISSUES_DIR="$TMP/.issues"
mkdir -p "$ISSUES_DIR/open" "$ISSUES_DIR/working" "$ISSUES_DIR/blocked" "$ISSUES_DIR/closed" "$TMP/bin"
git -C "$TMP" init -q
printf '{ "issueSource": "file", "issueDir": "%s" }\n' "$ISSUES_DIR" > "$TMP/.autocoder.json"
printf '#!/bin/bash\nexit 97\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
printf -- '---\nnumber: 7\ntitle: t\nlabels: [P1]\nstatus: open\n---\noriginal spec\n' > "$ISSUES_DIR/open/007.md"
(cd "$TMP" && PATH="$TMP/bin:$PATH" bash -c "source '$ROOT/plugins/autocoder/scripts/issue-fns.sh'; issue_comment 7 --body 'use v2 endpoint instead'") >/dev/null 2>&1
OUT=$(cd "$TMP" && PATH="$TMP/bin:$PATH" "$SPEC" 7 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "fetches by number through the configured backend" || bad "fetch by number — rc $RC: $OUT"
has "file backend: body present" "$OUT" "original spec"
has "file backend: comment present" "$OUT" "use v2 endpoint instead"

# ── Both /fix mirrors use it, and do not truncate the spec ────────────────
for f in plugins/autocoder/commands/fix.md .agent/workflows/fix.md; do
  n=$(grep -c 'issue-spec.sh" "\$\(ISSUE\|ENHANCE\)_NUM"' "$ROOT/$f")
  [ "$n" -ge 2 ] && ok "$f reads the spec for bugs and enhancements" || bad "$f — issue-spec.sh used $n times, want ≥2"
  if grep -q 'echo "\$ISSUE_BODY" | head' "$ROOT/$f"; then bad "$f still truncates the body with head"
  else ok "$f no longer truncates the spec"; fi
  grep -qF 'a later comment overrides the body' "$ROOT/$f" && ok "$f states the precedence rule" \
    || bad "$f lacks the precedence rule"
done
[ -f "$ROOT/.agent/scripts/issue-spec.sh" ] && cmp -s "$SPEC" "$ROOT/.agent/scripts/issue-spec.sh" \
  && ok ".agent/scripts carries an identical issue-spec.sh" || bad ".agent/scripts/issue-spec.sh missing or stale"

# ── Parent sub-task list comes from the decomposition comment ─────────────
# Mirrors the jq in fix.md's "Monitoring Decomposed Issues" block.
SUBTASK_JQ='([(.comments // [])[] | (.body // "") | select(test("Issue Decomposed into Sub-Tasks"))] | last) // (.body // "")'
for f in plugins/autocoder/commands/fix.md .agent/workflows/fix.md; do
  grep -qF 'select(test("Issue Decomposed into Sub-Tasks"))] | last)' "$ROOT/$f" \
    && ok "$f reads sub-tasks from the decomposition comment" || bad "$f sub-task jq drifted from this test"
done
cat > "$TMP/parent.json" <<'EOF'
{"body": "See #3 and #4 for background.", "comments": [
  {"body": "🔍 **Issue Decomposed into Sub-Tasks**\n\n- [ ] #10\n- [ ] #11"},
  {"body": "🔍 **Issue Decomposed into Sub-Tasks**\n\n- [ ] #10\n- [x] #12"}
]}
EOF
GOT=$(jq -r "$SUBTASK_JQ" "$TMP/parent.json" | grep -oE '^- \[[ xX]\] #[0-9]+' | grep -oE '[0-9]+$' | tr '\n' ' ')
[ "$GOT" = "10 12 " ] && ok "sub-tasks come from the latest decomposition comment, not body refs" \
  || bad "sub-task list — got '$GOT', want '10 12 '"
SUB=$(printf 'x\n## Sub-task of #42\ny Sub-task of #43\n' | sed -nE 's/.*Sub-task of #([0-9]+).*/\1/p' | head -1)
[ "$SUB" = "42" ] && ok "parent number extraction yields the number" || bad "parent extraction got '$SUB'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
