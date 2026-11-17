#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_start_parallel_live_manifest.sh — pins #137: a swarm started WITHOUT
# --paused writes its swarm manifest too.
#
# The manifest used to be written only on the --paused path, so the swarm people
# actually run had no .autocoder/swarm/ at all. add-worker, remove-worker,
# restart-worker and start-workers all read the manifest, so none of them could act
# on a live swarm. The fallback was `tmux kill-pane`, which leaves the manager
# dispatching to a dead worker. 6f59053 (R2-F1) made every launch path write
# it; this keeps it that way, for the launch and for remove-worker, which is the
# issue's repro.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SP="$ROOT/plugins/autocoder/scripts/start-parallel-agents.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if ! command -v tmux >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "SKIP: tmux/git not available"
  echo "0 passed / 0 failed / 0 total"
  exit 0
fi

# Same sandbox as test_start_parallel_base_index.sh: a private tmux server, never
# the developer's (unset TMUX), and kill-server only on a socket we own.
TMPROOT=$(mktemp -d /tmp/splm.XXXXXX)
export TMUX_TMPDIR="$TMPROOT/s"
unset TMUX
mkdir -p "$TMUX_TMPDIR" "$TMPROOT/bin" "$TMPROOT/proj"
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

# Stub agent: any `claude` on PATH; it just idles in the pane.
printf '#!/bin/bash\nexec sleep 600\n' > "$TMPROOT/bin/claude"
chmod +x "$TMPROOT/bin/claude"
tmux new-session -d -s keepalive

git -C "$TMPROOT/proj" init -q -b main .
git -C "$TMPROOT/proj" commit -q --allow-empty -m init

# ── 1. A live (non-paused) launch writes the manifest ──────────────────────
# The stub agent never shows the manager marker; do not wait 15s for it.
OUT=$(cd "$TMPROOT/proj" && PATH="$TMPROOT/bin:$PATH" AUTOCODER_MANAGER_PID_WAIT=1 \
  bash "$SP" 3 --mux tmux --agent claude --no-worktrees \
    --issue-source file --issue-dir "$TMPROOT/issues" 2>&1 </dev/null) || true
SESSION="claude-proj"
tmux has-session -t "$SESSION" 2>/dev/null && ok "live swarm session created" \
  || bad "no swarm session: $(tail -5 <<<"$OUT")"

MANIFEST="$TMPROOT/proj/.autocoder/swarm/$SESSION.json"
if [ -f "$MANIFEST" ]; then
  ok "live launch wrote the swarm manifest"
else
  bad "live launch wrote no manifest: $(ls "$TMPROOT/proj/.autocoder" 2>&1)"
fi

if [ -f "$MANIFEST" ]; then
  read -r NW STATES <<<"$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
ws = d.get("workers") or []
print(len(ws), ",".join(sorted({str(w.get("state")) for w in ws})))' "$MANIFEST")"
  [ "$NW" = 3 ] && ok "manifest lists all 3 workers" || bad "manifest lists $NW workers"
  [ "$STATES" != "paused" ] && ok "workers are not recorded as paused (states: $STATES)" \
    || bad "a live launch recorded its workers as paused"
  LIVE=" $(tmux list-panes -s -t "$SESSION" -F '#{pane_id}' | tr '\n' ' ')"
  for t in $(python3 -c 'import json,sys; print("\n".join(w.get("tmuxTarget") or "" for w in json.load(open(sys.argv[1]))["workers"]))' "$MANIFEST"); do
    case "$LIVE " in *" $t "*) ok "manifest target $t is a live pane" ;; *) bad "manifest target $t is not live (live:$LIVE)" ;; esac
  done
fi

# ── 2. remove-worker can act on the live swarm (the issue's repro) ──────────
BEFORE=$(tmux list-panes -t "$SESSION:agents" -F '#{pane_id}' 2>/dev/null | wc -l)
ROUT=$(cd "$TMPROOT/proj" && PATH="$TMPROOT/bin:$PATH" \
  bash "$ROOT/plugins/autocoder/scripts/remove-worker.sh" 2 --mux tmux </dev/null 2>&1); RRC=$?
AFTER=$(tmux list-panes -t "$SESSION:agents" -F '#{pane_id}' 2>/dev/null | wc -l)
[ "$RRC" -eq 0 ] && ok "remove-worker 2 succeeds on a live swarm" \
  || bad "remove-worker 2 failed (rc=$RRC): $(tail -3 <<<"$ROUT")"
[ "$AFTER" -eq $((BEFORE - 1)) ] && ok "remove-worker closed one pane ($BEFORE → $AFTER)" \
  || bad "pane count $BEFORE → $AFTER"
if [ -f "$MANIFEST" ]; then
  # remove-worker deletes the entry (swarm-manifest-lib.sh); workers are keyed by
  # "number". Worker 2 must be gone and 1 and 3 must remain.
  NUMS=$(python3 -c '
import json, sys
print(",".join(str(w.get("number")) for w in json.load(open(sys.argv[1]))["workers"]))' "$MANIFEST")
  [ "$NUMS" = "1,3" ] && ok "worker 2 deregistered; 1 and 3 remain" \
    || bad "manifest workers after remove-worker 2: '$NUMS' (want 1,3)"
fi

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
