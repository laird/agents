#!/bin/bash
# tests/test_autocoder_ctl_swarm.sh — autocoder-ctl's swarm lifecycle verbs (#246):
# start, add-worker, remove-worker and stop-swarm, through the dispatcher.
#
# Hermetic: the wrapped scripts are stubs passed through AUTOCODER_CTL_*_CMD that log
# their arguments and edit the swarm manifest the way the real ones do; the agent CLI
# (claude) and tmux are stubs on PATH. Pane screens come from $STUB/screen-<pane>.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$ROOT/plugins/autocoder/scripts/autocoder-ctl.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)
STUB="$TMP/stub"; mkdir -p "$STUB/bin"
LOG="$STUB/calls.log"

# tmux: capture-pane prints $STUB/screen-<pane> (":" and "." become "_"); anything
# else that would type into a pane is logged, and the test checks none happens.
cat > "$STUB/bin/tmux" <<'SH'
#!/bin/bash
printf 'tmux %s\n' "$(IFS='|'; echo "$*")" >> "$AUTOCODER_TEST_STUB/calls.log"
case "$1" in
  capture-pane) f="$AUTOCODER_TEST_STUB/screen-$(printf '%s' "$4" | tr ':.' '__')"; [ -f "$f" ] && cat "$f" ;;
  # A session is up while $STUB/alive-<name> exists ("-t =name").
  has-session)  [ -f "$AUTOCODER_TEST_STUB/alive-${3#=}" ] || exit 1 ;;
  kill-session) rm -f "$AUTOCODER_TEST_STUB/alive-${3#=}" ;;
esac
exit 0
SH
# claude: "plugin list" shows the plugin when $STUB/plugin-present exists; "plugin
# install" fails when $STUB/plugin-install-fail exists.
cat > "$STUB/bin/claude" <<'SH'
#!/bin/bash
printf 'claude %s\n' "$(IFS='|'; echo "$*")" >> "$AUTOCODER_TEST_STUB/calls.log"
case "$1 $2" in
  "plugin list")    [ -f "$AUTOCODER_TEST_STUB/plugin-present" ] && printf 'Installed plugins:\n  ❯ autocoder@plugin-marketplace\n'; exit 0 ;;
  "plugin install") [ -f "$AUTOCODER_TEST_STUB/plugin-install-fail" ] && { echo "Plugin not found in any marketplace" >&2; exit 1; }
                    echo "✔ Successfully installed plugin: $3"; exit 0 ;;
esac
exit 0
SH
# start-parallel-agents.sh: writes <cwd>/.autocoder/swarm/<agent>-<dir>.json with N
# workers (default 3) on panes <session>:1.<n>, manager on <session>:2.1.
cat > "$STUB/start" <<'SH'
#!/bin/bash
printf 'start %s cwd=%s stdin_tty=%s\n' "$(IFS='|'; echo "$*")" "$(pwd -P)" "$([ -t 0 ] && echo y || echo n)" >> "$AUTOCODER_TEST_STUB/calls.log"
[ -f "$AUTOCODER_TEST_STUB/start-fail" ] && { echo "❌ Error: cmux is not running" >&2; exit 1; }
# Already running: writes nothing, though another swarm's manifest changes meanwhile.
[ -f "$AUTOCODER_TEST_STUB/start-exists" ] && { touch .autocoder/swarm/*.json 2>/dev/null; echo "⚠️  Session 'claude-repo' already exists"; exit 0; }
n=3 agent=claude mux=tmux
while [ $# -gt 0 ]; do
  case "$1" in --agent) agent=$2; shift 2 ;; --mux) mux=$2; shift 2 ;; [0-9]*) n=$1; shift ;; *) shift ;; esac
done
s="$agent-$(basename "$PWD")"; mkdir -p .autocoder/swarm
python3 - "$s" "$agent" "$mux" "$n" > ".autocoder/swarm/$s.json" <<'PY'
import json, sys
s, agent, mux, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
import time
print(json.dumps({"session": s, "agent": agent, "mux": mux, "state": "running", "taskListId": f"parallel-{time.time_ns()}",
  "workers": [{"number": i, "worktree": f"/wt-{i}", "tmuxTarget": f"{s}:1.{i}", "state": "started"} for i in range(1, n + 1)],
  "manager": {"tmuxTarget": f"{s}:2.1"}}))
PY
echo "✅ Parallel agent system started!"
SH
# add-worker.sh: wakes the first paused worker, else appends the next number.
cat > "$STUB/add" <<'SH'
#!/bin/bash
printf 'add %s cwd=%s\n' "$(IFS='|'; echo "$*")" "$(pwd -P)" >> "$AUTOCODER_TEST_STUB/calls.log"
[ -f "$AUTOCODER_TEST_STUB/add-fail" ] && { echo "❌ No tmux session 'claude-repo' found." >&2; exit 1; }
m=$(ls .autocoder/swarm/*.json | head -1)
python3 - "$m" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); s = d["session"]
paused = [w for w in d["workers"] if w["state"] == "paused"]
if paused:
    paused[0]["state"] = "started"; print(f"▶️  Starting idle worker {paused[0]['number']}")
else:
    n = max([w["number"] for w in d["workers"]] or [0]) + 1
    d["workers"].append({"number": n, "worktree": f"/wt-{n}", "tmuxTarget": f"{s}:1.{n}", "state": "started"})
    print(f"✅ Worker {n} added")
json.dump(d, open(p, "w"))
PY
SH
# remove-worker.sh: drops the named workers that exist; exit 1 if any was missing.
cat > "$STUB/remove" <<'SH'
#!/bin/bash
printf 'remove %s cwd=%s\n' "$(IFS='|'; echo "$*")" "$(pwd -P)" >> "$AUTOCODER_TEST_STUB/calls.log"
nums=(); s=""
while [ $# -gt 0 ]; do case "$1" in --session) s=$2; shift 2 ;; [0-9]*) nums+=("$1"); shift ;; *) shift ;; esac; done
python3 - ".autocoder/swarm/$s.json" "${nums[@]}" <<'PY'
import json, sys
p = sys.argv[1]; want = {int(x) for x in sys.argv[2:]}; d = json.load(open(p))
have = {w["number"] for w in d["workers"]}
d["workers"] = [w for w in d["workers"] if w["number"] not in want]
json.dump(d, open(p, "w"))
missing = sorted(want - have)
if missing:
    print("Worker(s) not found in manifest: " + ", ".join(map(str, missing)), file=sys.stderr); sys.exit(1)
print("✅ Removed worker(s): " + " ".join(map(str, sorted(want))))
PY
SH
cat > "$STUB/stop" <<'SH'
#!/bin/bash
printf 'stop %s cwd=%s\n' "$(IFS='|'; echo "$*")" "$(pwd -P)" >> "$AUTOCODER_TEST_STUB/calls.log"
[ -f "$AUTOCODER_TEST_STUB/stop-fail" ] && { echo "❌ No herdr server is running"; exit 1; }
[ -f "$AUTOCODER_TEST_STUB/stop-none" ] && { echo "No parallel agent sessions found for $(basename "$PWD")"; exit 0; }
rm -f "$AUTOCODER_TEST_STUB"/alive-claude-* "$AUTOCODER_TEST_STUB"/alive-gemini-*
echo "🛑 Killing tmux session: claude-$(basename "$PWD")"; echo "✅ Done"
SH
chmod +x "$STUB/bin/"* "$STUB/start" "$STUB/add" "$STUB/remove" "$STUB/stop"

export PATH="$STUB/bin:$PATH" AUTOCODER_TEST_STUB="$STUB"
export AUTOCODER_CTL_START_CMD="$STUB/start" AUTOCODER_CTL_ADD_WORKER_CMD="$STUB/add"
export AUTOCODER_CTL_REMOVE_WORKER_CMD="$STUB/remove" AUTOCODER_CTL_STOP_SWARM_CMD="$STUB/stop"
export AUTOCODER_CTL_PROMPT_WAIT=0
# Every verb records a lifecycle event (#247): keep them out of the real log.
export AUTOCODER_ISSUE_EVENTS="$TMP/events.jsonl"
unset AUTOCODER_CTL_PROJECT_ROOT

REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m base
SW="$REPO/.autocoder/swarm"

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
has()   { grep -qxF -- "$2" "$LOG" && ok "$1" || bad "$1: no '$2' in: $(cat "$LOG")"; }
hasnt() { grep -q -- "$2" "$LOG" && bad "$1: found '$2' in: $(cat "$LOG")" || ok "$1"; }
detail() { jq -e "$2" <<<"$OUT" >/dev/null && ok "$1" || bad "$1: $OUT"; }

# ── Bad arguments: one usage result each, exit 2, nothing run ─────────────────
run 2 false "start with no repo"                   -- start
run 2 false "start with two repos"                 -- start "$REPO" "$REPO"
run 2 false "start with a bad worker count"        -- start "$REPO" --workers 0
run 2 false "start with a non-numeric count"       -- start "$REPO" --workers three
run 2 false "start with an unknown agent"          -- start "$REPO" --agent cursor
run 2 false "start with an unknown multiplexer"    -- start "$REPO" --mux screen
run 2 false "start with a bad route"               -- start "$REPO" --route anywhere
run 2 false "start --workers with no value"        -- start "$REPO" --workers
run 2 false "start with an unknown option"         -- start "$REPO" --force
run 2 false "add-worker with a bad count"          -- add-worker -1
run 2 false "add-worker with two counts"           -- add-worker 1 2
run 2 false "add-worker --session with a path"     -- add-worker --session ../x
run 2 false "remove-worker with no number"         -- remove-worker
run 2 false "remove-worker with a non-number"      -- remove-worker two
run 2 false "remove-worker with an unknown option" -- remove-worker 1 --force
run 2 false "stop-swarm with an argument"          -- stop-swarm now
run 2 false "stop-swarm with an unknown mux"       -- stop-swarm --mux screen
detail "a usage result names the verb, target null" '.action == "stop-swarm" and .target == null'
[ ! -s "$LOG" ] && ok "bad arguments run nothing" || bad "bad arguments ran: $(cat "$LOG")"

# ── start ─────────────────────────────────────────────────────────────────────
run 1 false "start in a directory that does not exist" -- start "$TMP/nope"
mkdir -p "$TMP/plain"
run 1 false "start outside a git repository"          -- start "$TMP/plain" --agent claude
detail "it says it is not a repository"               '.detail | test("not a git repository")'

touch "$STUB/plugin-install-fail"
run 1 false "start when the plugin is missing and cannot be installed" -- start "$REPO" --agent claude
detail "the failed install is reported"     '.detail.plugin.status == "failed" and .detail.started == false and (.detail.plugin.output | test("not found"))'
hasnt  "start-parallel-agents is not run"   "^start "
rm -f "$STUB/plugin-install-fail"

run 0 true "start installs a missing plugin, then starts" -- start "$REPO" --agent claude --workers 2 --mux tmux --route manager
has    "the plugin is installed for the agent" "claude plugin|install|autocoder@plugin-marketplace"
has    "start-parallel-agents gets the options, --no-attach and no terminal" \
       "start 2|--agent|claude|--no-attach|--mux|tmux|--route|manager cwd=$REPO stdin_tty=n"
jq -e --arg repo "$REPO" '.target == $repo and .detail.started and .detail.session == "claude-repo"
  and .detail.workers == [1,2] and .detail.mux == "tmux" and .detail.agent == "claude"
  and .detail.plugin.status == "installed" and .detail.prompts == [] and .detail.prompts_pending == false
  and (.detail.manifest | endswith(".autocoder/swarm/claude-repo.json"))' <<<"$OUT" >/dev/null \
  && ok "start reports session, manifest, workers and plugin" || bad "start detail: $OUT"

touch "$STUB/plugin-present" "$STUB/start-exists"
echo '{"agent": "codex", "mux": "tmux", "workers": []}' > "$SW/codex-repo.json"
run 1 false "start when the swarm is already running"  -- start "$REPO" --agent claude
rm -f "$SW/codex-repo.json"
detail "it says a session is already running"         '.detail.started == false and (.detail.reason | test("already running"))'
hasnt  "a present plugin is not reinstalled"          "claude plugin|install"
has    "the plugin is looked up from the repo"        "claude plugin|list"
detail "another swarm's manifest changing is not taken for this start" '.detail.started == false'
rm -f "$STUB/start-exists"

touch "$STUB/start-fail"
run 1 false "start-parallel-agents failing"           -- start "$REPO" --agent claude
detail "its exit code and last line are reported"     '.detail.exit == 1 and (.detail.output | test("cmux is not running"))'
rm -f "$STUB/start-fail"

# Pending prompts: read from the panes, reported, never answered.
rm -f "$SW"/*.json
printf '╭───╮\n│ Do you trust the files in this folder?\n│ ❯ 1. Yes, proceed\n│   2. No, exit\n' > "$STUB/screen-claude-repo_1_1"
printf 'WARNING: Claude Code running in Bypass Permissions mode\n❯ 1. No, exit\n  2. Yes, I accept\n' > "$STUB/screen-claude-repo_2_1"
printf '> /autocoder:fix-loop\n' > "$STUB/screen-claude-repo_1_2"
run 0 true "start with agents waiting on prompts"     -- start "$REPO" --agent claude --workers 2 --no-plugin-install
jq -e '.detail.prompts_pending and (.detail.prompts | length) == 2
  and (.detail.prompts | any(.role == "worker" and .worker == 1 and .pane == "claude-repo:1.1" and .kind == "trust"
                             and (.text | test("Do you trust the files in this folder"))))
  and (.detail.prompts | any(.role == "manager" and .worker == null and .pane == "claude-repo:2.1" and .kind == "consent"))' <<<"$OUT" >/dev/null \
  && ok "trust and consent prompts come back in detail, by pane" || bad "prompts: $OUT"
detail "--no-plugin-install skips the plugin step"    '.detail.plugin.status == "skipped"'
hasnt  "--no-plugin-install runs no plugin command"   "^claude plugin"
hasnt  "no prompt is answered: nothing is typed"      "send-keys"
has    "every pane is read"                           "tmux capture-pane|-p|-t|claude-repo:2.1"

# A similarly named plugin is not the autocoder plugin.
rm -f "$STUB/plugin-present" "$SW"/*.json
cp "$STUB/bin/claude" "$STUB/claude.orig"
printf '#!/bin/bash\nprintf "claude %%s\\n" "$(IFS="|"; echo "$*")" >> "$AUTOCODER_TEST_STUB/calls.log"\n[ "$2" = list ] && echo "  ❯ foo-autocoder@plugin-marketplace"\nexit 0\n' > "$STUB/bin/claude"
run 0 true "start with only a look-alike plugin installed" -- start "$REPO" --agent claude --workers 1
has    "the real plugin is installed"                  "claude plugin|install|autocoder@plugin-marketplace"
touch "$STUB/plugin-present"
# A pane target that could be read as an option is never passed to the multiplexer.
python3 - "$SW/claude-repo.json" <<'PY2'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["workers"][0]["state"] = "paused"; d["workers"][0]["tmuxTarget"] = "-t evil"; json.dump(d, open(p, "w"))
PY2
run 0 true "add-worker with a manifest pane that looks like an option" -- add-worker --repo "$REPO"
hasnt  "the bad pane target is not read"               "capture-pane|-p|-t|-t evil"
rm -f "$SW"/*.json; cp "$STUB/claude.orig" "$STUB/bin/claude"
run 0 true "a fresh swarm for the rest"                -- start "$REPO" --agent claude --workers 2 --no-plugin-install

# ── add-worker ────────────────────────────────────────────────────────────────
run 0 true "add-worker uses the swarm's agent and mux" -- add-worker --repo "$REPO"
has    "add-worker.sh gets --no-attach and the manifest's agent and mux" "add --no-attach|--agent|claude|--mux|tmux cwd=$REPO"
detail "the new worker is reported"                  '.detail.added == [3] and .detail.started == [] and .detail.session == "claude-repo"'
printf 'Do you trust the contents of this directory?\n' > "$STUB/screen-claude-repo_1_4"
python3 - "$SW/claude-repo.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["workers"][1]["state"] = "paused"; json.dump(d, open(p, "w"))
PY
run 0 true "add-worker 2 from inside the repo"       -- add-worker 2 --repo "$REPO"
detail "a woken paused worker and a new one are told apart" '.detail.started == [2] and .detail.added == []'
( cd "$REPO" && "$CTL" add-worker >"$TMP/out" 2>/dev/null ); OUT=$(cat "$TMP/out")
detail "without --repo it acts on the current repo"  '.ok and .detail.added == [4]'
detail "the new worker's pending trust prompt is reported" '.detail.prompts_pending and .detail.prompts[0].worker == 4 and .detail.prompts[0].kind == "trust"'
git -C "$REPO" worktree add -q "$TMP/linked" -b linked
run 0 true "add-worker --repo a linked worktree"     -- add-worker --repo "$TMP/linked"
has    "it acts on the main worktree's swarm"        "add --no-attach|--agent|claude|--mux|tmux cwd=$REPO"
cp "$SW/claude-repo.json" "$SW/codex-repo.json"
run 1 false "add-worker with two swarms and no --session" -- add-worker --repo "$REPO"
detail "it asks for --session"                       '.detail | test("--session")'
run 0 true "--session picks the swarm"               -- add-worker --repo "$REPO" --session claude-repo
run 1 false "--session with no manifest"             -- add-worker --repo "$REPO" --session nosuch
rm -f "$SW/codex-repo.json"
touch "$STUB/add-fail"
run 1 false "add-worker.sh failing"                  -- add-worker --repo "$REPO"
detail "its output is reported"                      '.detail.exit == 1 and (.detail.output | test("No tmux session"))'
rm -f "$STUB/add-fail"
mkdir -p "$TMP/empty"; git init -q "$TMP/empty"
run 1 false "add-worker where no swarm runs"         -- add-worker --repo "$TMP/empty"
detail "it says to start one first"                  '.detail | test("start one first")'

# ── remove-worker ─────────────────────────────────────────────────────────────
run 0 true "remove-worker 1 3"                       -- remove-worker 1 3 --repo "$REPO" --remove-worktree
has    "remove-worker.sh gets the numbers, session and flag" "remove 1|3|--session|claude-repo|--remove-worktree cwd=$REPO"
detail "removed and remaining workers are reported" '.detail.removed == [1,3] and (.detail.remaining | index(1) | not) and .detail.worktrees_removed'
run 1 false "remove-worker of a worker that is not there" -- remove-worker 9 --repo "$REPO"
detail "the script's exit and message come back"    '.detail.exit == 1 and .detail.removed == [] and (.detail.output | test("not found"))'

# ── stop-swarm ────────────────────────────────────────────────────────────────
run 0 true "stop-swarm"                              -- stop-swarm --repo "$REPO"
has    "stop-parallel-agents runs in the repo with the manifest's mux" "stop --mux|tmux cwd=$REPO"
detail "it reports the swarm stopped"                '.detail.stopped == true and .detail.mux == "tmux"'
touch "$STUB/stop-none"
run 0 true "stop-swarm with nothing running"         -- stop-swarm --repo "$REPO" --mux herdr
detail "nothing running is ok, stopped false"        '.detail.stopped == false and .detail.mux == "herdr"'
rm -f "$STUB/stop-none"
echo '{"agent": "codex", "mux": "tmux", "workers": []}' > "$SW/codex-repo.json"
touch "$STUB/alive-codex-repo" "$STUB/alive-claude-repo"
run 0 true "stop-swarm with a codex swarm running"   -- stop-swarm --repo "$REPO"
detail "the session the script cannot stop is closed by name" '.detail.stopped and .detail.sessions_closed == ["codex-repo"] and .detail.sessions_still_running == []'
has    "it is killed by exact name"                  "tmux kill-session|-t|=codex-repo"
[ ! -e "$STUB/alive-claude-repo" ] && ok "the claude session is left to the script" || bad "claude session still alive"
touch "$STUB/alive-codex-repo"
run 0 true "stop-swarm --mux herdr"                  -- stop-swarm --repo "$REPO" --mux herdr
detail "it leaves tmux sessions alone"               '.detail.sessions_closed == []'
[ -e "$STUB/alive-codex-repo" ] && ok "the tmux codex session survives a herdr stop" || bad "tmux session killed by a herdr stop"
rm -f "$SW/codex-repo.json" "$STUB/alive-codex-repo"; touch "$STUB/stop-fail"
run 1 false "stop-parallel-agents failing"           -- stop-swarm --repo "$REPO"
rm -f "$STUB/stop-fail"
rm -f "$SW"/*.json
run 0 true "stop-swarm with no manifest lets the script pick the mux" -- stop-swarm --repo "$REPO"
has    "no --mux is passed"                          "stop  cwd=$REPO"

# The real start script must not attach without a terminal: ctl passes --no-attach.
grep -q -- '--no-attach)' "$ROOT/plugins/autocoder/scripts/start-parallel-agents.sh" \
  && ok "start-parallel-agents.sh accepts --no-attach" || bad "start-parallel-agents.sh has no --no-attach"

echo ""
echo "autocoder-ctl swarm: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
