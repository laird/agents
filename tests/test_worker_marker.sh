#!/bin/bash
# tests/test_worker_marker.sh — pins #216: workers launched by start-parallel
# and by add-worker carry AUTOCODER_WORKER=<session>:<N> in their environment,
# like the manager's AUTOCODER_MANAGER=<session> marker, so swarm-register.sh
# and the sentinel can recognise a worker by evidence rather than by name.
#
# The stub agent records the environment it was actually started with, so this
# checks what the agent process inherits, not just what the launcher typed.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ── 1. The helper (no tmux needed) ─────────────────────────────────────────
# shellcheck source=../plugins/autocoder/scripts/worker-launch-lib.sh
source "$SCRIPTS/worker-launch-lib.sh"
LINE=$(worker_marker_export "claude-proj" 3)
[ "$LINE" = "export AUTOCODER_WORKER=claude-proj:3" ] && ok "helper emits the export line" \
  || bad "helper emitted '$LINE'"
GOT=$(bash -c "$(worker_marker_export 'odd name;x' 2); printf %s \"\$AUTOCODER_WORKER\"")
[ "$GOT" = "odd name;x:2" ] && ok "helper quotes the session for the shell" \
  || bad "quoted export evaluated to '$GOT'"
worker_marker_export "claude-proj" "" 2>/dev/null && bad "helper accepted an empty number" \
  || ok "helper rejects a missing worker number"
worker_marker_export "" 1 2>/dev/null && bad "helper accepted an empty session" \
  || ok "helper rejects a missing session"

if ! command -v tmux >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "SKIP: tmux/git not available for the launch checks"
  TOTAL=$((PASS + FAIL)); echo "$PASS passed / $FAIL failed / $TOTAL total"
  [ "$FAIL" -eq 0 ]; exit
fi

# Private tmux server, never the developer's (same sandbox as
# test_start_parallel_live_manifest.sh): unset TMUX, kill only our own socket.
TMPROOT=$(mktemp -d /tmp/wmark.XXXXXX)
export TMUX_TMPDIR="$TMPROOT/s"
unset TMUX
mkdir -p "$TMUX_TMPDIR" "$TMPROOT/bin" "$TMPROOT/proj" "$TMPROOT/env"
cleanup() {
  local sock
  sock=$(tmux display-message -p '#{socket_path}' 2>/dev/null || true)
  case "$sock" in
    "$TMPROOT"/*) tmux kill-server 2>/dev/null ;;
    "")           : ;;
    *)            echo "WARNING: refusing 'tmux kill-server' — socket '$sock' is outside the sandbox ($TMPROOT)" >&2 ;;
  esac
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

# Stub interactive agent: record cwd and marker, then idle in the pane.
cat > "$TMPROOT/bin/gemini" <<STUB
#!/bin/bash
printf '%s|%s\n' "\$PWD" "\${AUTOCODER_WORKER:-}" > "$TMPROOT/env/\$\$"
exec sleep 600
STUB
chmod +x "$TMPROOT/bin/gemini"
tmux new-session -d -s keepalive

git -C "$TMPROOT/proj" init -q -b main .
git -C "$TMPROOT/proj" commit -q --allow-empty -m init

SESSION="gemini-proj"
marker_for() {  # marker_for <cwd> -> marker recorded by the agent started there
  local f
  for f in "$TMPROOT"/env/*; do
    [ -f "$f" ] || continue
    IFS='|' read -r cwd marker < "$f"
    [ "$cwd" = "$1" ] && { printf '%s' "$marker"; return 0; }
  done
  return 1
}
wait_for_agent() {  # wait_for_agent <cwd>
  local n=0
  until marker_for "$1" >/dev/null; do
    n=$((n + 1)); [ "$n" -gt 40 ] && return 1; sleep 0.25
  done
}

# ── 2. start-parallel: each worker carries its own session and number ──────
OUT=$(cd "$TMPROOT/proj" && PATH="$TMPROOT/bin:$PATH" AUTOCODER_MANAGER_PID_WAIT=1 \
  bash "$SCRIPTS/start-parallel-agents.sh" 2 --mux tmux --agent gemini --paused \
    --issue-source file --issue-dir "$TMPROOT/issues" 2>&1 </dev/null) || true
tmux has-session -t "$SESSION" 2>/dev/null && ok "start-parallel created the swarm session" \
  || bad "no swarm session: $(tail -5 <<<"$OUT")"

for n in 1 2; do
  dir="$TMPROOT/proj-wt-$n"
  if wait_for_agent "$dir"; then
    got=$(marker_for "$dir")
    [ "$got" = "$SESSION:$n" ] && ok "start-parallel worker $n has AUTOCODER_WORKER=$got" \
      || bad "start-parallel worker $n has AUTOCODER_WORKER='$got' (want $SESSION:$n)"
  else
    bad "start-parallel worker $n agent never started in $dir"
  fi
done

# The manager is not a worker: it must not inherit a worker marker.
if wait_for_agent "$TMPROOT/proj"; then
  got=$(marker_for "$TMPROOT/proj")
  [ -z "$got" ] && ok "manager carries no worker marker" \
    || bad "manager carries AUTOCODER_WORKER='$got'"
else
  echo "NOTE: manager agent not started in this mode; manager check skipped"
fi

# ── 3. add-worker: the new worker gets the next number ─────────────────────
# The paused swarm has two idle workers; add-worker starts those before it adds
# panes, so asking for 3 starts workers 1 and 2 and adds worker 3.
AOUT=$(cd "$TMPROOT/proj" && PATH="$TMPROOT/bin:$PATH" \
  bash "$SCRIPTS/add-worker.sh" 3 --mux tmux --agent gemini --no-attach 2>&1 </dev/null) || true
dir="$TMPROOT/proj-wt-3"
if wait_for_agent "$dir"; then
  got=$(marker_for "$dir")
  [ "$got" = "$SESSION:3" ] && ok "add-worker worker 3 has AUTOCODER_WORKER=$got" \
    || bad "add-worker worker 3 has AUTOCODER_WORKER='$got' (want $SESSION:3)"
else
  bad "add-worker agent never started in $dir: $(tail -5 <<<"$AOUT")"
fi

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
