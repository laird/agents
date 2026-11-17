#!/bin/bash
# tests/test_swarm_register.sh — swarm-register.sh adds or updates this
# worktree's worker entry (or the manager's) in the swarm manifest (#215).

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REG="$ROOT/plugins/autocoder/scripts/swarm-register.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset AUTOCODER_WORKER AUTOCODER_MANAGER TMUX_PANE HERDR_PANE_ID CMUX_WORKSPACE_ID

P="$TMP/proj"
git init -q "$P"; git -C "$P" config user.email t@example.com; git -C "$P" config user.name T
git -C "$P" commit -q --allow-empty -m init; git -C "$P" branch -M main
git -C "$P" worktree add -q -b main-wt-2 "$P-wt-2"
git -C "$P" worktree add -q -b main-wt-3 "$P-wt-3"
J() { python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print($2)" "$1"; }

# ── no manifest: silent no-op ───────────────────────────────────────────────
OUT=$(cd "$P-wt-2" && bash "$REG" 2>&1); RC=$?
eq "no manifest: exit 0" "0" "$RC"
[ ! -d "$P/.autocoder" ] && ok "no manifest: nothing created" || bad "no manifest: created $P/.autocoder"

# ── first run registers, second updates ─────────────────────────────────────
mkdir -p "$P/.autocoder/swarm"
M="$P/.autocoder/swarm/claude-proj.json"
cat > "$M" <<JSON
{"version": 1, "session": "claude-proj", "projectRoot": "$P", "state": "paused",
 "workers": [{"number": 1, "worktree": "$P", "launchMode": "tmux", "tmuxTarget": "%9", "state": "paused"}],
 "manager": null}
JSON
OUT=$(cd "$P-wt-2" && TMUX_PANE=%4 bash "$REG" --pid $$ 2>&1); RC=$?
eq "first run exits 0" "0" "$RC"
eq "a worker is added" "2" "$(J "$M" 'len(m["workers"])')"
eq "numbered from the -wt-N suffix" "2" "$(J "$M" 'm["workers"][1]["number"]')"
eq "worktree recorded" "$P-wt-2" "$(J "$M" 'm["workers"][1]["worktree"]')"
eq "branch recorded" "main-wt-2" "$(J "$M" 'm["workers"][1]["branch"]')"
eq "tmux pane recorded" "%4" "$(J "$M" 'm["workers"][1]["tmuxTarget"]')"
eq "pid recorded" "$$" "$(J "$M" 'm["workers"][1]["pid"]')"
[ -n "$(J "$M" 'm["workers"][1]["pid_start_time"] or ""')" ] && ok "pid start time recorded" || bad "no pid_start_time"
eq "state started" "started" "$(J "$M" 'm["workers"][1]["state"]')"
eq "worker 1 untouched" "%9 paused" "$(J "$M" 'm["workers"][0]["tmuxTarget"]+" "+m["workers"][0]["state"]')"
eq "registering a worker sets the swarm running (#218)" "running" "$(J "$M" 'm["state"]')"

git -C "$P-wt-2" checkout -q -b feature/issue-7
OUT=$(cd "$P-wt-2" && HERDR_PANE_ID=h-1 bash "$REG" --pid $$ 2>&1); RC=$?
eq "second run exits 0" "0" "$RC"
eq "second run does not duplicate" "2" "$(J "$M" 'len(m["workers"])')"
eq "branch updated" "feature/issue-7" "$(J "$M" 'm["workers"][1]["branch"]')"
eq "herdr pane added" "h-1" "$(J "$M" 'm["workers"][1]["herdrPane"]')"
eq "tmux pane kept when TMUX_PANE is unset" "%4" "$(J "$M" 'm["workers"][1]["tmuxTarget"]')"
echo "$OUT" | grep -q "worker 2 updated" && ok "says updated" || bad "output: $OUT"

# A taken -wt-N number falls through to the next free one; a marker number wins.
OUT=$(cd "$P-wt-3" && AUTOCODER_WORKER=claude-proj:5 bash "$REG" --pid $$ 2>&1)
eq "AUTOCODER_WORKER number used" "5" "$(J "$M" '[w["number"] for w in m["workers"] if w["worktree"].endswith("-wt-3")][0]')"

# Re-registering keeps a state it was not asked to change.
python3 - "$M" <<'PY2'
import json, sys
p = sys.argv[1]; m = json.load(open(p))
[w for w in m["workers"] if w["number"] == 2][0]["state"] = "paused"
json.dump(m, open(p, "w"))
PY2
python3 - "$M" <<'PY2'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["state"] = "paused"
json.dump(m, open(p, "w"))
PY2
(cd "$P-wt-2" && bash "$REG" --pid $$ >/dev/null 2>&1)
eq "state kept without --state" "paused" "$(J "$M" '[w["state"] for w in m["workers"] if w["number"] == 2][0]')"
eq "re-registering a worker sets a paused swarm running (#218)" "running" "$(J "$M" 'm["state"]')"
(cd "$P-wt-2" && bash "$REG" --pid $$ --state started >/dev/null 2>&1)
eq "--state sets it" "started" "$(J "$M" '[w["state"] for w in m["workers"] if w["number"] == 2][0]')"

# The main checkout is the manager's: not registered as a worker unless listed
# or named. (Worker 1 is listed at $P here, so use a manifest without it.)
python3 - "$M" "$P" <<'PY2'
import json, sys
p, root = sys.argv[1:]; m = json.load(open(p))
m["workers"] = [w for w in m["workers"] if w["worktree"] != root]
json.dump(m, open(p, "w"))
PY2
OUT=$(cd "$P" && bash "$REG" --pid $$ 2>&1); RC=$?
eq "main checkout, unlisted: exit 0" "0" "$RC"
eq "main checkout, unlisted: not registered" "2" "$(J "$M" 'len(m["workers"])')"
(cd "$P" && bash "$REG" --session claude-proj --pid $$ >/dev/null 2>&1)
eq "main checkout with --session: registered" "3" "$(J "$M" 'len(m["workers"])')"
python3 - "$M" "$P" <<'PY2'
import json, sys
p, root = sys.argv[1:]; m = json.load(open(p))
m["workers"] = [w for w in m["workers"] if w["worktree"] != root]
json.dump(m, open(p, "w"))
PY2
(cd "$P" && bash "$REG" --session ../../x --pid $$ >/dev/null 2>&1); eq "session with a path: exit 1" "1" "$?"

# ── --manager ───────────────────────────────────────────────────────────────
python3 - "$M" <<'PY2'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["state"] = "paused"
json.dump(m, open(p, "w"))
PY2
OUT=$(cd "$P" && HERDR_PANE_ID=h-mgr bash "$REG" --manager --pid $$ 2>&1); RC=$?
eq "--manager exits 0" "0" "$RC"
eq "registering the manager sets the swarm running (#218)" "running" "$(J "$M" 'm["state"]')"
eq "manager pid set" "$$" "$(J "$M" 'm["manager"]["pid"]')"
eq "manager pane set" "h-mgr" "$(J "$M" 'm["manager"]["herdrPane"]')"
eq "--manager adds no worker" "2" "$(J "$M" 'len(m["workers"])')"
OUT=$(cd "$P" && TMUX_PANE=%1 bash "$REG" --manager --pid $$ 2>&1)
eq "manager update keeps the herdr pane" "h-mgr %1" "$(J "$M" 'm["manager"]["herdrPane"]+" "+m["manager"]["tmuxTarget"]')"

# A live manager recorded under another pid is not displaced (#217); a dead
# one is, and so is a recycled pid, a pane shell whose agent has exited, and a
# recorded pid that is this process's ancestor. "Live" means an agent CLI runs
# at or under the recorded pid, so the stand-in agent is a copy of sleep named
# claude (one process, so killing it leaves nothing holding the output pipe).
mkdir -p "$TMP/bin"
cp "$(command -v sleep)" "$TMP/bin/claude"
stop_tree() { pkill -P "$1" 2>/dev/null; kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
MREG() { (cd "$P" && bash "$REG" --manager "$@" 2>&1); }

"$TMP/bin/claude" 300 >/dev/null 2>&1 & LIVE=$!
MREG --pid $LIVE >/dev/null
OUT=$(TMUX_PANE=%8 MREG --pid $$); RC=$?
eq "live manager kept: exit 0" "0" "$RC"
eq "live manager kept: pid" "$LIVE" "$(J "$M" 'm["manager"]["pid"]')"
eq "live manager kept: pane" "%1" "$(J "$M" 'm["manager"]["tmuxTarget"]')"
echo "$OUT" | grep -q "live manager pid $LIVE" && ok "says why it kept the manager" || bad "output: $OUT"
# Same pid, recorded start token wrong: the pid was recycled.
python3 - "$M" <<'PY2'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["manager"]["pid_start_time"] = "1"; json.dump(m, open(p, "w"))
PY2
TMUX_PANE=%8 MREG --pid $$ >/dev/null
eq "recycled pid replaced" "$$" "$(J "$M" 'm["manager"]["pid"]')"
stop_tree $LIVE

bash -c '"$0" 300; true' "$TMP/bin/claude" >/dev/null 2>&1 & SHELL_PID=$!
sleep 0.3
MREG --pid $SHELL_PID >/dev/null
TMUX_PANE=%8 MREG --pid $$ >/dev/null
eq "pane shell running an agent kept" "$SHELL_PID" "$(J "$M" 'm["manager"]["pid"]')"
pkill -P $SHELL_PID 2>/dev/null; sleep 0.3
bash -c 'sleep 300; true' >/dev/null 2>&1 & STALE=$!
MREG --pid $STALE >/dev/null
TMUX_PANE=%8 MREG --pid $$ >/dev/null
eq "pane shell with no agent under it replaced" "$$" "$(J "$M" 'm["manager"]["pid"]')"
stop_tree $SHELL_PID; stop_tree $STALE

"$TMP/bin/claude" 300 >/dev/null 2>&1 & LIVE=$!
MREG --pid $LIVE >/dev/null; stop_tree $LIVE
TMUX_PANE=%8 MREG --pid $$ >/dev/null
eq "dead manager replaced" "$$ %8" "$(J "$M" 'str(m["manager"]["pid"])+" "+m["manager"]["tmuxTarget"]')"
# The recorded pid ($$) is live (an agent runs under it) and is an ancestor of
# the registering helper: the same manager re-registering, so it is replaced.
"$TMP/bin/claude" 300 >/dev/null 2>&1 & UNDER=$!
"$TMP/bin/claude" 300 >/dev/null 2>&1 & OTHER=$!
MREG --pid $OTHER >/dev/null
eq "recorded live ancestor pid is replaced" "$OTHER" "$(J "$M" 'm["manager"]["pid"]')"
stop_tree $OTHER; stop_tree $UNDER
TMUX_PANE=%1 MREG --pid $$ >/dev/null

# ── session selection ───────────────────────────────────────────────────────
cp "$M" "$P/.autocoder/swarm/other.json"
python3 - "$P/.autocoder/swarm/other.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["session"] = "other"; m["workers"] = []
json.dump(m, open(p, "w"))
PY
OUT=$(cd "$P-wt-2" && bash "$REG" --pid $$ 2>&1); RC=$?
eq "two manifests: the one listing this worktree is used" "0 2 0" "$RC $(J "$M" 'len(m["workers"])') $(J "$P/.autocoder/swarm/other.json" 'len(m["workers"])')"
git -C "$P" worktree add -q -b main-wt-4 "$P-wt-4"
OUT=$(cd "$P-wt-4" && bash "$REG" --pid $$ 2>&1); RC=$?
eq "ambiguous: exit 0" "0" "$RC"
echo "$OUT" | grep -q "pass --session" && ok "ambiguous: asks for --session" || bad "ambiguous output: $OUT"
OUT=$(cd "$P-wt-4" && bash "$REG" --session other --pid $$ 2>&1)
eq "--session picks the manifest" "1" "$(J "$P/.autocoder/swarm/other.json" 'len(m["workers"])')"
OUT=$(cd "$P-wt-4" && bash "$REG" --session nosuch 2>&1); RC=$?
eq "unknown session: no-op exit 0" "0" "$RC"
bash "$REG" --bogus >/dev/null 2>&1; eq "unknown flag exits 1" "1" "$?"

[ -z "$(find "$P/.autocoder/swarm" -name '.manifest.*')" ] && ok "no temp files left" || bad "temp files left"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
