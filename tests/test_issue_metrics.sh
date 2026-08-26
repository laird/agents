#!/bin/bash
# tests/test_issue_metrics.sh — per-issue token/time/cost attribution.
#
# WHY THIS EXISTS:
#   The numbers this ships end up as a public comment on an issue, so a parsing
#   slip is not a cosmetic bug — it misattributes spend. The cases pinned here
#   are the ones that are wrong in a way that still LOOKS like a valid report:
#
#     * a gate transcript folded into an issue's total (gate work has no single
#       owner; counting it would inflate whichever issue happened to follow it)
#     * an in-flight session read as a finished one (no result event => zeroes,
#       which would publish "$0.00, 0 turns" for a fix that is still running)
#     * the two comment scopes sharing a marker (per-session and aggregate
#       comments must dedupe independently, or posting one suppresses the other)
#
#   No network: the poster is exercised through --dry-run only.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/plugins/autocoder/scripts/issue-metrics.py"
POST="$ROOT/plugins/autocoder/scripts/post-issue-metrics.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }

assert_contains() {
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output: $(printf '%s' "$3" | head -3)" ;; esac
}
assert_not_contains() {
  case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not installed"; echo "0 passed / 0 failed / 0 total"; exit 0
fi

LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT

# A transcript is JSONL; only the terminal `result` event carries the totals.
# $1 file  $2 cost  $3 duration_ms  $4 turns  $5 output_tokens
finished() {
  {
    printf '{"type":"system","subtype":"init","model":"claude-sonnet-5"}\n'
    printf '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":5,"cache_read_input_tokens":1000}}}\n'
    printf '{"type":"result","is_error":false,"duration_ms":%s,"duration_api_ms":%s,"num_turns":%s,"total_cost_usd":%s,' \
      "$3" "$3" "$4" "$2"
    printf '"usage":{"input_tokens":10,"output_tokens":%s,"cache_read_input_tokens":2000,"cache_creation_input_tokens":300},' "$5"
    printf '"modelUsage":{"claude-sonnet-5":{"provider":"vertex","contextWindow":1000000}}}\n'
  } > "$LOGS/$1"
}

# An in-flight session: real events, no result event. This is what every running
# worker's transcript looks like at the moment the manager reads it.
unfinished() {
  {
    printf '{"type":"system","subtype":"init","model":"claude-sonnet-5"}\n'
    printf '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":5,"cache_read_input_tokens":900}}}\n'
  } > "$LOGS/$1"
}

finished  worker-111-fix-900-090000.jsonl 1.50 60000  10 1000
finished  worker-111-fix-900-100000.jsonl 2.50 120000 20 3000
finished  worker-222-fix-901-110000.jsonl 4.00 30000   7  500
unfinished worker-333-fix-902-120000.jsonl
# Gate work: same worker, same directory, deliberately not attributable.
finished  worker-111-gate-085500.jsonl    9.99 600000 99 9999

run_py() { python3 "$PY" --log-dir "$LOGS" "$@" 2>&1; }

# ── Aggregation ───────────────────────────────────────────────────────────
out=$(run_py --json)
cost900=$(printf '%s' "$out" | python3 -c 'import json,sys; print(round(json.load(sys.stdin)["900"]["cost_usd"],2))' 2>/dev/null)
[ "$cost900" = "4.0" ] && ok "two sessions on one issue sum their cost (1.50+2.50)" \
                       || bad "two sessions on one issue sum their cost" "got '$cost900'"

turns900=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["900"]["num_turns"])' 2>/dev/null)
[ "$turns900" = "30" ] && ok "turns sum across sessions" || bad "turns sum across sessions" "got '$turns900'"

sess900=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["900"]["sessions"])' 2>/dev/null)
[ "$sess900" = "2" ] && ok "session count is per-transcript" || bad "session count is per-transcript" "got '$sess900'"

# ── The gate transcript must not be attributable to anything ──────────────
assert_not_contains "gate transcript contributes no issue row" '"9.99"' "$out"
has_gate=$(printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("yes" if any(round(v["cost_usd"],2)==9.99 for v in d.values()) else "no")' 2>/dev/null)
[ "$has_gate" = "no" ] && ok "gate cost never lands on an issue" || bad "gate cost never lands on an issue"

# ── In-flight sessions are held apart from the totals ─────────────────────
fly902=$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin)["902"]; print(d["in_flight"], d["sessions"], round(d["cost_usd"],2))' 2>/dev/null)
[ "$fly902" = "1 0 0.0" ] && ok "in-flight session counted separately, not as \$0 of work" \
                          || bad "in-flight session counted separately" "got '$fly902'"

rc=0; python3 "$PY" --session "$LOGS/worker-333-fix-902-120000.jsonl" --markdown >/dev/null 2>&1 || rc=$?
[ "$rc" = "3" ] && ok "--session on an unfinished transcript exits 3, not 0" \
                || bad "--session on an unfinished transcript exits 3" "got exit $rc"

# ── Comment rendering ─────────────────────────────────────────────────────
agg=$(run_py --markdown 900)
assert_contains "aggregate comment carries the aggregate marker" '<!-- autocoder-metrics aggregate -->' "$agg"
assert_contains "aggregate comment reports both sessions"       '| Agent sessions | 2 |' "$agg"
assert_contains "aggregate comment reports summed cost"         '| Cost | $4.00 |' "$agg"
assert_contains "aggregate comment discloses the gate exclusion" 'undercounts total swarm cost' "$agg"
assert_contains "aggregate comment discloses retry inclusion"    'retried and abandoned attempts' "$agg"

one=$(python3 "$PY" --session "$LOGS/worker-111-fix-900-100000.jsonl" --markdown 2>&1)
assert_contains "session comment carries a session-scoped marker" \
  '<!-- autocoder-metrics session=worker-111-fix-900-100000.jsonl -->' "$one"
assert_contains "session comment reports only that session"       '| Cost | $2.50 |' "$one"
assert_not_contains "session comment omits the sessions row"      '| Agent sessions |' "$one"

# The two scopes must not dedupe against each other: post-issue-metrics.sh skips
# on an exact marker match, so a shared marker would mean posting the aggregate
# suppressed every future per-session comment.
m1=$(printf '%s' "$agg" | head -1); m2=$(printf '%s' "$one" | head -1)
[ "$m1" != "$m2" ] && ok "session and aggregate markers differ" || bad "session and aggregate markers differ"

# ── Poster: renders without touching a backend ────────────────────────────
if [ -x "$POST" ]; then
  dry=$(AUTOCODER_LOG_DIR="$LOGS" "$POST" 900 --dry-run 2>&1)
  assert_contains "--dry-run prints the body and posts nothing" '<!-- autocoder-metrics aggregate -->' "$dry"

  off=$(AUTOCODER_METRICS=0 AUTOCODER_LOG_DIR="$LOGS" "$POST" 900 2>&1)
  assert_contains "AUTOCODER_METRICS=0 disables posting" 'disabled' "$off"

  none=$(AUTOCODER_LOG_DIR="$LOGS" "$POST" 99999 --dry-run 2>&1); rc=$?
  [ "$rc" = "0" ] && ok "an issue with no transcript exits 0 (fail-soft)" \
                  || bad "an issue with no transcript exits 0" "got exit $rc"
else
  bad "post-issue-metrics.sh is executable"
fi

# ── Worker-loop wiring ────────────────────────────────────────────────────
# A metrics call that runs before the fix, or without `|| true`, is the failure
# mode that matters: `set -e` is on in that loop, so a non-zero metrics exit
# would end the worker.
LOOP="$ROOT/plugins/autocoder/scripts/claude-worker-loop.sh"
loop_src=$(cat "$LOOP" 2>/dev/null)
assert_contains "worker loop posts metrics after a fix session" 'post-issue-metrics.sh' "$loop_src"
assert_contains "worker loop passes the session transcript"     '--session "$LAST_TRANSCRIPT"' "$loop_src"
assert_contains "metrics failure cannot end the worker loop"    'LAST_TRANSCRIPT" || true' "$loop_src"

fix_line=$(grep -n 'run_claude "fix-\$ISSUE_NUM"' "$LOOP" | head -1 | cut -d: -f1)
post_line=$(grep -n 'POST_METRICS" "\$ISSUE_NUM"' "$LOOP" | head -1 | cut -d: -f1)
if [ -n "$fix_line" ] && [ -n "$post_line" ] && [ "$post_line" -gt "$fix_line" ]; then
  ok "metrics post runs after the fix session, not before"
else
  bad "metrics post runs after the fix session" "fix@$fix_line post@$post_line"
fi

if bash -n "$LOOP" && bash -n "$POST"; then
  ok "worker loop and poster parse as bash"
else
  bad "worker loop and poster parse as bash"
fi

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
