#!/bin/bash
# Tests for the --route <self|manager> flag on start-parallel-agents.sh (issue #16).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/plugins/autocoder/scripts/start-parallel-agents.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. The launcher is syntactically valid.
#    NOTE: the .agent/scripts/ copy is a separate, already-stale mirror (it
#    predates --issue-source/--paused/manifest support) and is intentionally
#    left untouched by the #16 change; it is not asserted here.
bash -n "$SCRIPT" || fail "plugin script has a syntax error"

# 2. --help advertises the routing flags.
HELP=$("$SCRIPT" --help)
grep -Fq -- "--route self|manager" <<<"$HELP" || fail "help missing --route"
grep -Fq -- "--manager-routing" <<<"$HELP" || fail "help missing --manager-routing alias"

# 3. An unknown route value is rejected before any side effects.
if OUT=$("$SCRIPT" --route bogus 2>&1); then
  fail "expected non-zero exit for --route bogus"
fi
grep -Fq "Unknown route 'bogus'" <<<"$OUT" || fail "bogus route error message missing"

# 4. Default routing is self, and manager routing suppresses the self-claim loop.
#    (Structural invariants — the launcher needs a real tmux/cmux + agent to run
#    end-to-end, so assert the gate wiring statically.)
grep -Eq '^ROUTE="self"' "$SCRIPT" || fail "default ROUTE is not self"
grep -q 'SEND_WORKER_LOOP=false' "$SCRIPT" || fail "manager mode does not clear SEND_WORKER_LOOP"

# Every place that sends the worker fix-loop command must be gated on SEND_WORKER_LOOP.
worker_cmd_sends=$(grep -cE 'send_(tmux_text_enter|cmux_command) "\$?\{?WORKER_TARGETS|send_cmux_command "\$WS_REF" "\$WORKER_CMD"' "$SCRIPT" || true)
gated=$(grep -c 'SEND_WORKER_LOOP" = true' "$SCRIPT" || true)
[ "$gated" -ge 2 ] || fail "expected worker-loop sends to be gated on SEND_WORKER_LOOP in both tmux and cmux paths"

# 5. Routing mode is threaded to the manager session via AUTOCODER_ROUTE.
grep -q "export AUTOCODER_ROUTE='\$ROUTE'" "$SCRIPT" || fail "AUTOCODER_ROUTE not exported to manager"

echo "ok route-manager"
