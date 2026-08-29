#!/bin/bash
# tests/test_merge_launch_poll.sh — pin #1693's fix: merge-to-integration.sh
# must never run inside a single foreground call. It legitimately takes
# 25-30 minutes, and agent harnesses kill a foreground Bash-tool call at a
# ~2-minute default — a guaranteed failure, not a flake, plus (depending on
# how the kill propagates) either a torn-down merge or an orphaned gate
# subtree (reparented to init) that nothing ever reaps.
#
# merge-launch.sh must:
#   - return almost immediately (well under the 2-minute ceiling) regardless
#     of how long the underlying merge takes
#   - detach the merge into its own session (setsid) so killing the poller
#     that checks on it can never take the merge down too
#   - refuse to start a second job for the same issue while one is running
# merge-poll.sh must:
#   - never block longer than its own --wait slice
#   - report "still running" (75) without reaping state while the job is live
#   - pass through the underlying merge-to-integration.sh exit code (0/1/2)
#     once it finishes, and reap state so a later poll reports "no job" (64)
#
# And the command docs (fix.md) must call merge-launch.sh / merge-poll.sh at
# every merge site, never merge-to-integration.sh directly — that direct call
# is exactly the regression this test exists to catch.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f /tmp/autocoder-merge-19001.* /tmp/autocoder-merge-19002.* /tmp/autocoder-merge-19003.*' EXIT

mkdir -p "$TMP/fakebin"
cp "$SCRIPT_DIR/merge-launch.sh" "$TMP/fakebin/"
cp "$SCRIPT_DIR/merge-poll.sh" "$TMP/fakebin/"

# ── Fixture 1: a slow, successful fake merge (issue #19001) ─────────────────
cat > "$TMP/fakebin/merge-to-integration.sh" <<'FAKE'
#!/bin/bash
echo "fake merge running: $*"
sleep 4
echo "fake merge succeeded"
exit 0
FAKE
chmod +x "$TMP/fakebin/merge-to-integration.sh"

START=$(date +%s 2>/dev/null || echo 0)
LAUNCH_OUT=$(bash "$TMP/fakebin/merge-launch.sh" --feature feature/issue-19001 --issue 19001 --integration master --test-cmd "true" 2>&1)
LAUNCH_RC=$?
END=$(date +%s 2>/dev/null || echo 0)
ELAPSED=$((END - START))

[ "$LAUNCH_RC" -eq 0 ] && ok "merge-launch.sh exits 0 on launch" || bad "merge-launch.sh exit code on launch (got $LAUNCH_RC)"
[ "$ELAPSED" -le 3 ] && ok "merge-launch.sh returns fast, not waiting for the 4s merge (${ELAPSED}s)" \
  || bad "merge-launch.sh blocked for ${ELAPSED}s — defeats the whole point of #1693"

[ -f /tmp/autocoder-merge-19001.pid ] && ok "pidfile written" || bad "pidfile missing"

DUP_OUT=$(bash "$TMP/fakebin/merge-launch.sh" --feature feature/issue-19001 --issue 19001 --integration master --test-cmd "true" 2>&1)
echo "$DUP_OUT" | grep -qi "already running" && ok "duplicate launch refused while job is in flight" \
  || bad "duplicate launch not detected — would double the gate cost (secondary ask in #1693)"

POLL1_OUT=$(bash "$TMP/fakebin/merge-poll.sh" --issue 19001 --wait 1 2>&1); POLL1_RC=$?
[ "$POLL1_RC" -eq 75 ] && ok "merge-poll.sh reports 75 (still running) mid-flight" \
  || bad "merge-poll.sh exit code while running (got $POLL1_RC)"
[ -f /tmp/autocoder-merge-19001.pid ] && ok "poll while running does not reap state" || bad "poll while running reaped state early"

POLL2_OUT=$(bash "$TMP/fakebin/merge-poll.sh" --issue 19001 --wait 5 2>&1); POLL2_RC=$?
[ "$POLL2_RC" -eq 0 ] && ok "merge-poll.sh passes through exit 0 on success" \
  || bad "merge-poll.sh exit code on success (got $POLL2_RC)"
echo "$POLL2_OUT" | grep -q "fake merge succeeded" && ok "merge-poll.sh surfaces the merge's own log output" \
  || bad "merge-poll.sh did not surface log tail"
[ -f /tmp/autocoder-merge-19001.pid ] && bad "poll after completion left state behind (should reap)" \
  || ok "poll after completion reaps pid/exit/log state"

POLL3_RC=0
bash "$TMP/fakebin/merge-poll.sh" --issue 19001 --wait 1 >/dev/null 2>&1 || POLL3_RC=$?
[ "$POLL3_RC" -eq 64 ] && ok "polling a reaped/never-launched issue reports 64" \
  || bad "poll after reap exit code (got $POLL3_RC)"

# ── Fixture 2: a fake merge that fails the combined-tree test re-run ────────
cat > "$TMP/fakebin/merge-to-integration.sh" <<'FAKE'
#!/bin/bash
echo "fake merge: combined-tree tests fail"
sleep 1
exit 2
FAKE
chmod +x "$TMP/fakebin/merge-to-integration.sh"
bash "$TMP/fakebin/merge-launch.sh" --feature feature/issue-19002 --issue 19002 --integration master --test-cmd "true" >/dev/null 2>&1
RC=0
bash "$TMP/fakebin/merge-poll.sh" --issue 19002 --wait 3 >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 2 ] && ok "merge-poll.sh passes through exit 2 (test failure on combined tree)" \
  || bad "merge-poll.sh exit code on test failure (got $RC)"

# ── Fixture 3: killing the POLLER must not kill the detached merge ──────────
cat > "$TMP/fakebin/merge-to-integration.sh" <<'FAKE'
#!/bin/bash
sleep 6
echo done > /dev/null
exit 0
FAKE
chmod +x "$TMP/fakebin/merge-to-integration.sh"
bash "$TMP/fakebin/merge-launch.sh" --feature feature/issue-19003 --issue 19003 --integration master --test-cmd "true" >/dev/null 2>&1
MPID=$(cat /tmp/autocoder-merge-19003.pid 2>/dev/null)

( bash "$TMP/fakebin/merge-poll.sh" --issue 19003 --wait 20 >/dev/null 2>&1 & POLLER=$!; sleep 1; kill -9 -- -"$POLLER" 2>/dev/null; kill -9 "$POLLER" 2>/dev/null )
sleep 0.5
if [ -n "$MPID" ] && kill -0 "$MPID" 2>/dev/null; then
  ok "detached merge survives a killed poller (pid $MPID still alive)"
else
  bad "detached merge died when its poller was killed — the exact orphan/kill bug #1693 reports"
fi
# Let it finish naturally so it doesn't leak past the test.
for _ in 1 2 3 4 5 6 7 8; do kill -0 "$MPID" 2>/dev/null || break; sleep 1; done
kill -0 "$MPID" 2>/dev/null && kill -9 "$MPID" 2>/dev/null || ok "detached merge for #19003 ran to completion on its own"
rm -f /tmp/autocoder-merge-19003.*

# ── Docs: fix.md must launch+poll at every merge site, never call
#          merge-to-integration.sh directly ──────────────────────────────────
FIXMD="$ROOT/plugins/autocoder/commands/fix.md"
if [ -f "$FIXMD" ]; then
  ok "plugins/autocoder/commands/fix.md exists"
  DIRECT_CALLS=$(grep -c '"\${SCRIPT_DIR}/merge-to-integration\.sh"' "$FIXMD")
  [ "$DIRECT_CALLS" -eq 0 ] && ok "fix.md never invokes merge-to-integration.sh directly" \
    || bad "fix.md still calls merge-to-integration.sh directly at $DIRECT_CALLS site(s) — the #1693 regression"

  LAUNCH_CALLS=$(grep -c '"\${SCRIPT_DIR}/merge-launch\.sh"' "$FIXMD")
  POLL_CALLS=$(grep -c '"\${SCRIPT_DIR}/merge-poll\.sh"' "$FIXMD")
  [ "$LAUNCH_CALLS" -ge 3 ] && ok "fix.md launches the merge at all 3 sites (found $LAUNCH_CALLS)" \
    || bad "fix.md missing merge-launch.sh at one or more sites (found $LAUNCH_CALLS, want >= 3)"
  [ "$POLL_CALLS" -ge 3 ] && ok "fix.md polls the merge at all 3 sites (found $POLL_CALLS)" \
    || bad "fix.md missing merge-poll.sh at one or more sites (found $POLL_CALLS, want >= 3)"
else
  bad "plugins/autocoder/commands/fix.md exists"
fi

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
