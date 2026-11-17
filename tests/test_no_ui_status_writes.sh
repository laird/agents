#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_no_ui_status_writes.sh — autocoder publishes UI-neutral status and writes
# no files laid out for one UI (#193).
#
# fix.md and monitor-workers.md used to have the model hand-build
# /tmp/agents-ui/<session>.json files. The fields and pane ids varied from run to
# run, and the prompts named one UI's directory. Status now comes from scripts:
# issue-events.jsonl, merge-events.jsonl and `autocoder-ctl.sh status --json`.
# This guards every shipped copy of the commands, skills and scripts against
# the writes coming back.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT" || exit 1
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Every tree that ships prompts, skills or scripts to an agent platform.
SHIPPED=(plugins skills .agent codex-plugins .factory .factory-plugin .pi)
existing=()
for d in "${SHIPPED[@]}"; do [ -d "$d" ] && existing+=("$d"); done
[ "${#existing[@]}" -ge 3 ] && ok "found shipped trees: ${existing[*]}" || bad "expected shipped trees, found: ${existing[*]}"

# Not a bare `agents-ui` grep: install-release-hook.sh must keep matching the legacy
# "# agents-ui release hook" marker to replace that hook in existing checkouts.
hits=$(grep -rnE '/tmp/agents-ui|for agents-tui\)|agents-ui TUI' "${existing[@]}" 2>/dev/null)
if [ -z "$hits" ]; then
  ok "no shipped file writes or names /tmp/agents-ui"
else
  bad "shipped files still write UI-specific status:"; echo "$hits" | head -20
fi

# The two commands that used to write it, in every platform copy.
for f in plugins/autocoder/commands/fix.md .agent/workflows/fix.md .pi/prompts/fix.md \
         plugins/autocoder/commands/monitor-workers.md .agent/workflows/monitor-workers.md \
         .pi/prompts/monitor-workers.md; do
  [ -f "$f" ] || { bad "$f missing"; continue; }
  if grep -q 'agents-ui' "$f"; then bad "$f mentions agents-ui"; else ok "$f does not mention agents-ui"; fi
done

for f in plugins/autocoder/commands/monitor-workers.md .agent/workflows/monitor-workers.md .pi/prompts/monitor-workers.md; do
  grep -q 'autocoder-ctl status --json' "$f" && grep -q 'issue-events.jsonl' "$f" \
    && ok "$f points UIs at ctl status and issue events" \
    || bad "$f does not point UIs at ctl status and issue events"
done

R=plugins/autocoder/scripts/README.md
if grep -q '^## Status for UIs' "$R"; then
  sec=$(sed -n '/^## Status for UIs/,/^## /p' "$R")
  for want in 'autocoder-ctl.sh status --json' 'issue-events.jsonl' 'merge-events.jsonl'; do
    echo "$sec" | grep -qF "$want" && ok "README Status for UIs names $want" || bad "README Status for UIs lacks $want"
  done
else
  bad "$R has no 'Status for UIs' section"
fi

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
