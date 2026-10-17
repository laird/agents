#!/bin/bash
# tests/test_fix_md_handoff.sh — the /fix protocol hands the merge off instead of polling,
# and the merge JOB owns the issue from the launch onward.
#
# fix.md is prose the LLM runtime follows, so this pins the text: at every merge-mode site
# the worker writes the summary file, launches `merge-launch.sh ... --summary-file ...
# --own-issue`, prints the hand-off line, and stops. It writes NO label after the launch:
# the job swaps `working` for `merging` itself as its first act, and a worker-side label
# write landing after the job's fast path used to overwrite the job's outcome (a closed
# issue carrying `awaiting-integration`, or a double-blocked one). No site polls
# merge-poll.sh or runs the ship gate inline. The Pi prompt is generated from the same
# source and must say the same thing.

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

  # Between each launch and its hand-off line the worker touches no label: no
  # issue_update, issue_release, or add-blocking-label call.
  late_writes=$(awk '
    /"\$\{SCRIPT_DIR\}\/merge-launch\.sh"/ { after = 1 }
    after && /handed off to the merge job/ { after = 0 }
    after && /issue_update|issue_release|add-blocking-label|--add-label|--remove-label/ { print NR }
  ' "$path")
  [ -z "$late_writes" ] && ok "$f: no worker-side label write after any launch" || bad "$f writes a label after the launch at line(s) $late_writes; the job owns the hand-off"

  merging_sites=$(grep -c "merging" "$path")
  [ "$merging_sites" -ge 4 ] && ok "$f names the job's \`merging\` hand-off ($merging_sites mentions)" || bad "$f barely mentions merging ($merging_sites)"

  grep -q 'Merge launched (`merge` merge mode)' "$path" && ok "$f lock table lists the merge launch as a hand-off" || bad "$f lock table lacks the merge-launch hand-off row"
  grep -q 'swaps `working` for `merging` itself as its first act' "$path" && ok "$f lock table says the job performs the swap" || bad "$f lock table does not assign the swap to the job"
  grep -q 'merge-launch.sh --own-issue' "$path" && ok "$f blocking-labels table names the merge job" || bad "$f blocking-labels row not updated"
  grep -q '^| `merging` |' "$path" && ok "$f blocking-labels table has a merging row" || bad "$f blocking-labels table lacks a merging row"
  grep -q '"merging:' "$path" && ok "$f creates the merging label on GitHub" || bad "$f label-creation list lacks merging"

  prs=$(grep -c 'gh pr create' "$path")
  [ "$prs" -ge 2 ] && ok "$f keeps the pr merge-mode branch ($prs)" || bad "$f lost the pr merge-mode branch"
done

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
