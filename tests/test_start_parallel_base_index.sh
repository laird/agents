#!/bin/bash
# tests/test_start_parallel_base_index.sh — pin that the tmux launcher never
# addresses windows by a hardcoded index.
#
# tmux honours the user's `base-index` option, so on a config with
# `set -g base-index 1` (very common) the first window of a new session is
# window 1, not 0. Every hardcoded ":0" target then fails with
#   can't find window: 0
# and because start-parallel-agents.sh runs under `set -e`, the launcher died
# at the first `split-window -t "$SESSION:0"` — after worker 1 had been set up.
# The wreckage looked like a half-built swarm: a session with one pane, no
# agents launched, no review window and no manifest, and a re-run just attached
# to the broken session instead of rebuilding it. Observed 2026-08-31.
#
# The fix is to capture window/pane ids (@N / %N) at creation and target those;
# ids are stable under any base-index and pane-base-index.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ── 1. Structural: no hardcoded window indexes anywhere in the launchers ─────
for f in plugins/autocoder/scripts/start-parallel-agents.sh \
         plugins/autocoder/scripts/add-worker.sh \
         .agent/scripts/start-parallel-agents.sh; do
  p="$ROOT/$f"
  [ -f "$p" ] || { bad "$f exists"; continue; }
  hits=$(grep -n 'SESSION_NAME:[0-9]' "$p" || true)
  [ -z "$hits" ] && ok "$f addresses no window by hardcoded index" \
                 || bad "$f still has hardcoded window targets: $hits"
done

# The launcher must capture the ids it later targets.
SP="$ROOT/plugins/autocoder/scripts/start-parallel-agents.sh"
grep -q "AGENTS_WINDOW=\$(tmux new-session .* -P -F '#{window_id}')" "$SP" \
  && ok "launcher captures the agents window id at creation" \
  || bad "launcher does not capture the agents window id"
grep -q "REVIEW_WINDOW=\$(tmux new-window .* -P -F '#{window_id}')" "$SP" \
  && ok "launcher captures the review window id at creation" \
  || bad "launcher does not capture the review window id"

# ── 2. Live: build a real swarm on a tmux server with base-index 1 ───────────
if ! command -v tmux >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "SKIP: tmux/git not available for the live check"
else
  # A tmux socket path is capped near 100 chars, so keep TMUX_TMPDIR short.
  TMPROOT=$(mktemp -d /tmp/spbi.XXXXXX)
  export TMUX_TMPDIR="$TMPROOT/s"
  # Inside a tmux pane $TMUX names the caller's socket, and tmux prefers it over
  # TMUX_TMPDIR. Left set, every tmux call below runs against the developer's real
  # server: the sandbox never applies (so base-index is not even under test) and
  # cleanup's kill-server destroys their sessions. Agents run inside tmux, so this
  # is the common case, not the edge case.
  unset TMUX
  mkdir -p "$TMUX_TMPDIR" "$TMPROOT/bin" "$TMPROOT/proj"
  # kill-server is unrecoverable, so never take the sandbox on faith: ask the server
  # we would actually reach where its socket lives, and refuse if it is not ours.
  cleanup() {
    local sock
    sock=$(tmux display-message -p '#{socket_path}' 2>/dev/null || true)
    case "$sock" in
      "$TMPROOT"/*) tmux kill-server 2>/dev/null ;;
      "")           : ;;  # no server reachable — nothing to tear down
      *)            echo "WARNING: refusing 'tmux kill-server' — socket '$sock' is outside the sandbox ($TMPROOT)" >&2 ;;
    esac
    rm -rf "$TMPROOT"
  }
  trap cleanup EXIT

  # Stub agent: the launcher only needs *a* `claude` on PATH to detect and run.
  printf '#!/bin/bash\nexec bash\n' > "$TMPROOT/bin/claude"
  chmod +x "$TMPROOT/bin/claude"

  printf 'set -g base-index 1\nset -g pane-base-index 1\n' > "$TMPROOT/tmux.conf"
  tmux -f "$TMPROOT/tmux.conf" new-session -d -s keepalive

  git -C "$TMPROOT/proj" init -q -b main .
  git -C "$TMPROOT/proj" commit -q --allow-empty -m init

  OUT=$(cd "$TMPROOT/proj" && PATH="$TMPROOT/bin:$PATH" \
    bash "$SP" 2 --mux tmux --agent claude --no-worktrees --paused \
      --issue-source file --issue-dir "$TMPROOT/issues" 2>&1) || true
  SESSION="claude-proj"

  tmux has-session -t "$SESSION" 2>/dev/null \
    && ok "swarm session created under base-index 1" \
    || bad "no swarm session under base-index 1: $(tail -3 <<<"$OUT")"

  WINDOWS=$(tmux list-windows -t "$SESSION" -F '#{window_name}:#{window_panes}' 2>/dev/null | tr '\n' ' ')
  [ "$WINDOWS" = "agents:2 review:1 " ] \
    && ok "agents window has both worker panes and the review window exists" \
    || bad "unexpected windows/panes: '$WINDOWS'"

  # The manifest's pane ids must be live panes, not stale/guessed targets.
  MANIFEST="$TMPROOT/proj/.autocoder/swarm/$SESSION.json"
  if [ -f "$MANIFEST" ]; then
    ok "manifest written"
    LIVE=$(tmux list-panes -s -t "$SESSION" -F '#{pane_id}' | sort | tr '\n' ' ')
    for target in $(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
print("\n".join(w["tmuxTarget"] or "" for w in d["workers"]))' "$MANIFEST"); do
      grep -q " ${target} \|^${target} \| ${target}$" <<<" $LIVE " \
        && ok "manifest target $target is a live pane" \
        || bad "manifest target $target is not a live pane (live: $LIVE)"
    done
  else
    bad "manifest not written (launcher exited early?)"
  fi

  # The summary must name the real window indexes, not 0 and 1.
  grep -q "Window 1: 2 worker agents" <<<"$OUT" \
    && ok "summary reports the real agents window index" \
    || bad "summary does not report the real agents window index"
  grep -q "Switch windows: Ctrl+b then 1 or 2" <<<"$OUT" \
    && ok "summary reports the real switch-window keys" \
    || bad "summary does not report the real switch-window keys"

  # add-worker must be able to split the agents window too. It restarts idle
  # workers in preference to adding panes, so mark the existing ones running.
  if [ -f "$MANIFEST" ]; then
    python3 - "$MANIFEST" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for w in d["workers"]:
    w["state"] = "running"
json.dump(d, open(p, "w"))
PY
  fi
  (cd "$TMPROOT/proj" && PATH="$TMPROOT/bin:$PATH" \
    bash "$ROOT/plugins/autocoder/scripts/add-worker.sh" \
      --mux tmux --agent claude --no-worktrees --no-attach >/dev/null 2>&1) || true
  PANES=$(tmux list-panes -t "$SESSION:agents" -F '#{pane_id}' 2>/dev/null | wc -l)
  [ "$PANES" -eq 3 ] \
    && ok "add-worker split the agents window under base-index 1" \
    || bad "add-worker did not add a pane (agents window has $PANES panes)"
fi

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
