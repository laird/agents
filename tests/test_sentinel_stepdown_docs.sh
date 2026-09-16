#!/bin/bash
# tests/test_sentinel_stepdown_docs.sh — doc contracts for the idle-sentinel
# step-down protocol (spec: docs/specs/2026-09-16-idle-sentinel-design.md).
#
# The sentinel and the manager protocol docs share machine-parsed formats and
# file paths: the heartbeat file, the health-alert handshake, the quiescence
# counter, and the sentinel-standing fence. idle-sentinel.sh parses what the
# command docs tell the manager to write, so drift between them silently
# breaks wake predicates and wedge detection. These are deliberately cheap
# substring checks on the exact tokens both sides must agree on — not prose
# assertions — so wording can change freely as long as the contracts hold.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT" || exit 1

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

MW="plugins/autocoder/commands/monitor-workers.md"
MH="plugins/autocoder/commands/manager-handoff.md"
MR="plugins/autocoder/commands/manager-resume.md"
IS="plugins/autocoder/scripts/idle-sentinel.sh"
INSTALL="plugins/autocoder/scripts/install.sh"

for f in "$MW" "$MH" "$MR" "$IS" "$INSTALL"; do
  [ -f "$f" ] || { bad "missing file: $f"; }
done

# ── monitor-workers.md: the manager side of the sentinel handshake ─────────
grep -q '\.autocoder/manager-heartbeat' "$MW" \
  && ok "monitor-workers names the heartbeat file path" \
  || bad "monitor-workers lacks .autocoder/manager-heartbeat"
grep -q 'cat \.autocoder/health-alert' "$MW" \
  && ok "monitor-workers reads the health-alert file" \
  || bad "monitor-workers lacks the health-alert read step"
grep -q 'rm -f \.autocoder/health-alert' "$MW" \
  && ok "monitor-workers deletes the health-alert after acting (read+act+delete)" \
  || bad "monitor-workers lacks the health-alert delete step"
grep -q '\.autocoder/quiescent-iterations' "$MW" \
  && ok "monitor-workers persists the quiescence counter file" \
  || bad "monitor-workers lacks .autocoder/quiescent-iterations"
grep -q 'rm -f \.autocoder/quiescent-iterations' "$MW" \
  && ok "monitor-workers deletes the counter at step-down (R2-F8)" \
  || bad "monitor-workers lacks the counter deletion step"

# Step-down must RETAIN the manifest manager entry: only the sentinel clears
# it, after verifying the recorded identity is dead (R2-F6).
grep -q 'Do NOT clear the swarm manifest' "$MW" \
  && ok "monitor-workers step-down retains the manifest manager entry" \
  || bad "monitor-workers lacks the do-not-clear-manifest step-down rule"
grep -Eq 'manifest_set_manager.*null' "$MW" \
  && bad "monitor-workers instructs clearing the manifest manager entry (sentinel-owned)" \
  || ok "monitor-workers never instructs clearing the manifest manager entry"

# ── manager-handoff.md: the sentinel-standing fence format ─────────────────
grep -q '```sentinel-standing' "$MH" \
  && ok "manager-handoff documents the sentinel-standing fence" \
  || bad "manager-handoff lacks the sentinel-standing fence"
grep -q 'SENTINEL-STANDING: <issue-number> <updatedAt-iso>' "$MH" \
  && ok "manager-handoff pins the SENTINEL-STANDING line format (number + updatedAt)" \
  || bad "manager-handoff lacks the SENTINEL-STANDING line format"

# Both sides of the fence contract must speak the same tokens: the handoff
# writes what idle-sentinel.sh parses.
grep -q '```sentinel-standing' "$IS" && grep -q 'SENTINEL-STANDING:' "$IS" \
  && ok "idle-sentinel.sh parses the same fence language and line prefix" \
  || bad "idle-sentinel.sh no longer references the sentinel-standing fence format"

# ── manager-resume.md: unattended resume semantics ─────────────────────────
grep -q -- '--non-interactive' "$MR" \
  && ok "manager-resume documents --non-interactive" \
  || bad "manager-resume lacks --non-interactive"
grep -q 'NEVER archive' "$MR" \
  && ok "manager-resume forbids archiving MANAGER-STATE.md when non-interactive" \
  || bad "manager-resume lacks the never-archive rule"

# The sentinel's wake prompt must invoke the resume flag the doc defines.
grep -q 'manager-resume --non-interactive' "$IS" \
  && ok "idle-sentinel wake prompt uses manager-resume --non-interactive" \
  || bad "idle-sentinel wake prompt does not use --non-interactive"

# ── install.sh: optional scheduler install delegates to --ensure ───────────
grep -q 'idle-sentinel\.sh' "$INSTALL" \
  && ok "install.sh references idle-sentinel.sh" \
  || bad "install.sh does not reference idle-sentinel.sh"
grep -q -- '"$SENTINEL" --ensure' "$INSTALL" \
  && ok "install.sh delegates scheduling to idle-sentinel.sh --ensure" \
  || bad "install.sh does not invoke the sentinel's --ensure mode"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
