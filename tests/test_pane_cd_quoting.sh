#!/bin/bash
# tests/test_pane_cd_quoting.sh — pins #232: the launchers type `cd <dir>` into
# a pane, and a directory whose name contains a single quote must still land
# the agent in that directory. The old `cd '<dir>'` form broke out of its own
# quoting there: the cd failed and the rest of the line ran as shell input.
#
# Drives start-parallel, add-worker and restart-worker against a project at a
# path with a quote in it, on a private tmux server, with a stub agent that
# records the directory it was actually started in.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Static check: no launcher types a bare single-quoted cd into a pane.
HITS=$(grep -nE "(send-keys|send_tmux_command).*\"cd '" \
  "$SCRIPTS/add-worker.sh" "$SCRIPTS/restart-worker.sh" "$SCRIPTS/start-parallel-agents.sh" \
  "$SCRIPTS/idle-sentinel.sh" "$ROOT/.agent/scripts/start-parallel-agents.sh" \
  "$ROOT/.agent/scripts/idle-sentinel.sh" 2>/dev/null)
[ -z "$HITS" ] && ok "no launcher types cd '<dir>' into a pane" \
  || bad "bare-quoted pane cd remains: $HITS"

if ! command -v tmux >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "SKIP: tmux/git not available for the launch checks"
  TOTAL=$((PASS + FAIL)); echo "$PASS passed / $FAIL failed / $TOTAL total"
  [ "$FAIL" -eq 0 ]; exit
fi

# Private tmux server, never the developer's: unset TMUX, kill only our socket.
TMPROOT=$(mktemp -d /tmp/pcdq.XXXXXX)
export TMUX_TMPDIR="$TMPROOT/s"
unset TMUX
PROJ="$TMPROOT/it's proj"
mkdir -p "$TMUX_TMPDIR" "$TMPROOT/bin" "$PROJ" "$TMPROOT/env"
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

# Stub interactive agent: record the directory it started in, then idle.
cat > "$TMPROOT/bin/gemini" <<STUB
#!/bin/bash
printf '%s\n' "\$PWD" > "$TMPROOT/env/\$\$"
exec sleep 600
STUB
chmod +x "$TMPROOT/bin/gemini"
tmux new-session -d -s keepalive

git -C "$PROJ" init -q -b main .
git -C "$PROJ" commit -q --allow-empty -m init

started_in() {  # started_in <dir> -> 0 once an agent has recorded <dir>
  local n=0 f
  while [ "$n" -le 40 ]; do
    for f in "$TMPROOT"/env/*; do
      [ -f "$f" ] && [ "$(cat "$f")" = "$1" ] && return 0
    done
    n=$((n + 1)); sleep 0.25
  done
  return 1
}

# ── start-parallel ─────────────────────────────────────────────────────────
OUT=$(cd "$PROJ" && PATH="$TMPROOT/bin:$PATH" AUTOCODER_MANAGER_PID_WAIT=1 \
  bash "$SCRIPTS/start-parallel-agents.sh" 2 --mux tmux --agent gemini --paused \
    --issue-source file --issue-dir "$TMPROOT/issues" 2>&1 </dev/null) || true
for n in 1 2; do
  started_in "$PROJ-wt-$n" && ok "start-parallel worker $n started in its quoted worktree" \
    || bad "start-parallel worker $n never started in '$PROJ-wt-$n': $(tail -5 <<<"$OUT")"
done

# ── add-worker ─────────────────────────────────────────────────────────────
AOUT=$(cd "$PROJ" && PATH="$TMPROOT/bin:$PATH" \
  bash "$SCRIPTS/add-worker.sh" 3 --mux tmux --agent gemini --no-attach 2>&1 </dev/null) || true
started_in "$PROJ-wt-3" && ok "add-worker worker 3 started in its quoted worktree" \
  || bad "add-worker worker 3 never started in '$PROJ-wt-3': $(tail -5 <<<"$AOUT")"

# ── restart-worker ─────────────────────────────────────────────────────────
rm -f "$TMPROOT"/env/*
ROUT=$(cd "$PROJ" && PATH="$TMPROOT/bin:$PATH" \
  bash "$SCRIPTS/restart-worker.sh" --worktree "$PROJ-wt-1" --mux tmux --agent gemini 2>&1 </dev/null) || true
started_in "$PROJ-wt-1" && ok "restart-worker relaunched worker 1 in its quoted worktree" \
  || bad "restart-worker never relaunched in '$PROJ-wt-1': $(tail -5 <<<"$ROUT")"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
