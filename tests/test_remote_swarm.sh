#!/bin/bash
# tests/test_remote_swarm.sh — pins join-parallel --remote and remote-swarm-setup.
#
# A remote join must hand the terminal to herdr's own remote attach (or to
# `ssh -t … tmux attach`) and never fall through to the LOCAL multiplexer
# auto-detect: on a client like a uConsole, a local herdr server may well be
# running, and joining that instead of the host's swarm is the silent failure
# this guards. The three copies of join-parallel-agents.sh must stay identical.

set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
JOIN="$ROOT/plugins/autocoder/scripts/join-parallel-agents.sh"
SETUP="$ROOT/plugins/autocoder/scripts/remote-swarm-setup.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — expected '$2', got '$3'"; fi; }

STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
LOG="$STUB/calls.log"

# ssh stub: answers the remote mux probe with $REMOTE_MUX, logs attach calls.
cat > "$STUB/ssh" <<'EOF'
#!/bin/bash
for a in "$@"; do case $a in *"herdr status server"*) echo "${REMOTE_MUX:-}"; exit 0 ;; esac; done
echo "ssh $*" >> "$CALLS"
EOF
# herdr stub: a LOCAL server is "running" so a fall-through would be visible.
cat > "$STUB/herdr" <<'EOF'
#!/bin/bash
case "$1 $2" in "status server") echo "status: running"; exit 0 ;; esac
echo "herdr $*" >> "$CALLS"
EOF
cat > "$STUB/tmux" <<'EOF'
#!/bin/bash
echo "tmux $*" >> "$CALLS"
EOF
chmod +x "$STUB/ssh" "$STUB/herdr" "$STUB/tmux"

run_join() { : > "$LOG"; CALLS="$LOG" PATH="$STUB:$PATH" bash "$JOIN" "$@" >/dev/null 2>&1; cat "$LOG"; }

# 1. herdr on the host -> native herdr remote attach, not the local server
out=$(REMOTE_MUX=herdr run_join --remote swarm)
assert_eq "herdr host: herdr --remote attach" "herdr --remote swarm" "$out"

# 2. session name is passed through
out=$(REMOTE_MUX=herdr run_join --remote swarm claude-proj)
assert_eq "herdr host: --session passed" "herdr --remote swarm --session claude-proj" "$out"

# 3. tmux on the host -> ssh -t tmux attach
out=$(REMOTE_MUX=tmux run_join --remote swarm claude-proj)
assert_eq "tmux host: ssh -t tmux attach -t" "ssh -t swarm tmux attach -t claude-proj" "$out"

# 4. forced --mux skips the probe
out=$(REMOTE_MUX="" run_join --remote swarm --mux tmux)
assert_eq "--mux tmux forces tmux" "ssh -t swarm tmux attach" "$out"

# 5. SWARM_REMOTE is the default; --local overrides it
out=$(SWARM_REMOTE=swarm REMOTE_MUX=herdr run_join)
assert_eq "SWARM_REMOTE default" "herdr --remote swarm" "$out"
: > "$LOG"
CALLS="$LOG" SWARM_REMOTE=swarm REMOTE_MUX=herdr PATH="$STUB:$PATH" bash "$JOIN" --local >/dev/null 2>&1
if grep -q -- "--remote" "$LOG"; then fail "--local overrides SWARM_REMOTE"; else pass "--local overrides SWARM_REMOTE"; fi

# 6. unreachable host / no mux -> non-zero exit, nothing attached
: > "$LOG"
if CALLS="$LOG" REMOTE_MUX="" PATH="$STUB:$PATH" bash "$JOIN" --remote swarm >/dev/null 2>&1; then
  fail "no remote mux exits non-zero"
else
  pass "no remote mux exits non-zero"
fi
assert_eq "no remote mux attaches nothing" "" "$(cat "$LOG")"

# 7. cmux is rejected for remote
if CALLS="$LOG" PATH="$STUB:$PATH" bash "$JOIN" --remote swarm --mux cmux >/dev/null 2>&1; then
  fail "--remote --mux cmux rejected"
else
  pass "--remote --mux cmux rejected"
fi

# 8. mirrors stay identical
for m in .agent/scripts .pi/scripts; do
  if cmp -s "$JOIN" "$ROOT/$m/join-parallel-agents.sh"; then pass "$m copy identical"
  else fail "$m copy differs from plugins/autocoder/scripts"; fi
done

# 9. setup script: syntax, help, argument validation (no system changes)
bash -n "$SETUP" && pass "setup script parses" || fail "setup script parses"
bash "$SETUP" --help | grep -q "remote-swarm-setup.sh client" && pass "setup --help" || fail "setup --help"
if bash "$SETUP" bogus >/dev/null 2>&1; then fail "setup rejects unknown mode"; else pass "setup rejects unknown mode"; fi
if PATH="$STUB:$PATH" bash "$SETUP" client --name 'bad name' host >/dev/null 2>&1; then
  fail "setup rejects bad alias"
else
  pass "setup rejects bad alias"
fi

echo ""
echo "remote swarm: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
