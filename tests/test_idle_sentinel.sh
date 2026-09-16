#!/bin/bash
# tests/test_idle_sentinel.sh — formal suite for the idle-sentinel feature.
#
# Subject: plugins/autocoder/scripts/idle-sentinel.sh (spec:
# docs/specs/2026-09-16-idle-sentinel-design.md, Implementation plan item 7)
# plus the U2 lib/launcher changes it depends on (swarm-manifest-lib.sh
# identity fields, start-parallel-agents.sh --manager-only).
#
# Isolation rules (hard):
#   - everything runs in scratch dirs under mktemp -d;
#   - tmux uses a PRIVATE server via TMUX_TMPDIR (same pattern as
#     test_start_parallel_base_index.sh) — `tmux kill-server` in the trap
#     touches only that server, never the operator's;
#   - claude/gh are PATH shims; no real agent process is ever spawned;
#   - the sentinel is always run under `env -i` so no ambient AUTOCODER_* /
#     ISSUE_SOURCE / AUTOCODER_MANAGER value can leak in;
#   - --ensure is deliberately NEVER invoked (it would touch the real
#     crontab); scheduler installation is out of scope here.
#
# Linux-only paths (/proc scans) are the ones under test; the darwin ps -E
# fallbacks are exercised only by code review, as CI runs ubuntu.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
SENTINEL="$SCRIPTS/idle-sentinel.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# shellcheck source=../plugins/autocoder/scripts/swarm-manifest-lib.sh
source "$SCRIPTS/swarm-manifest-lib.sh"

if [ ! -d /proc/self ]; then
  echo "SKIP: this suite tests the Linux /proc identity paths"
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

# tmux socket paths are capped near 100 chars: keep the root short.
TMP=$(mktemp -d /tmp/idsent.XXXXXX)
export TMUX_TMPDIR="$TMP/s"
FAKEHOME="$TMP/home"
SHIM="$TMP/shim"
mkdir -p "$TMUX_TMPDIR" "$FAKEHOME" "$SHIM"

CLEANUP_PIDS=()
cleanup() {
  tmux kill-server 2>/dev/null
  local p
  for p in "${CLEANUP_PIDS[@]}"; do
    kill "$p" 2>/dev/null
    pkill -P "$p" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

# ── PATH shims ──────────────────────────────────────────────────────────────
# claude: enough of an agent for `command -v claude`, and for the real-wake
# test a long-lived process the marker scan can find. Prints nothing that
# matches the consent-dialog pattern.
cat > "$SHIM/claude" <<'EOF'
#!/bin/bash
echo "stub claude accepted ${#} args"
sleep 120
EOF
# crontab: nothing in these tests may reach the real crontab; a shim that
# fails loudly turns an accidental --ensure-like call into a test failure.
cat > "$SHIM/crontab" <<'EOF'
#!/bin/bash
echo "TEST VIOLATION: crontab invoked" >&2
exit 97
EOF
chmod +x "$SHIM/claude" "$SHIM/crontab"
BASEPATH="$SHIM:$PATH"

# gh shim, mode A: hard backend failure (issues-gh.sh maps any gh failure to
# its exit-3 backend-error contract).
GHFAIL="$TMP/shim-ghfail"
mkdir -p "$GHFAIL"
printf '#!/bin/bash\nexit 3\n' > "$GHFAIL/gh"
chmod +x "$GHFAIL/gh"

# gh shim, mode B: fixture-driven. Distinguishes the three sentinel probes and
# `gh issue view N --json updatedAt` by argv shape; fixtures live in $GH_FIXTURES.
GHFIX_BIN="$TMP/shim-ghfix"
mkdir -p "$GHFIX_BIN"
cat > "$GHFIX_BIN/gh" <<'EOF'
#!/bin/bash
prev="" mode="open" view_n=""
for a in "$@"; do
  [ "$a" = "view" ] && mode="view"
  [ "$prev" = "view" ] && view_n="$a"
  if [ "$prev" = "--label" ] && [ "$a" = "awaiting-integration" ]; then mode="awaiting"; fi
  case "$a" in *'label:"working"'*) mode="working" ;; esac
  prev="$a"
done
case "$mode" in
  view)     cat "$GH_FIXTURES/updated_$view_n" 2>/dev/null; exit 0 ;;
  awaiting) cat "$GH_FIXTURES/awaiting.json" ;;
  working)  echo '[]' ;;
  open)     echo '[]' ;;
esac
EOF
chmod +x "$GHFIX_BIN/gh"

# ── helpers ─────────────────────────────────────────────────────────────────

# new_project <label> <file|github> → prints the project dir. The random
# mktemp suffix keeps the derived session name (claude-<basename>) unique per
# run, so /proc marker scans can never collide with a parallel run's sleepers.
# The basename must stay DOT-FREE: it becomes a tmux session name, and tmux
# parses "." in a target as the session/window separator.
new_project() {
  local label="$1" src="$2" dir
  dir=$(mktemp -d "$TMP/${label}XXXXXX") || return 1
  git init -q "$dir"
  if [ "$src" = file ]; then
    mkdir -p "$dir/.issues"
    printf '{"issueSource":"file","issueDir":"%s"}\n' "$dir/.issues" > "$dir/.autocoder.json"
  else
    printf '{"issueSource":"github"}\n' > "$dir/.autocoder.json"
  fi
  echo "$dir"
}

# run_sentinel <path-prefix> [VAR=val ...] -- <sentinel args...>
# Hermetic environment: only what is listed here reaches the sentinel.
run_sentinel() {
  local pathpfx="$1"; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift  # the --
  env -i HOME="$FAKEHOME" PATH="$pathpfx" TMUX_TMPDIR="$TMUX_TMPDIR" \
    TERM=xterm "${envs[@]}" bash "$SENTINEL" "$@"
}

state_get_t() {  # state_get_t <project> <dotted.key>
  python3 - "$1/.autocoder/sentinel-state.json" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for part in sys.argv[2].split("."):
    if not isinstance(d, dict) or part not in d:
        sys.exit(0)
    d = d[part]
print(d)
PY
}

sha_hex() { printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }

install_notify_hook() {  # writes notifications to .autocoder/notify.log
  mkdir -p "$1/.autocoder"
  cat > "$1/.autocoder/sentinel-hooks.sh" <<'EOF'
sentinel_notify() { printf '%s\n' "$1" >> "$AC_DIR/notify.log"; }
EOF
}

# start_marker_sleeper <session> <cwd> — background process whose /proc
# environ carries AUTOCODER_MANAGER=<session>. Sets SLEEPER_PID (a global,
# NOT echoed: calling this in a command substitution would hand the pipe to
# the sleeper and block the substitution until the sleeper exits). Stdio is
# detached for the same reason.
start_marker_sleeper() {
  bash -c 'cd "$1" && exec env AUTOCODER_MANAGER="$2" sleep 300' _ "$2" "$1" \
    </dev/null >/dev/null 2>&1 &
  SLEEPER_PID=$!
  CLEANUP_PIDS+=("$SLEEPER_PID")
  # Wait for the exec chain to settle so process_start_time is stable.
  sleep 0.3
}

# write_manager_manifest <project> <session> <pid> <start> [tmuxTarget]
write_manager_manifest() {
  local proj="$1" session="$2" pid="$3" start="$4" ttarget="${5:-}"
  local mgr mf
  mgr=$(manifest_manager_json shell false shell ".autocoder/swarm/$session.ready.txt" \
    "$ttarget" "" "" "$pid" "$start" "AUTOCODER_MANAGER=$session")
  mf=$(manifest_path_for_session "$proj" "$session")
  write_swarm_manifest "$mf" "$session" "$proj" "$(basename "$proj")" claude tmux \
    file configured "" "$proj/.issues" task-test main "[]" "$mgr" running
  echo "$mf"
}

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# seed_state <project> <json> — pre-seed sentinel-state.json.
seed_state() {
  mkdir -p "$1/.autocoder"
  printf '%s\n' "$2" > "$1/.autocoder/sentinel-state.json"
}

# ═════════════════════════════════════════════════════════════════════════════
# 1a. Predicate: quiescent tick (file backend, empty queue)
# ═════════════════════════════════════════════════════════════════════════════
P=$(new_project quiesc file)
run_sentinel "$BASEPATH" -- --once --project "$P" >/dev/null 2>&1
[ "$(state_get_t "$P" last_tick_result)" = "quiescent" ] \
  && ok "empty file queue ticks quiescent" \
  || bad "empty file queue: last_tick_result=$(state_get_t "$P" last_tick_result), wanted quiescent"
[ "$(state_get_t "$P" consecutive_errors)" = "0" ] \
  && ok "quiescent tick resets consecutive_errors to 0" \
  || bad "quiescent tick: consecutive_errors=$(state_get_t "$P" consecutive_errors)"
grep -q "TICK result=quiescent predicate=\[claimable=0" "$P/.autocoder/sentinel.log" \
  && ok "quiescent tick logs its predicate summary" \
  || bad "quiescent tick: no predicate summary in sentinel.log"
# First-ever tick starts the duty clock instead of firing a duty wake.
[ -n "$(state_get_t "$P" last_duty_wake_at)" ] \
  && ok "first tick starts the duty clock" \
  || bad "first tick did not record last_duty_wake_at"

# ═════════════════════════════════════════════════════════════════════════════
# 1b. Predicate: claimable issue → wake decision (dry-run), zero side effects
# ═════════════════════════════════════════════════════════════════════════════
P=$(new_project claim file)
ISSUE_NUM=$(ISSUE_DIR_PATH="$P/.issues" python3 "$SCRIPTS/issues-file.py" create \
  --title "sentinel test issue" --body "b" | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
OUT=$(run_sentinel "$BASEPATH" AUTOCODER_MUX=tmux -- --dry-run --project "$P" 2>&1)
echo "$OUT" | grep -q "DRY-RUN wake plan (mux=tmux, session=claude-$(basename "$P"), reason=claimable)" \
  && ok "dry-run: claimable issue produces a tmux wake plan" \
  || bad "dry-run: no claimable wake plan in output: $OUT"
echo "$OUT" | grep -q "export AUTOCODER_MANAGER=claude-$(basename "$P") AUTOCODER_UNATTENDED=1" \
  && ok "dry-run: spawn env exports marker + unattended policy" \
  || bad "dry-run: marker/unattended export line missing"
echo "$OUT" | grep -q -- "claude --dangerously-skip-permissions" \
  && ok "dry-run: claude launches argv-mode with --dangerously-skip-permissions" \
  || bad "dry-run: claude launch line missing"
echo "$OUT" | grep -q "manager-resume.*--non-interactive" \
  && ok "dry-run: wake prompt sequences manager-resume --non-interactive" \
  || bad "dry-run: wake prompt lacks manager-resume --non-interactive"
# Argv mode = single launch line; the "then type the prompt" step must be absent.
echo "$OUT" | grep -q "after the TUI settles" \
  && bad "dry-run: claude wake fell back to post-spawn typing (consent-dialog unsafe)" \
  || ok "dry-run: claude wake has no post-spawn prompt typing"
[ ! -e "$P/.autocoder/sentinel-state.json" ] && [ ! -e "$P/.autocoder/sentinel.log" ] \
  && ok "dry-run: no state file and no log were written" \
  || bad "dry-run: side effects found under $P/.autocoder"

# ═════════════════════════════════════════════════════════════════════════════
# 1c. Dry-run spawn plans for the other muxes (forced via AUTOCODER_MUX)
# ═════════════════════════════════════════════════════════════════════════════
for mux in cmux herdr; do
  OUT=$(run_sentinel "$BASEPATH" AUTOCODER_MUX=$mux -- --dry-run --project "$P" 2>&1)
  echo "$OUT" | grep -q "DRY-RUN wake plan (mux=$mux," \
    && ok "dry-run: $mux wake plan renders" \
    || bad "dry-run: $mux wake plan missing: $OUT"
  echo "$OUT" | grep -q -- "--manager-only --mux $mux" \
    && ok "dry-run: $mux bootstrap goes through start-parallel-agents --manager-only" \
    || bad "dry-run: $mux bootstrap line missing"
  echo "$OUT" | grep -q "export AUTOCODER_MANAGER=.* AUTOCODER_UNATTENDED=1" \
    && ok "dry-run: $mux spawn exports marker + unattended policy" \
    || bad "dry-run: $mux marker/unattended export missing"
done

# ═════════════════════════════════════════════════════════════════════════════
# 1d. Backend error is NOT quiescence: consecutive_errors climbs, escalation
#     fires at tolerance (default 2). The escalation wake is made harmless by
#     an unresolvable agent (fails before any mux call).
# ═════════════════════════════════════════════════════════════════════════════
P=$(new_project gherr github)
install_notify_hook "$P"
run_sentinel "$GHFAIL:$BASEPATH" -- --once --project "$P" >/dev/null 2>&1
[ "$(state_get_t "$P" last_tick_result)" = "error" ] \
  && ok "gh exit-3: tick result is error, not quiescent" \
  || bad "gh exit-3: last_tick_result=$(state_get_t "$P" last_tick_result)"
[ "$(state_get_t "$P" consecutive_errors)" = "1" ] \
  && ok "gh exit-3: consecutive_errors incremented to 1" \
  || bad "gh exit-3: consecutive_errors=$(state_get_t "$P" consecutive_errors)"
run_sentinel "$GHFAIL:$BASEPATH" AUTOCODER_MUX=tmux AUTOCODER_AGENT=bogusagent \
  -- --once --project "$P" >/dev/null 2>&1
grep -q "consecutive errored ticks — escalation wake" "$P/.autocoder/notify.log" \
  && ok "error tolerance reached: escalation wake notified" \
  || bad "error tolerance: no escalation notify recorded"
[ "$(state_get_t "$P" last_tick_result)" = "wake-failed:error-escalation" ] \
  && ok "escalation wake attempted (and failed harmlessly on bogus agent)" \
  || bad "escalation: last_tick_result=$(state_get_t "$P" last_tick_result)"
grep -q "result=quiescent" "$P/.autocoder/sentinel.log" \
  && bad "backend errors were misread as quiescence" \
  || ok "no errored tick ever reported quiescent"

# ═════════════════════════════════════════════════════════════════════════════
# 2. flock -n: two concurrent --once ticks → exactly one runs, one skips
# ═════════════════════════════════════════════════════════════════════════════
P=$(new_project flock file)
mkdir -p "$P/.autocoder"
cat > "$P/.autocoder/sentinel-hooks.sh" <<'EOF'
sentinel_health_probe() { sleep 3; return 0; }
EOF
run_sentinel "$BASEPATH" -- --once --project "$P" >/dev/null 2>&1 &
T1=$!
sleep 0.6
run_sentinel "$BASEPATH" -- --once --project "$P" >/dev/null 2>&1 &
T2=$!
wait "$T1" "$T2"
SKIPS=$(grep -c "result=skip (tick lock contended)" "$P/.autocoder/sentinel.log")
TICKS=$(grep -c "TICK result=quiescent" "$P/.autocoder/sentinel.log")
[ "$SKIPS" = "1" ] && [ "$TICKS" = "1" ] \
  && ok "contended tick lock: one tick ran, one logged a skip" \
  || bad "contended tick lock: skips=$SKIPS ticks=$TICKS (wanted 1/1)"
[ -s "$P/.autocoder/sentinel.skips" ] \
  && ok "the skipped tick was recorded toward the error tolerance" \
  || bad "no sentinel.skips entry from the contended tick"

# ═════════════════════════════════════════════════════════════════════════════
# 3a. Two-manager guard: live manifest identity → observe mode, no spawn
# ═════════════════════════════════════════════════════════════════════════════
P=$(new_project guard file)
SESSION="claude-$(basename "$P")"
start_marker_sleeper "$SESSION" "$P"; MPID=$SLEEPER_PID
MSTART=$(process_start_time "$MPID")
MF=$(write_manager_manifest "$P" "$SESSION" "$MPID" "$MSTART")
touch "$P/.autocoder/manager-heartbeat"
run_sentinel "$BASEPATH" -- --once --project "$P" >/dev/null 2>&1
[ "$(state_get_t "$P" last_tick_result)" = "observe" ] \
  && ok "live manager identity: sentinel enters observe mode" \
  || bad "live manager: last_tick_result=$(state_get_t "$P" last_tick_result)"
kill -0 "$MPID" 2>/dev/null \
  && ok "live manager was not touched" \
  || bad "live manager process was killed"
[ "$(manifest_manager_field "$MF" pid)" = "$MPID" ] \
  && ok "manifest manager entry preserved in observe mode" \
  || bad "manifest manager entry changed: pid=$(manifest_manager_field "$MF" pid)"

# ═════════════════════════════════════════════════════════════════════════════
# 3b. Two-manager guard: dead pid → manifest entry cleared under the lock
# ═════════════════════════════════════════════════════════════════════════════
kill "$MPID" 2>/dev/null; wait "$MPID" 2>/dev/null
run_sentinel "$BASEPATH" -- --once --project "$P" >/dev/null 2>&1
[ -z "$(manifest_get "$MF" 'm.get("manager")')" ] \
  && ok "dead manager pid: manifest manager entry cleared" \
  || bad "dead manager pid: manifest still has $(manifest_get "$MF" 'm.get("manager")')"
grep -q "MANIFEST cleared manager entry (pid $MPID dead or start-time mismatch)" "$P/.autocoder/sentinel.log" \
  && ok "clearing was logged with the dead identity" \
  || bad "no MANIFEST-cleared log line for pid $MPID"

# ═════════════════════════════════════════════════════════════════════════════
# 4. Backoff/dedup state machinery: same reason with the same issues-hash at
#    the dedup threshold → backoff recorded; expiry with no state change →
#    the backoff doubles; a changed hash resets count and clears backoff.
#    (record_wake only counts SUCCESSFUL wakes, so the threshold is seeded.)
# ═════════════════════════════════════════════════════════════════════════════
P=$(new_project dedup file)
N=$(ISSUE_DIR_PATH="$P/.issues" python3 "$SCRIPTS/issues-file.py" create \
  --title "dedup issue" --body "b" | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
H=$(sha_hex "claimable:$N")
install_notify_hook "$P"
seed_state "$P" "{\"version\":1,\"last_duty_wake_at\":\"$NOW_ISO\",\"dedup\":{\"claimable\":{\"hash\":\"$H\",\"count\":3}}}"
run_sentinel "$BASEPATH" AUTOCODER_SENTINEL_BACKOFF_BASE=120 -- --once --project "$P" >/dev/null 2>&1
[ "$(state_get_t "$P" last_tick_result)" = "backoff:claimable" ] \
  && ok "3x same wake hash: wake suppressed into backoff" \
  || bad "dedup threshold: last_tick_result=$(state_get_t "$P" last_tick_result)"
[ "$(state_get_t "$P" backoff.claimable.seconds)" = "120" ] \
  && ok "first backoff records the base interval" \
  || bad "first backoff seconds=$(state_get_t "$P" backoff.claimable.seconds), wanted 120"
grep -q "fired 3 times with no state change" "$P/.autocoder/notify.log" \
  && ok "backoff entry fired the notify hook" \
  || bad "no backoff notify recorded"
# Expire the backoff without changing the observable state → doubling.
python3 - "$P/.autocoder/sentinel-state.json" <<'PY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["backoff"]["claimable"]["until_epoch"] = int(time.time()) - 5
json.dump(d, open(p, "w"))
PY
run_sentinel "$BASEPATH" AUTOCODER_SENTINEL_BACKOFF_BASE=120 -- --once --project "$P" >/dev/null 2>&1
[ "$(state_get_t "$P" backoff.claimable.seconds)" = "240" ] \
  && ok "unchanged state after backoff expiry: interval doubles" \
  || bad "backoff doubling: seconds=$(state_get_t "$P" backoff.claimable.seconds), wanted 240"
# Observable state change (second issue) → dedup + backoff reset, wake goes
# (harmlessly failed on a bogus agent — no mux is ever touched).
N2=$(ISSUE_DIR_PATH="$P/.issues" python3 "$SCRIPTS/issues-file.py" create \
  --title "second issue" --body "b" | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
run_sentinel "$BASEPATH" AUTOCODER_MUX=tmux AUTOCODER_AGENT=bogusagent \
  -- --once --project "$P" >/dev/null 2>&1
[ "$(state_get_t "$P" dedup.claimable.count)" = "0" ] \
  && [ "$(state_get_t "$P" dedup.claimable.hash)" = "$(sha_hex "claimable:$N,$N2")" ] \
  && [ "$(state_get_t "$P" backoff.claimable.until_epoch)" = "0" ] \
  && ok "changed issues-hash resets dedup count and clears the backoff" \
  || bad "hash change: count=$(state_get_t "$P" dedup.claimable.count) until=$(state_get_t "$P" backoff.claimable.until_epoch)"

# ═════════════════════════════════════════════════════════════════════════════
# 5a. Heartbeat wedge: stale heartbeat + in-flight gate from this checkout →
#     the manager is NOT killed
# ═════════════════════════════════════════════════════════════════════════════
P=$(new_project wedge file)
SESSION="claude-$(basename "$P")"
start_marker_sleeper "$SESSION" "$P"; MPID=$SLEEPER_PID
MSTART=$(process_start_time "$MPID")
MF=$(write_manager_manifest "$P" "$SESSION" "$MPID" "$MSTART")
mkdir -p "$P/.autocoder"
touch -d @$(( $(date +%s) - 1800 )) "$P/.autocoder/manager-heartbeat"
printf '#!/bin/bash\nsleep 60\n' > "$P/merge-to-integration.sh"
chmod +x "$P/merge-to-integration.sh"
bash -c 'cd "$1" && exec bash "$1/merge-to-integration.sh"' _ "$P" &
GPID=$!
CLEANUP_PIDS+=("$GPID")
sleep 0.3
run_sentinel "$BASEPATH" AUTOCODER_SENTINEL_INTERVAL=60 -- --once --project "$P" >/dev/null 2>&1
grep -q "HEARTBEAT stale .* gate/deploy in flight — not touching the manager" "$P/.autocoder/sentinel.log" \
  && ok "stale heartbeat + in-flight gate: kill was withheld and logged" \
  || bad "in-flight gating: expected HEARTBEAT-stale/in-flight log line"
kill -0 "$MPID" 2>/dev/null \
  && ok "manager survived the in-flight-gated tick" \
  || bad "manager was killed despite an in-flight gate"
pkill -P "$GPID" 2>/dev/null; kill "$GPID" 2>/dev/null; wait "$GPID" 2>/dev/null

# ═════════════════════════════════════════════════════════════════════════════
# 5b. Heartbeat wedge: stale heartbeat, NO in-flight, static process →
#     kill decision (asserted via --dry-run; the manager must survive)
# ═════════════════════════════════════════════════════════════════════════════
OUT=$(run_sentinel "$BASEPATH" AUTOCODER_SENTINEL_INTERVAL=60 AUTOCODER_MUX=tmux \
  -- --once --dry-run --project "$P" 2>&1)
echo "$OUT" | grep -q "DRY-RUN would kill wedged manager pid=$MPID and respawn" \
  && ok "stale heartbeat + static process: kill+respawn decision reached" \
  || bad "wedge kill decision missing from dry-run output: $OUT"
kill -0 "$MPID" 2>/dev/null \
  && ok "dry-run wedge tick did not actually kill the manager" \
  || bad "dry-run killed the manager"
kill "$MPID" 2>/dev/null; wait "$MPID" 2>/dev/null

# ═════════════════════════════════════════════════════════════════════════════
# 6. Orphan sweep: a marker-bearing process that is not the manifest manager
#    is killed; the manifest manager survives
# ═════════════════════════════════════════════════════════════════════════════
P=$(new_project orphan file)
SESSION="claude-$(basename "$P")"
start_marker_sleeper "$SESSION" "$P"; MPID=$SLEEPER_PID
MSTART=$(process_start_time "$MPID")
MF=$(write_manager_manifest "$P" "$SESSION" "$MPID" "$MSTART")
touch "$P/.autocoder/manager-heartbeat"
start_marker_sleeper "$SESSION" "$P"; OPID=$SLEEPER_PID
run_sentinel "$BASEPATH" -- --once --project "$P" >/dev/null 2>&1
sleep 0.5
kill -0 "$OPID" 2>/dev/null \
  && bad "orphan marker process survived the sweep" \
  || ok "orphan marker process was killed"
kill -0 "$MPID" 2>/dev/null \
  && ok "manifest manager survived the orphan sweep" \
  || bad "orphan sweep killed the manifest manager"
grep -q "ORPHAN killing marker-bearing pid $OPID" "$P/.autocoder/sentinel.log" \
  && ok "orphan kill was logged with its pid" \
  || bad "no ORPHAN log line for pid $OPID"
kill "$MPID" 2>/dev/null; wait "$MPID" 2>/dev/null

# ═════════════════════════════════════════════════════════════════════════════
# 7+8(duty). Real wake on a PRIVATE tmux server: stale-counter reset, duty
#    wake expiring ALL standing conditions, manifest identity recording, and
#    spawn-verification against the stub agent.
# ═════════════════════════════════════════════════════════════════════════════
if ! command -v tmux >/dev/null 2>&1; then
  echo "SKIP: tmux not available for the live wake and --manager-only checks"
else
  P=$(new_project wake file)
  SESSION="claude-$(basename "$P")"
  mkdir -p "$P/.autocoder"
  printf '2\n' > "$P/.autocoder/quiescent-iterations"
  cat > "$P/MANAGER-STATE.md" <<'EOF'
# Manager state
```sentinel-standing
SENTINEL-STANDING: 42 2026-09-10T00:00:00Z waiting on human
SENTINEL-STANDING: 43 2026-09-11T00:00:00Z cross-repo PR
```
Priorities text that must survive.
EOF
  seed_state "$P" '{"version":1,"last_duty_wake_at":"2020-01-01T00:00:00Z"}'
  env -i HOME="$FAKEHOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" TERM=xterm \
    tmux new-session -d -s "$SESSION" -n review -x 200 -y 50
  run_sentinel "$BASEPATH" AUTOCODER_MUX=tmux AUTOCODER_SENTINEL_ACTIVITY_TIMEOUT=25 \
    -- --once --project "$P" >/dev/null 2>&1
  [ "$(state_get_t "$P" last_tick_result)" = "wake:duty" ] \
    && ok "duty wake spawned and verified a manager (stub) end-to-end" \
    || bad "real wake: last_tick_result=$(state_get_t "$P" last_tick_result), wanted wake:duty"
  [ -f "$P/.autocoder/quiescent-iterations" ] && [ ! -s "$P/.autocoder/quiescent-iterations" ] \
    && ok "pre-seeded quiescent-iterations counter was truncated by the wake" \
    || bad "quiescent-iterations not truncated: '$(cat "$P/.autocoder/quiescent-iterations" 2>/dev/null)'"
  grep -q "SENTINEL-STANDING:" "$P/MANAGER-STATE.md" \
    && bad "duty wake left standing conditions behind" \
    || ok "duty wake expired ALL standing conditions"
  grep -q "Priorities text that must survive." "$P/MANAGER-STATE.md" \
    && ok "MANAGER-STATE.md content outside the fence untouched" \
    || bad "MANAGER-STATE.md lost non-fence content"
  MF=$(manifest_path_for_session "$P" "$SESSION")
  WPID=$(manifest_manager_field "$MF" pid)
  if [ -n "$WPID" ] && kill -0 "$WPID" 2>/dev/null; then
    ok "manifest records the spawned manager pid ($WPID, alive)"
    CLEANUP_PIDS+=("$WPID")
  else
    bad "manifest manager pid missing or dead after wake: '$WPID'"
  fi
  [ "$(manifest_manager_field "$MF" marker)" = "AUTOCODER_MANAGER=$SESSION" ] \
    && [ -n "$(manifest_manager_field "$MF" pid_start_time)" ] \
    && ok "manifest manager identity fields (marker, pid_start_time) recorded" \
    || bad "manifest identity fields incomplete after wake"
  [ "$(state_get_t "$P" dedup.duty.count)" = "1" ] \
    && ok "successful wake recorded in dedup state" \
    || bad "dedup.duty.count=$(state_get_t "$P" dedup.duty.count), wanted 1"
  [ "$(state_get_t "$P" last_duty_wake_at)" != "2020-01-01T00:00:00Z" ] \
    && ok "duty clock advanced after the duty wake" \
    || bad "last_duty_wake_at was not updated"
  env -i HOME="$FAKEHOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" TERM=xterm \
    tmux kill-session -t "$SESSION" 2>/dev/null

  # ═══════════════════════════════════════════════════════════════════════════
  # 9. start-parallel-agents.sh --manager-only (U2): manifest shape
  # ═══════════════════════════════════════════════════════════════════════════
  P=$(new_project mgronly file)
  SESSION="claude-$(basename "$P")"
  ( cd "$P" && env -i HOME="$FAKEHOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" TERM=xterm \
      bash "$SCRIPTS/start-parallel-agents.sh" --manager-only --mux tmux --agent claude \
      --issue-source file --issue-dir "$P/.issues" </dev/null ) >/dev/null 2>&1
  MF=$(manifest_path_for_session "$P" "$SESSION")
  if [ -f "$MF" ]; then
    ok "--manager-only wrote the swarm manifest"
    [ "$(manifest_get "$MF" 'len(m.get("workers", []))')" = "0" ] \
      && ok "--manager-only manifest has zero workers" \
      || bad "--manager-only workers: $(manifest_get "$MF" 'm.get("workers")')"
    [ "$(manifest_manager_field "$MF" marker)" = "AUTOCODER_MANAGER=$SESSION" ] \
      && ok "--manager-only manager entry carries the identity marker" \
      || bad "--manager-only marker: '$(manifest_manager_field "$MF" marker)'"
    [ -n "$(manifest_manager_field "$MF" tmuxTarget)" ] \
      && [ -n "$(manifest_manager_field "$MF" spawned_at)" ] \
      && ok "--manager-only manager entry has tmuxTarget and spawned_at" \
      || bad "--manager-only manager entry incomplete"
    [ -z "$(manifest_manager_field "$MF" pid)" ] \
      && ok "--manager-only records pid null (nothing dispatched)" \
      || bad "--manager-only recorded a pid: $(manifest_manager_field "$MF" pid)"
    [ "$(manifest_get "$MF" 'm.get("state")')" = "paused" ] \
      && ok "--manager-only swarm state is paused" \
      || bad "--manager-only state: $(manifest_get "$MF" 'm.get("state")')"
  else
    bad "--manager-only did not write a manifest at $MF"
  fi
  env -i HOME="$FAKEHOME" PATH="$BASEPATH" TMUX_TMPDIR="$TMUX_TMPDIR" TERM=xterm \
    tmux kill-session -t "$SESSION" 2>/dev/null
fi

# ═════════════════════════════════════════════════════════════════════════════
# 8. Standing conditions: unchanged updatedAt is honoured (subtracted from the
#    banked predicate); a changed updatedAt drops the condition and wakes
# ═════════════════════════════════════════════════════════════════════════════
P=$(new_project stand github)
GH_FIXTURES="$TMP/ghfix-$(basename "$P")"
mkdir -p "$GH_FIXTURES"
echo '[{"number":42,"title":"t","body":"b","state":"OPEN","labels":[{"name":"awaiting-integration"}],"comments":[]}]' \
  > "$GH_FIXTURES/awaiting.json"
echo '2026-09-10T00:00:00Z' > "$GH_FIXTURES/updated_42"
cat > "$P/MANAGER-STATE.md" <<'EOF'
```sentinel-standing
SENTINEL-STANDING: 42 2026-09-10T00:00:00Z waiting on human
```
EOF
seed_state "$P" "{\"version\":1,\"last_duty_wake_at\":\"$NOW_ISO\"}"
run_sentinel "$GHFIX_BIN:$BASEPATH" GH_FIXTURES="$GH_FIXTURES" -- --once --project "$P" >/dev/null 2>&1
[ "$(state_get_t "$P" last_tick_result)" = "quiescent" ] \
  && ok "standing condition subtracts its issue from the banked predicate" \
  || bad "standing kept: last_tick_result=$(state_get_t "$P" last_tick_result), wanted quiescent"
grep -q "SENTINEL-STANDING: 42" "$P/MANAGER-STATE.md" \
  && ok "unchanged updatedAt keeps the standing condition" \
  || bad "standing condition was dropped despite an unchanged updatedAt"
echo '2026-09-15T09:00:00Z' > "$GH_FIXTURES/updated_42"
run_sentinel "$GHFIX_BIN:$BASEPATH" GH_FIXTURES="$GH_FIXTURES" \
  AUTOCODER_MUX=tmux AUTOCODER_AGENT=bogusagent -- --once --project "$P" >/dev/null 2>&1
grep -q "SENTINEL-STANDING: 42" "$P/MANAGER-STATE.md" \
  && bad "changed updatedAt did not drop the standing condition" \
  || ok "changed updatedAt drops the standing condition from MANAGER-STATE.md"
grep -q "STANDING drop #42" "$P/.autocoder/sentinel.log" \
  && ok "the drop was logged with old→new updatedAt" \
  || bad "no STANDING drop log line"
[ "$(state_get_t "$P" last_tick_result)" = "wake-failed:banked" ] \
  && ok "the freed issue re-armed the banked wake predicate" \
  || bad "after drop: last_tick_result=$(state_get_t "$P" last_tick_result), wanted wake-failed:banked"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
