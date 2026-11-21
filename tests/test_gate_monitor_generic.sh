#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"
# tests/test_gate_monitor_generic.sh — monitor-workers' gate efficiency step names the project's monitor
# through .autocoder.json (gateMonitor), never a particular project's script, and the generic fallback
# read carries no project's test-suite names.
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; C="$ROOT/plugins/autocoder/commands"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
grep -q "gateMonitor" "$C/monitor-workers.md" && ok "Step 2b reads gateMonitor from .autocoder.json" || bad "no gateMonitor in monitor-workers.md"
grep -q "gateMonitor" "$C/monitor-loop.md" && ok "monitor-loop names gateMonitor" || bad "no gateMonitor in monitor-loop.md"
if grep -nE "athena2(:|'s)|thesis-validator|dashboard-ui|mgr-gate-health|mgr-train|mgr-queue|MGR_GATE_" "$C/monitor-workers.md" "$C/monitor-loop.md" "$C/fix.md"; then
  bad "a command names a project's script, workspace or setting (lines above)"
else ok "no project names in the gate efficiency text"; fi
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
