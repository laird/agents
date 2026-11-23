#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_fix_md_verdict_rule.sh — a worker never waits on a background-job notification for a
# pre-check verdict (#7134): fix.md Step 3 carries the rule and the foreground poll of the verdict
# line, and monitor-workers.md runs the verdict watchdog each tick. Both platform copies.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

for f in plugins/autocoder/commands/fix.md .agent/workflows/fix.md; do
  P="$ROOT/$f"
  grep -q 'Never wait on a background-job notification for a verdict you need (#7134)' "$P" && ok "$f: the rule" || bad "$f: no rule"
  grep -qE "until grep -qE '\^=== \(prebank\|pre-check\)\[\^:\]\*: \(PASS\|FAIL\)' \"\\\$LOG\"" "$P" && ok "$f: the foreground poll of the verdict line" || bad "$f: no verdict-line poll"
  grep -q 'A run with no verdict and no live process is dead: re-run it, do not wait.' "$P" && ok "$f: a dead run is re-run" || bad "$f: dead-run sentence missing"
  # The rule is inside Step 3 (the plugin copy's numbered pre-merge list; the .agent copy's leaner Step 3), before the next heading.
  python3 - "$P" <<'PY' && ok "$f: the rule sits inside Step 3" || bad "$f: the rule is not inside Step 3"
import sys
s = open(sys.argv[1]).read()
step3 = s.index("### Step 3: Commit and Close")
rule = s.index("**Never wait on a background-job notification for a verdict you need (#7134).**")
nxt = s.index("\n### ", step3 + 1)
sys.exit(0 if step3 < rule < nxt else 1)
PY
done

for f in plugins/autocoder/commands/monitor-workers.md .agent/workflows/monitor-workers.md; do
  P="$ROOT/$f"
  grep -q '### Step 3b: Nudge workers that never saw a pre-check verdict (#7134)' "$P" && ok "$f: the watchdog step" || bad "$f: no watchdog step"
  grep -q 'worker-verdict-watchdog --once' "$P" && ok "$f: runs the watchdog each tick" || bad "$f: does not run the watchdog"
  grep -q 'workers.verdictLogs' "$P" && ok "$f: names the project configuration" || bad "$f: configuration not named"
done

echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
