#!/bin/bash
# tests/test_agent_start_parallel_issue_source.sh — Antigravity's swarm launcher
# (.agent/scripts/start-parallel-agents.sh) must honour the same issue-source
# contract as the plugin copy (#88).
#
# The two copies legitimately differ (Antigravity launch mechanics, ANTIGRAVITY_*
# env names), so the packager keeps the .agent copy hand-maintained (`local`,
# #153) and a byte comparison would fail forever. What must match is behaviour:
# the same --issue-source/--issue-dir CLI surface, the dispatcher resolving the
# backend once, and the result reaching EVERY pane it launches, on every
# multiplexer. Each is a separate way to be half-wired, so each is asserted.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
PLUGIN="$ROOT/plugins/autocoder/scripts/start-parallel-agents.sh"
AGENT="$ROOT/.agent/scripts/start-parallel-agents.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --help exits during argument parsing, before any multiplexer or worktree is
# touched, so running it is hermetic. Real output beats grepping the source: a
# flag can be documented in a comment and still not be parsed.
for side in "plugin:$PLUGIN" "agent:$AGENT"; do
  label="${side%%:*}"; f="${side#*:}"
  help_out=$(bash "$f" --help 2>&1) || true
  for flag in --issue-source --issue-dir; do
    echo "$help_out" | grep -qF -- "$flag" && ok "$label --help documents $flag" || bad "$label --help lacks $flag"
  done
done

# Parsed, resolved, exported.
for needle in 'source "$SCRIPT_DIR/issue-source-lib.sh"' '--issue-source)' '--issue-dir)' \
              'resolve_effective_issue_source "$CLI_ISSUE_SOURCE" "$CLI_ISSUE_DIR"' 'issue_env_exports'; do
  grep -qF -- "$needle" "$AGENT" && ok "agent copy has: $needle" || bad "agent copy is missing: $needle"
done
[ -f "$ROOT/.agent/scripts/issue-source-lib.sh" ] && ok ".agent/scripts ships issue-source-lib.sh" || bad ".agent/scripts/issue-source-lib.sh missing"

# Every multiplexer branch propagates the env. Split the script at its MUX
# branches and require at least one send_issue_env_* call in each.
branch_has_env() { # branch_has_env <mux>
  awk -v mux="$1" '
    /^(if|elif) \[ "\$MUX" = "/ { inb = ($0 ~ "\"" mux "\"") ; next }
    /^(else|fi)$/ { inb = 0 }
    inb && /send_issue_env_/ { found = 1 }
    END { exit found ? 0 : 1 }' "$AGENT"
}
for mux in tmux cmux herdr; do
  branch_has_env "$mux" && ok "agent copy: the $mux branch sends the issue env" || bad "agent copy: the $mux branch never sends the issue env"
done

# Workers AND managers on every multiplexer: assert each launch target by name,
# so dropping any single send (e.g. only the herdr worker one) fails here.
need() { # need <min-count> <exact call>
  local n; n=$(grep -cF -- "$2" "$AGENT")
  [ "$n" -ge "$1" ] && ok "agent copy: $2 (x$n)" || bad "agent copy: expected $2 at least $1x, found $n"
}
need 2 'send_issue_env_tmux "$PANE_ID"'          # first worker + each further worker
need 2 'send_issue_env_tmux "$MANAGER_PANE"'     # manager-only pane + manager
need 1 'send_issue_env_cmux "$WS_REF"'           # cmux workers
need 1 'send_issue_env_cmux "$REVIEW_WS_REF"'    # cmux manager
need 1 'send_issue_env_herdr "$PANE_ID"'         # herdr workers
need 1 'send_issue_env_herdr "$MANAGER_PANE_ID"' # herdr manager
awk '/Creating manager-only tmux session/{m=1} m&&/send_issue_env_tmux/{f=1} m&&/write_launch_manifest/{exit} END{exit f?0:1}' "$AGENT" \
  && ok "agent copy: the manager-only pane gets the env" || bad "agent copy: the manager-only pane does not get the env"

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
