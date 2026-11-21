#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
source "$(dirname "${BASH_SOURCE[0]}")/lib/fix-md-landing.sh"  # #242: one landing section, reached from every flow
# tests/test_spot_check_wiring.sh — spot-check (#197) runs at every merge-mode close
# and nowhere else that matters, and its human side is registered on every platform.
#
# Merge mode closes an issue as done at these sites, and each must call the selector
# AFTER a successful close: the merge job (every fix.md merge site launches it with
# --own-issue), the post-merge sentinel closing a parked issue, and the decomposed-parent
# rollup in fix.md (skipped in pr mode). The `spot-check` label is reconciled but is
# never a blocking or claim-filter label: spot-check items are closed and never gate.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

SC='spot-check-select.sh'

# ── The merge job: inside the close-success branch, after the close ────────────
for d in plugins/autocoder/scripts .agent/scripts; do
  M="$ROOT/$d/merge-to-integration.sh"
  CLOSE_BLOCK=$(awk '/if issue_close "\$ISSUE_NUM" --comment "✅ \*\*Issue Resolved\*\*/ {on=1}
                     on {print}
                     on && /^    else$/ {exit}' "$M")
  printf '%s' "$CLOSE_BLOCK" | grep -q "\"\${_MTI_DIR}/${SC}\" --issue \"\$ISSUE_NUM\" --sha \"\$landed\"" \
    && ok "$d/merge-to-integration.sh samples the issue it just closed" \
    || bad "$d/merge-to-integration.sh does not call ${SC} in its close-success branch"
  printf '%s' "$CLOSE_BLOCK" | grep -A1 "${SC}" | grep -q -- '--apply || true' \
    && ok "$d/merge-to-integration.sh: the call applies and can never fail the job" \
    || bad "$d/merge-to-integration.sh: the ${SC} call is not '--apply || true'"
  [ "$(grep -c "${SC}" "$M")" -eq 1 ] && ok "$d/merge-to-integration.sh calls it exactly once (not on park or escalate)" \
    || bad "$d/merge-to-integration.sh calls ${SC} $(grep -c "${SC}" "$M") times"
done

# ── The sentinel's close of a parked issue ─────────────────────────────────────
for d in plugins/autocoder/scripts .agent/scripts; do
  M="$ROOT/$d/main-sentinel.sh"
  BLOCK=$(awk '/if issue_close "\$num" --comment "✅ \*\*Issue Resolved\*\*/ {on=1} on {print} on && /^    fi$/ {exit}' "$M")
  printf '%s' "$BLOCK" | grep -q "\"\${_MS_DIR}/${SC}\" --issue \"\$num\" --sha \"\$sha\" --apply" \
    && ok "$d/main-sentinel.sh samples a parked issue when it closes it" \
    || bad "$d/main-sentinel.sh does not call ${SC} after closing a parked issue"
done

# ── fix.md: every merge site hands the close to the job; the rollup samples ────
for P in plugins/autocoder/commands/fix.md .agent/workflows/fix.md; do
  F="$ROOT/$P"
  # A merge site either hands the close to the job (--own-issue; the job samples) or
  # closes inline (the Antigravity mirror), and then must sample right after its close.
  OWN=$(grep -c -- '--own-issue; then' "$F")
  INLINE=$(grep -cE '^ *if issue_close "\$(ISSUE_NUM|ENHANCE_NUM|LAND_NUM)" --comment "✅ \*\*' "$F")
  BARE=$(grep -cE '^ *issue_close "\$(ISSUE_NUM|ENHANCE_NUM|LAND_NUM)" --comment "✅ \*\*' "$F")
  INLINE_SAMPLED=$(grep -cE "\"\\\$\{SCRIPT_DIR\}/${SC}\" --issue \"\\\$(ISSUE_NUM|ENHANCE_NUM|LAND_NUM)\"" "$F")
  PROBLEMS=$(fix_md_landing_problems "$F")
  [ -z "$PROBLEMS" ] && ok "$P lands every flow through one section (#242)" || bad "$P landing section: $PROBLEMS"
  [ $((OWN + INLINE)) -eq 1 ] && ok "$P: the one merge site is covered (job-owned: $OWN, inline: $INLINE)" \
    || bad "$P: $((OWN + INLINE)) merge site(s) reach spot-check, want 1 (#242)"
  [ "$BARE" -eq 0 ] && ok "$P: no merge site closes an issue without sampling it" \
    || bad "$P: $BARE close(s) of ISSUE_NUM/ENHANCE_NUM are not followed by the selector"
  [ "$INLINE_SAMPLED" -eq "$INLINE" ] && ok "$P: each inline close calls the selector ($INLINE)" \
    || bad "$P: $INLINE inline close(s) but $INLINE_SAMPLED selector call(s)"
  ROLLUP=$(awk '/if issue_close "\$PARENT_ISSUE"/ {on=1} on {print} on && /^      fi$/ {exit}' "$F")
  printf '%s' "$ROLLUP" | grep -q '\[ "\$MERGE_MODE" != "pr" \]' \
    && ok "$P: the rollup samples only outside pr mode" || bad "$P: the rollup's spot-check is not skipped in pr mode"
  printf '%s' "$ROLLUP" | grep -q "\"\${SCRIPT_DIR}/${SC}\" --issue \"\$PARENT_ISSUE\"" \
    && ok "$P: the decomposed-parent rollup calls the selector after its close" \
    || bad "$P: the rollup close does not call ${SC}"
  [ "$(grep -c "${SC}" "$F")" -eq $((1 + INLINE)) ] && ok "$P: no other site calls the selector (pr-mode sites stay untouched)" \
    || bad "$P: ${SC} appears $(grep -c "${SC}" "$F") times, want $((1 + INLINE))"

  # The label is reconciled...
  grep -E '^ *for label in ' "$F" | grep -q '"spot-check:' \
    && ok "$P: the spot-check label is in the label reconciliation block" \
    || bad "$P: spot-check missing from the label reconciliation block"
  # ...but is never a blocking label or a claimable-queue filter.
  if grep -nE "needs-approval" "$F" | grep -v '^ *[0-9]*: *for label in ' | grep -v 'for label in' | grep -q 'spot-check'; then
    bad "$P: spot-check appears in a blocking/claim-filter list"
  else
    ok "$P: spot-check is not a blocking or claim-filter label"
  fi
done
for f in fix-loop-gate.sh issues-gh.sh issues-file.py issue-fns.sh claimed-issue-numbers.sh; do
  [ -f "$ROOT/plugins/autocoder/scripts/$f" ] || continue
  grep -q 'spot-check' "$ROOT/plugins/autocoder/scripts/$f" \
    && bad "$f mentions spot-check: it must not filter the claimable queue" \
    || ok "$f does not filter on spot-check"
done

# ── The human side: /spot-check, help, monitor-workers, every platform ─────────
for P in plugins/autocoder/commands/spot-check.md .agent/workflows/spot-check.md; do
  F="$ROOT/$P"
  [ -f "$F" ] || { bad "$P missing"; continue; }
  grep -q 'issue_list --state all --label spot-check' "$F" && ok "$P lists with --state all (items are closed)" \
    || bad "$P does not list with --state all"
  for outcome in 'Spot-check: ok' 'Spot-check: follow-up #' 'Spot-check: revert #'; do
    grep -qF "🔎 $outcome" "$F" && ok "$P records '$outcome'" || bad "$P does not record '$outcome'"
  done
  grep -q 'issue_update "\$N" --remove-label spot-check' "$F" && ok "$P removes the label after review" \
    || bad "$P never removes the spot-check label"
  grep -qE 'issue_create --label P1 ' "$F" && ok "$P files a revert as P1" || bad "$P: revert does not create a P1 issue"
done
# Identical apart from the script-dir resolver, which is per platform (test_script_dir_resolver.sh).
_body() { grep -v -e 'fix-loop-gate.sh' -e 'plugins/cache' -e 'if \[ -f "\$d/issue-fns.sh" \]' "$1"; }
[ "$(_body "$ROOT/plugins/autocoder/commands/spot-check.md")" = "$(_body "$ROOT/.agent/workflows/spot-check.md")" ] \
  && ok "spot-check.md matches between plugins/ and .agent/ (resolver aside)" || bad "spot-check.md differs between plugins/ and .agent/"
for P in plugins/autocoder/commands/autocoder-help.md .agent/workflows/autocoder-help.md; do
  grep -q '`/spot-check' "$ROOT/$P" && ok "$P registers /spot-check" || bad "$P does not register /spot-check"
done
grep -q 'commands/spot-check.md' "$ROOT/.factory-plugin/plugins/autocoder/plugin.json" \
  && ok "the Droid manifest ships /spot-check" || bad "the Droid manifest does not list spot-check.md"
for P in codex-plugins/autocoder/skills/autocoder/references/command-mapping.md .factory/skills/autocoder/references/command-mapping.md; do
  grep -q '`/spot-check`' "$ROOT/$P" && ok "$P maps /spot-check" || bad "$P does not map /spot-check"
done
for P in plugins/autocoder/commands/monitor-workers.md .agent/workflows/monitor-workers.md; do
  grep -q 'issue_list --state all --label spot-check' "$ROOT/$P" \
    && ok "$P shows the unreviewed spot-check count" || bad "$P does not count spot-check items"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
