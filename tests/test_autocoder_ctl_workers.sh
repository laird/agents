#!/bin/bash
# tests/test_autocoder_ctl_workers.sh — autocoder-ctl's worker verbs (#244):
# nudge, stop and restart, through the dispatcher.
#
# Hermetic: tmux, cmux and herdr are stubs on PATH that log every call and report
# whatever pane directory the test sets; restart-worker.sh is replaced through
# AUTOCODER_CTL_RESTART_CMD. The swarm manifests live in a temp project root.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$ROOT/plugins/autocoder/scripts/autocoder-ctl.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)
# Events (#247) go to a private log, never the user's real state dir (#254).
export AUTOCODER_ISSUE_EVENTS="$TMP/issue-events.jsonl"
STUB="$TMP/stub"; mkdir -p "$STUB/bin"
LOG="$STUB/calls.log"

# Each stub logs "<mux> <args joined by |>". tmux and herdr report the pane directory
# from $STUB/<mux>-cwd; a missing file means the pane is gone.
cat > "$STUB/bin/tmux" <<'SH'
#!/bin/bash
printf 'tmux %s\n' "$(IFS='|'; echo "$*")" >> "$AUTOCODER_TEST_STUB/calls.log"
case "$1" in
  display-message) [ -f "$AUTOCODER_TEST_STUB/tmux-cwd" ] || exit 1; cat "$AUTOCODER_TEST_STUB/tmux-cwd" ;;
  respawn-pane)    exit "$(cat "$AUTOCODER_TEST_STUB/tmux-respawn-rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
SH
cat > "$STUB/bin/herdr" <<'SH'
#!/bin/bash
printf 'herdr %s\n' "$(IFS='|'; echo "$*")" >> "$AUTOCODER_TEST_STUB/calls.log"
case "$1 $2" in
  "pane get")     [ -f "$AUTOCODER_TEST_STUB/herdr-cwd" ] || exit 1
                  jq -cn --arg c "$(cat "$AUTOCODER_TEST_STUB/herdr-cwd")" \
                    '{result: {pane: {pane_id: "w3:p1", cwd: $c, foreground_cwd: $c}}}' ;;
  "agent prompt") exit "$(cat "$AUTOCODER_TEST_STUB/herdr-prompt-rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
SH
cat > "$STUB/bin/cmux" <<'SH'
#!/bin/bash
printf 'cmux %s\n' "$(IFS='|'; echo "$*")" >> "$AUTOCODER_TEST_STUB/calls.log"
exit 0
SH
cat > "$STUB/restart" <<'SH'
#!/bin/bash
printf 'restart %s cwd=%s\n' "$(IFS='|'; echo "$*")" "$(pwd -P)" >> "$AUTOCODER_TEST_STUB/calls.log"
echo "♻️  Restarting worker"
[ -f "$AUTOCODER_TEST_STUB/restart-fail" ] && { echo "❌ No tmux session found." >&2; exit 1; }
echo "✅ Worker restarted"
SH
chmod +x "$STUB/bin/"* "$STUB/restart"

export PATH="$STUB/bin:$PATH" AUTOCODER_TEST_STUB="$STUB"
export AUTOCODER_CTL_PROJECT_ROOT="$TMP/root" AUTOCODER_CTL_RESTART_CMD="$STUB/restart"
export AUTOCODER_MUX_SUBMIT_DELAY=0

# Worktrees and manifests: one swarm per multiplexer.
for w in wt-1 wt-2 wt-3 wt-4 wt-5 wt-6; do mkdir -p "$TMP/$w"; done
mkdir -p "$TMP/root/.autocoder/swarm"
SW="$TMP/root/.autocoder/swarm"
cat > "$SW/claude-proj.json" <<JSON
{"agent": "claude", "mux": "tmux", "state": "running", "workers": [
  {"number": 1, "worktree": "$TMP/wt-1", "tmuxTarget": "claude-proj:1.1", "state": "started", "commandMode": "agent-input"},
  {"number": 2, "worktree": "$TMP/wt-2", "tmuxTarget": "claude-proj:1.2", "state": "paused", "commandMode": "agent-input"},
  {"number": 5, "worktree": "$TMP/wt-5", "tmuxTarget": null, "state": "started"}]}
JSON
cat > "$SW/codex-proj.json" <<JSON
{"agent": "codex", "mux": "cmux", "state": "running", "workers": [
  {"number": 1, "worktree": "$TMP/wt-3", "cmuxWorkspace": "workspace:7", "state": "started", "commandMode": "agent-input"}]}
JSON
cat > "$SW/gemini-proj.json" <<JSON
{"agent": "gemini", "mux": "herdr", "state": "running", "workers": [
  {"number": 1, "worktree": "$TMP/wt-4", "herdrPane": "w3:p1", "state": "started", "commandMode": "agent-input"},
  {"number": 2, "worktree": "$TMP/wt-6", "herdrPane": "w4:p1", "state": "started", "commandMode": "shell"}]}
JSON

# run <expected-rc> <expected-ok> <name> -- <args...>: exit code, exactly one JSON
# result line with the four keys, ok as expected. Leaves the result in $OUT.
run() {
  local want_rc="$1" want_ok="$2" name="$3"; shift 4
  : > "$LOG"
  OUT=$("$CTL" "$@" 2>"$TMP/stderr"); local rc=$?
  if [ "$rc" -ne "$want_rc" ]; then bad "$name: exit $rc, want $want_rc (out: $OUT)"; return 1; fi
  if [ "$(printf '%s\n' "$OUT" | wc -l)" -ne 1 ] \
     || ! printf '%s' "$OUT" | jq -e --argjson ok "$want_ok" \
          'type == "object" and (keys == ["action","detail","ok","target"]) and .ok == $ok' >/dev/null 2>&1; then
    bad "$name: not one result object with ok=$want_ok: $OUT"; return 1
  fi
  ok "$name"
}
has()  { grep -qxF -- "$2" "$LOG" && ok "$1" || bad "$1: no '$2' in: $(cat "$LOG")"; }
hasnt(){ grep -q -- "$2" "$LOG" && bad "$1: found '$2' in: $(cat "$LOG")" || ok "$1"; }
detail() { jq -e "$2" <<<"$OUT" >/dev/null && ok "$1" || bad "$1: $OUT"; }

DEFAULT_TEXT="Resume the autocoder fix loop: carry on with the issue you have claimed, or take the next claimable issue if you have none."

# ── Bad arguments: every one is one usage result, exit 2 ──────────────────────
run 2 false "nudge with no worktree"            -- nudge
run 2 false "nudge with two texts"              -- nudge "$TMP/wt-1" a b
run 2 false "nudge with an unknown option"      -- nudge "$TMP/wt-1" --force
run 2 false "nudge --session with no value"     -- nudge "$TMP/wt-1" --session
run 2 false "nudge --session with a path"       -- nudge "$TMP/wt-1" --session ../x
run 2 false "nudge with empty text"             -- nudge "$TMP/wt-1" ""
run 2 false "stop with no worktree"             -- stop
run 2 false "stop with a second argument"       -- stop "$TMP/wt-1" extra
run 2 false "restart with no worktree"          -- restart
run 2 false "restart with an unknown option"    -- restart "$TMP/wt-1" --now
detail "a usage result names the verb" '.action == "restart" and .target == null'

# ── Unknown workers ───────────────────────────────────────────────────────────
run 1 false "nudge a directory that does not exist"   -- nudge "$TMP/nope"
mkdir -p "$TMP/loose"
run 1 false "nudge a directory no swarm runs in"      -- nudge "$TMP/loose"
detail "it says no worker runs there" '.detail | test("no swarm worker")'
run 1 false "nudge with a session that has no manifest" -- nudge "$TMP/wt-1" --session nosuch
run 1 false "nudge a worker with no pane recorded"    -- nudge "$TMP/wt-5"

# ── nudge: the right submit for each multiplexer ──────────────────────────────
echo "$TMP/wt-1" > "$STUB/tmux-cwd"
run 0 true "tmux nudge with the default text"   -- nudge "$TMP/wt-1"
has  "tmux: the text is typed on its own"       "tmux send-keys|-l|-t|claude-proj:1.1|--|$DEFAULT_TEXT"
has  "tmux: Enter is a separate send-keys"      "tmux send-keys|-t|claude-proj:1.1|Enter"
jq -e --arg wt "$TMP/wt-1" '.target == $wt and .detail.sent and .detail.mux == "tmux" and .detail.worker == 1
  and .detail.session == "claude-proj" and .detail.pane == "claude-proj:1.1"' <<<"$OUT" >/dev/null \
  && ok "tmux nudge reports worktree, worker, session and pane" || bad "tmux nudge detail: $OUT"
run 0 true "tmux nudge with custom text"        -- nudge "$TMP/wt-1" "look at #12"
has  "the custom text is sent"                  "tmux send-keys|-l|-t|claude-proj:1.1|--|look at #12"
run 0 true "text after -- may start with a dash" -- nudge "$TMP/wt-1" -- "-v please"
has  "the dashed text is sent literally, after --" "tmux send-keys|-l|-t|claude-proj:1.1|--|-v please"
run 0 true "a key name as text"                  -- nudge "$TMP/wt-1" "C-c"
has  "a key name is typed, not pressed"          "tmux send-keys|-l|-t|claude-proj:1.1|--|C-c"
run 0 true "text that looks like a target option" -- nudge "$TMP/wt-1" -- "-t other:0.1"
has  "it cannot retarget the send"              "tmux send-keys|-l|-t|claude-proj:1.1|--|-t other:0.1"

echo "$TMP/loose" > "$STUB/tmux-cwd"
run 1 false "tmux nudge refuses a pane in another directory" -- nudge "$TMP/wt-1"
hasnt "nothing was typed into that pane"         "send-keys"
echo "$TMP/wt-1" > "$STUB/tmux-cwd"

run 1 false "nudge refuses a paused worker"     -- nudge "$TMP/wt-2"
hasnt "nothing was typed into the paused worker" "send-keys"

run 0 true "cmux nudge"                          -- nudge "$TMP/wt-3" "go"
has  "cmux: send to the workspace"               "cmux send|--workspace|workspace:7|go"
has  "cmux: then send-key enter"                 "cmux send-key|--workspace|workspace:7|enter"
run 1 false "cmux refuses text starting with a dash" -- nudge "$TMP/wt-3" -- "-x"
hasnt "nothing was sent to cmux"                 "cmux send"

echo "$TMP/wt-4" > "$STUB/herdr-cwd"
run 0 true "herdr nudge of an agent-input worker" -- nudge "$TMP/wt-4" "go"
has  "herdr: agent prompt submits in one write"  "herdr agent|prompt|w3:p1|go"
hasnt "herdr: no separate send-text needed"      "send-text"
echo 1 > "$STUB/herdr-prompt-rc"
run 0 true "herdr nudge falls back when agent prompt fails" -- nudge "$TMP/wt-4" "go"
has  "herdr fallback: send-text"                 "herdr pane|send-text|w3:p1|go"
has  "herdr fallback: then send-keys enter"      "herdr pane|send-keys|w3:p1|enter"
rm -f "$STUB/herdr-prompt-rc"
echo "$TMP/wt-6" > "$STUB/herdr-cwd"
run 0 true "herdr nudge of a shell-mode worker"  -- nudge "$TMP/wt-6" "go"
has  "herdr shell mode: send-text"               "herdr pane|send-text|w4:p1|go"
hasnt "herdr shell mode: no agent prompt"        "agent|prompt"
echo "$TMP/wt-4" > "$STUB/herdr-cwd"
run 0 true "herdr takes dashed text as the positional argument" -- nudge "$TMP/wt-4" -- "-x"
has  "herdr: the dashed text is the prompt"      "herdr agent|prompt|w3:p1|-x"
echo "$TMP/wt-6" > "$STUB/herdr-cwd"

# ── stop: only a pane whose directory is the worktree ─────────────────────────
echo "$TMP/loose" > "$STUB/tmux-cwd"
run 1 false "stop refuses a tmux pane in another directory" -- stop "$TMP/wt-1"
hasnt "the mismatched pane was not killed"       "respawn-pane"
detail "the refusal says where the pane is"      '.detail | test("loose")'
rm -f "$STUB/tmux-cwd"
run 1 false "stop refuses a tmux pane that is gone" -- stop "$TMP/wt-1"
hasnt "nothing was respawned"                    "respawn-pane"
echo "$TMP/wt-1" > "$STUB/tmux-cwd"
run 0 true "stop a tmux worker"                  -- stop "$TMP/wt-1"
has  "tmux stop kills the agent and leaves a shell in the worktree" "tmux respawn-pane|-k|-t|claude-proj:1.1|-c|$TMP/wt-1"
jq -e '.detail.stopped and .detail.pane_left == "shell" and .detail.worktree_kept and .detail.claim_kept' <<<"$OUT" >/dev/null \
  && ok "stop reports what it left behind" || bad "stop detail: $OUT"
grep -q "\"worktree\": \"$TMP/wt-1\"" "$SW/claude-proj.json" && ok "the manifest entry is kept for remove-worker" || bad "manifest changed"
echo 1 > "$STUB/tmux-respawn-rc"
run 1 false "a failed respawn is a failure"      -- stop "$TMP/wt-1"
rm -f "$STUB/tmux-respawn-rc"

echo "$TMP/wt-6" > "$STUB/herdr-cwd"
run 1 false "stop refuses a herdr pane in another directory" -- stop "$TMP/wt-4"
hasnt "the herdr pane was not closed"            "pane|close"
echo "$TMP/wt-4" > "$STUB/herdr-cwd"
run 0 true "stop a herdr worker"                 -- stop "$TMP/wt-4"
has  "herdr stop closes the verified pane"       "herdr pane|close|w3:p1"

run 1 false "stop refuses a cmux worker it cannot verify" -- stop "$TMP/wt-3"
hasnt "the cmux workspace was not closed"        "close"

# ── restart: restart-worker.sh with the manifest's mux and agent ──────────────
run 0 true "restart a worker"                    -- restart "$TMP/wt-3"
has  "restart passes the worktree, mux and agent, from the worktree" \
     "restart --worktree|$TMP/wt-3|--mux|cmux|--agent|codex cwd=$TMP/wt-3"
detail "restart reports the script's last line"  '.detail.restarted and .detail.output == "✅ Worker restarted" and .detail.agent == "codex"'
touch "$STUB/restart-fail"
run 1 false "a failed restart is a failure"      -- restart "$TMP/wt-1"
detail "the failure carries the exit and output" '.detail.restarted == false and .detail.exit == 1 and (.detail.output | test("No tmux session"))'
rm -f "$STUB/restart-fail"

# ── Lookup: symlinks, and a worktree in two swarms ────────────────────────────
ln -s "$TMP/wt-3" "$TMP/link-3"
run 0 true "a symlink to the worktree finds the worker" -- restart "$TMP/link-3"
[ "$(jq -r .target <<<"$OUT")" = "$TMP/wt-3" ] && ok "the target is the resolved worktree" || bad "target: $OUT"

cat > "$SW/droid-proj.json" <<JSON
{"agent": "droid", "mux": "tmux", "workers": [{"number": 1, "worktree": "$TMP/wt-3", "tmuxTarget": "droid-proj:1.1", "state": "started"}]}
JSON
run 1 false "a worktree in two swarms is ambiguous" -- restart "$TMP/wt-3"
detail "it asks for --session"                    '.detail | test("--session")'
run 0 true "--session picks the swarm"            -- restart "$TMP/wt-3" --session droid-proj
has  "the chosen swarm's mux and agent are used" "restart --worktree|$TMP/wt-3|--mux|tmux|--agent|droid cwd=$TMP/wt-3"
echo '{not json' > "$SW/broken.json"
run 0 true "an unreadable manifest is skipped"    -- restart "$TMP/wt-1"
rm -f "$SW/broken.json" "$SW/droid-proj.json"

# #254: the verbs above logged their ctl events to the private log set at the top.
if jq -e -s 'any(.[]; .event == "ctl")' "$TMP/issue-events.jsonl" >/dev/null 2>&1; then
  ok "ctl events went to the private log, not the real state dir"
else
  bad "no ctl event in \$TMP/issue-events.jsonl: AUTOCODER_ISSUE_EVENTS is not reaching autocoder-ctl"
fi

echo ""
echo "autocoder-ctl workers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
