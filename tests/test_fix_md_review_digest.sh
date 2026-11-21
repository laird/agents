#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
source "$(dirname "${BASH_SOURCE[0]}")/lib/fix-md-landing.sh"  # #242: one landing section, reached from every flow
# tests/test_fix_md_review_digest.sh — every place fix.md publishes work uses the
# review digest renderer (#196), in both platform copies.
#
# Publish sites: each `gh pr create`, each merge-mode close (the merge job's
# --summary-file in the Claude copy; `issue_close` after the local merge in the
# Antigravity copy), and the decomposed-parent rollup close. A site that writes
# its own body, or ignores the renderer's exit status, can ship an unfilled
# placeholder again.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want $2, got $3"; fi; }

for F in plugins/autocoder/commands/fix.md .agent/workflows/fix.md; do
  P="$ROOT/$F"
  [ -f "$P" ] || { bad "$F missing"; continue; }

  # Every `gh pr create` takes its body from a --pr render that stops on failure.
  PRS=$(grep -c '^ *gh pr create' "$P")
  PR_FROM_DIGEST=$(grep -c -- '--body "\${DIGEST}' "$P")
  eq "$F: one gh pr create site, in the shared landing section (#242)" 1 "$PRS"
  PROBLEMS=$(fix_md_landing_problems "$P")
  [ -z "$PROBLEMS" ] && ok "$F lands every flow through one section (#242)" || bad "$F landing section: $PROBLEMS"

  eq "$F: every gh pr create body is \${DIGEST}" "$PRS" "$PR_FROM_DIGEST"
  [ "$(grep -c -- '--sections "\${DIGEST_SECTIONS:?write the Review Digest sections file first}" --pr) \\' "$P")" -eq "$PRS" ] \
    && ok "$F: every PR digest is rendered with --pr" || bad "$F: a PR digest is not rendered with --pr"

  # Merge-mode closes.
  if grep -q 'SUMMARY_FILE=$(mktemp' "$P"; then   # Claude copy: the merge job closes
    SUMS=$(grep -c 'SUMMARY_FILE=$(mktemp' "$P")
    SUM_RENDERS=$(grep -c -- '--sections "\${DIGEST_SECTIONS:?write the Review Digest sections file first}" > "\$SUMMARY_FILE"' "$P")
    eq "$F: one merge summary, in the shared landing section" 1 "$SUMS"
    eq "$F: every merge summary is rendered" "$SUMS" "$SUM_RENDERS"
    CLOSES_LITERAL=$(grep -c "<<\\\\'SUMMARY\\\\'" "$P")
    eq "$F: no hand-written SUMMARY heredoc remains" 0 "$CLOSES_LITERAL"
  else
    CLOSES=$(grep -cE 'issue_close "\$LAND_NUM" --comment "✅ \*\*Issue Resolved' "$P")
    CLOSE_RENDERS=$(grep -c '^ *CLOSE_DIGEST=$(bash "\${SCRIPT_DIR}/render-review-digest.sh"' "$P")
    eq "$F: one resolved close, in the shared landing section" 1 "$CLOSES"
    eq "$F: the close digest is rendered before the review-gated landing" 1 "$CLOSE_RENDERS"
    BODIES=$(grep -A2 -E 'issue_close "\$LAND_NUM" --comment "✅ \*\*Issue Resolved' "$P" | grep -c '^\${CLOSE_DIGEST}$')
    eq "$F: the close body is \${CLOSE_DIGEST}" 1 "$BODIES"
  fi

  # Every render stops the publish on failure (|| { ...; exit 1; } on the next line).
  RENDERS_THAT_STOP=$(grep -A3 'render-review-digest.sh" --issue' "$P" | grep -c '|| { echo "❌ Review digest')
  ALL_ISSUE_RENDERS=$(grep -cE 'render-review-digest\.sh" --issue "\$(ISSUE_NUM|ENHANCE_NUM|LAND_NUM)"' "$P")
  eq "$F: every issue render stops the publish on failure" "$ALL_ISSUE_RENDERS" "$RENDERS_THAT_STOP"

  # Rollup close renders too, and does not close when the render fails.
  grep -q 'ROLLUP=$(bash "\${SCRIPT_DIR}/render-review-digest.sh" --issue "\$PARENT_ISSUE" --base HEAD' "$P" \
    && ok "$F: rollup close is rendered" || bad "$F: rollup close not rendered"
  grep -A12 'ROLLUP=$(bash' "$P" | grep -q 'leaving it open' \
    && ok "$F: rollup stays open when the render fails" || bad "$F: rollup closes without a digest"

  # The sections template uses {{FILL: slots, which the renderer rejects, so a
  # worker who forgets one cannot ship it (a bare <...> line would pass).
  FILLS=$(sed -n '/cat > "\$DIGEST_SECTIONS" <<.DIGEST./,/^DIGEST$/p' "$P" | grep -c '{{FILL:')
  [ "$FILLS" -ge 4 ] && ok "$F: digest template slots are {{FILL: (found $FILLS)" || bad "$F: digest template has $FILLS {{FILL: slots, want 4"

  # REVIEW FIT: scope gate criterion + post-implementation label, never split.
  grep -q '#   3. REVIEW FIT' "$P" && ok "$F: REVIEW FIT is in the scope gate" || bad "$F: no REVIEW FIT in the scope gate"
  grep -q 'add-label "needs-review-focus"' "$P" && ok "$F: over-size work gets needs-review-focus" || bad "$F: needs-review-focus never applied"
  grep -q '"needs-review-focus:' "$P" && ok "$F: needs-review-focus is reconciled as a label" || bad "$F: needs-review-focus not in label reconciliation"
  # It must never gate claiming.
  if grep -E 'needs-approval.*needs-review-focus|needs-review-focus.*needs-approval' "$P" | grep -v '"needs-review-focus:' | grep -q .; then
    bad "$F: needs-review-focus appears in a blocking/claimable filter"
  else
    ok "$F: needs-review-focus is not a blocking label"
  fi
done

LEGACY=$(grep -rn '\[Detailed explanation\|\[Detailed analysis\]\|\[What was implemented\]' \
  "$ROOT/plugins/autocoder/commands" "$ROOT/.agent/workflows" | wc -l)
eq "no legacy body placeholders remain in commands/ or .agent/workflows/" 0 "$LEGACY"

# The renderer ships beside the scripts each copy resolves.
for d in plugins/autocoder/scripts .agent/scripts; do
  [ -x "$ROOT/$d/render-review-digest.sh" ] && ok "$d/render-review-digest.sh present" || bad "$d/render-review-digest.sh missing"
done
cmp -s "$ROOT/plugins/autocoder/scripts/render-review-digest.sh" "$ROOT/.agent/scripts/render-review-digest.sh" \
  && ok ".agent renderer is identical to the plugin's" || bad ".agent renderer differs"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
