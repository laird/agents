#!/bin/bash
# tests/test_fix_md_handoff.sh — the /fix protocol hands the merge off instead of polling.
#
# fix.md is prose the LLM runtime follows, so this pins the text: at every merge-mode site
# the worker launches `merge-launch.sh ... --summary-file ... --own-issue`, swaps `working`
# for `awaiting-integration`, prints the hand-off line, and stops. No site polls
# merge-poll.sh or runs the ship gate inline; the detached job owns both. The Pi prompt is
# generated from the same source and must say the same thing.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

for f in plugins/autocoder/commands/fix.md .pi/prompts/fix.md; do
  path="$ROOT/$f"
  [ -f "$path" ] || { bad "$f exists"; continue; }

  launches=$(grep -c '"\${SCRIPT_DIR}/merge-launch\.sh"' "$path")
  [ "$launches" -ge 3 ] && ok "$f launches the merge at all 3 sites ($launches)" || bad "$f has $launches merge-launch.sh sites; want >= 3"

  # Every launch must carry --own-issue and --summary-file in the same command.
  unowned=$(awk '
    /"\$\{SCRIPT_DIR\}\/merge-launch\.sh"/ { in_cmd = 1; own = 0; summary = 0; start = NR }
    in_cmd && /--own-issue/   { own = 1 }
    in_cmd && /--summary-file/ { summary = 1 }
    in_cmd && !/\\$/ { if (!own || !summary) print start; in_cmd = 0 }
  ' "$path")
  [ -z "$unowned" ] && ok "$f: every launch passes --own-issue and --summary-file" || bad "$f: launches at line(s) $unowned lack --own-issue or --summary-file"

  polls=$(grep -c '"\${SCRIPT_DIR}/merge-poll\.sh"' "$path")
  [ "$polls" -eq 0 ] && ok "$f never polls merge-poll.sh" || bad "$f still polls merge-poll.sh at $polls site(s); the job owns the outcome now"

  inline_gate=$(grep -c '"\${SCRIPT_DIR}/verify-shipped\.sh"' "$path")
  [ "$inline_gate" -eq 0 ] && ok "$f runs no inline ship gate" || bad "$f still runs verify-shipped.sh inline at $inline_gate site(s)"

  handoffs=$(grep -c 'handed off to the merge job' "$path")
  [ "$handoffs" -ge 3 ] && ok "$f prints the hand-off line at all 3 sites ($handoffs)" || bad "$f prints the hand-off line $handoffs time(s); want >= 3"

  # The lock swap sits right after the launch: add awaiting-integration, then drop working.
  swaps=$(grep -A1 -- '--add-label "awaiting-integration"' "$path" | grep -c -- '--remove-label "working"')
  [ "$swaps" -ge 3 ] && ok "$f swaps working for awaiting-integration (add first) at all 3 sites ($swaps)" || bad "$f label swap found $swaps time(s); want >= 3"

  grep -q 'Merge launched (`merge` merge mode)' "$path" && ok "$f lock table lists the merge launch as a hand-off" || bad "$f lock table lacks the merge-launch hand-off row"
  grep -q 'merge-launch.sh --own-issue' "$path" && ok "$f blocking-labels table says the merge job applies and retires awaiting-integration" || bad "$f blocking-labels row not updated"

  prs=$(grep -c 'gh pr create' "$path")
  [ "$prs" -ge 2 ] && ok "$f keeps the pr merge-mode branch ($prs)" || bad "$f lost the pr merge-mode branch"
done

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
