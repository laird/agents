#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# Quota failover: pane-text detection, candidate selection, and the switch
# command sequence. GitHub API / GraphQL rate-limit text must not count.
set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
LIB="$SCRIPTS/quota-failover-lib.sh"
SCRIPT="$SCRIPTS/quota-failover.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 — missing '$2' in: $3"; fi
}
assert_not_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 — unexpected '$2' in: $3"; else ok "$1"; fi
}

# shellcheck source=plugins/autocoder/scripts/quota-failover-lib.sh
source "$LIB"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/panes"
export HOME="$T/home"

cat > "$T/bin/agent" <<'STUB'
#!/bin/bash
base=$(basename "$0")
case "$base:$1:${2:-}" in
  codex:login:status) exit "${CODEX_AUTH_RC:-0}" ;;
  *:auth:status) exit "${AGENT_AUTH_RC:-0}" ;;
esac
exit 0
STUB
chmod +x "$T/bin/agent"
for a in claude codex grok gemini droid pi; do cp "$T/bin/agent" "$T/bin/$a"; done

cat > "$T/bin/herdr" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${HERDR_ARGV:?}"
case "$1 $2" in
  "agent list") cat "${HERDR_STUB_AGENTS:?}" ;;
  "pane read")
    f="${HERDR_STUB_PANES:?}/${3//:/_}"
    [ -f "$f" ] && cat "$f"
    ;;
  "workspace create")
    [ -n "${HERDR_CREATE_SLEEP:-}" ] && sleep "$HERDR_CREATE_SLEEP"
    printf '%s\n' '{"result":{"root_pane":{"pane_id":"w9:p1"}}}'
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/bin/herdr"

cat > "$T/bin/tmux" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${TMUX_ARGV:?}"
case "$1" in
  has-session) exit 1 ;;
  list-panes) printf '%s|claude-repo:0.1\n' "${TMUX_WT:?}" ;;
  capture-pane) cat "${TMUX_PANE:?}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/bin/tmux"

cat > "$T/bin/restart-worker.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${RESTART_ARGV:?}"
exit 0
STUB
chmod +x "$T/bin/restart-worker.sh"

cat > "$T/bin/crontab" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "-l" ]; then cat "$CRONTAB_FILE" 2>/dev/null || exit 1
elif [ "${1:-}" = "-" ]; then cat > "$CRONTAB_FILE.new" && mv "$CRONTAB_FILE.new" "$CRONTAB_FILE"
fi
STUB
chmod +x "$T/bin/crontab"

CLAUDE_WEEKLY='You'"'"'ve hit your weekly limit · resets Nov 27, 12am (America/New_York) · out of usage credits
Stop and wait for limit to reset
Wait here, then continue automatically
Add funds to continue with usage credits
⚠ Usage limit reached · limit resets Nov 27, 12am (America/New_York)
Continuing automatically at 12:00 AM · Esc to cancel · /usage-credits to continue now
Goal paused · usage limit reached
/rate-limit-options'

CLAUDE_BANNER='⚠ Usage limit reached · limit resets Nov 27, 12am (America/New_York)
Continuing automatically at 12:00 AM · Esc to cancel · /usage-credits to continue now'

GROK_LIMIT='API rate limit. Ask a team admin to purchase more credits
Usage limits are managed by your team.'

CODEX_LIMIT='rate limit exceeded
unknown rate limit reached type: usage_limit'

GITHUB_LIMIT='gh: API rate limit exceeded for user ID 768147. (But here'"'"'s the good news: Authenticated requests get a higher rate limit.)
GraphQL: You have exceeded a secondary rate limit. Please wait a few minutes before you try again.
X-RateLimit-Remaining: 0'

TPM_LIMIT='Rate limit reached for gpt-5.1 in organization org-x on tokens per min (TPM): Limit 200000, Used 162960, Requested 42288. Please try again in 1.574s.'

exhausted() { # exhausted <agent>  (text on stdin)
  quota_pane_exhausted "$1"
}

# ── detection ────────────────────────────────────────────────────────────────
printf '%s\n' "$CLAUDE_WEEKLY" | exhausted claude && ok "claude weekly dialog is quota" || bad "claude weekly dialog is quota"
printf '%s\n' "$CLAUDE_BANNER" | exhausted claude && ok "claude banner without the dialog is quota" || bad "claude banner without the dialog is quota"
printf '%s\n' "You've hit your 5-hour limit · resets 6:20pm (America/Cambridge_Bay)" | exhausted claude \
  && ok "claude 5-hour limit is quota" || bad "claude 5-hour limit is quota"
printf '%s\n' "You've hit your Opus limit · resets 3:45pm" | exhausted claude \
  && bad "opus-only limit is not a platform quota hit" || ok "opus-only limit is not a platform quota hit"
printf '%s\n' "$CLAUDE_WEEKLY" | exhausted grok \
  && bad "claude text is not a grok hit" || ok "claude text is not a grok hit"
printf '%s\n' "$GROK_LIMIT" | exhausted grok && ok "grok credit strings are quota" || bad "grok credit strings are quota"
printf '%s\n' "$GROK_LIMIT" | exhausted codex \
  && bad "grok text is not a codex hit" || ok "grok text is not a codex hit"
printf '%s\n' "$CODEX_LIMIT" | exhausted codex && ok "codex rate-limit strings are quota" || bad "codex rate-limit strings are quota"
printf '%s\n' "You've hit your usage limit. Upgrade your plan or add credits to continue, or try again at 20 Aug 2026, 16:29." | exhausted codex \
  && ok "codex usage-limit banner is quota" || bad "codex usage-limit banner is quota"
printf '%s\n' "You're out of Codex and work usage" | exhausted codex && ok "codex allowance banner is quota" || bad "codex allowance banner is quota"
printf '%s\n' "$TPM_LIMIT" | exhausted codex && bad "codex TPM retry is not quota" || ok "codex TPM retry is not quota"
printf '%s\n' "exceeded retry limit, last status: 429 Too Many Requests" | exhausted codex \
  && bad "codex 429 retry is not quota" || ok "codex 429 retry is not quota"
printf '%s\n' "You have reached your daily gemini-2.5-pro quota limit." | exhausted gemini \
  && ok "gemini daily quota is quota" || bad "gemini daily quota is quota"
printf '%s\n' "TerminalQuotaError: You have exhausted your daily quota on this model." | exhausted gemini \
  && ok "gemini TerminalQuotaError is quota" || bad "gemini TerminalQuotaError is quota"
printf '%s\n' "You've reached your usage limit" | exhausted droid && ok "droid usage limit is quota" || bad "droid usage limit is quota"
printf '%s\n' "quota exhausted" | exhausted pi && ok "pi quota exhausted is quota" || bad "pi quota exhausted is quota"

for agent in claude codex grok gemini droid pi; do
  if printf '%s\n' "$GITHUB_LIMIT" | exhausted "$agent"; then
    bad "github rate limit is not a $agent quota hit"
  else
    ok "github rate limit is not a $agent quota hit"
  fi
done
printf '%s\n%s\n' "$GITHUB_LIMIT" "$CLAUDE_BANNER" | exhausted claude \
  && ok "claude banner still counts beside a github rate-limit line" \
  || bad "claude banner still counts beside a github rate-limit line"

# ── reset time ───────────────────────────────────────────────────────────────
NOW_EPOCH=$(python3 -c 'from datetime import datetime, timezone; print(int(datetime(2026,11,26,15,0,tzinfo=timezone.utc).timestamp()))')
EXP_EPOCH=$(python3 -c 'from datetime import datetime; from zoneinfo import ZoneInfo; print(int(datetime(2026,11,27,0,0,tzinfo=ZoneInfo("America/New_York")).timestamp()))')
GOT=$(QUOTA_NOW_EPOCH="$NOW_EPOCH" printf '%s\n' "$CLAUDE_WEEKLY" | quota_parse_reset || true)
case "$GOT" in
  "$EXP_EPOCH"*$'\t'*) ok "reset parses Nov 27, 12am America/New_York" ;;
  *) bad "reset parses Nov 27, 12am America/New_York — got '$GOT' expected $EXP_EPOCH" ;;
esac
QUOTA_STATE_FILE="$T/state-reset.json"
QUOTA_NOW_EPOCH=1000
until=$(quota_record_exhaustion claude "Goal paused · usage limit reached")
[ "$until" = "22600" ] && ok "unparsed reset uses the 6h cooldown" || bad "unparsed reset uses the 6h cooldown — $until"
rm -f "$QUOTA_STATE_FILE" "$QUOTA_STATE_FILE.lock"
unset QUOTA_NOW_EPOCH

# ── preference and selection ─────────────────────────────────────────────────
export QUOTA_STATE_FILE="$T/select.json"
export QUOTA_NOW_EPOCH=5000
quota_state_set exhausted claude 9000 "Nov 27, 12am (America/New_York)"
unset AUTOCODER_AGENT_PREFERENCE
export PATH="$T/bin:/usr/bin:/bin"
unset AUTOCODER_QUOTA_AUTH_CLAUDE AUTOCODER_QUOTA_AUTH_CODEX AUTOCODER_QUOTA_AUTH_GROK \
  AUTOCODER_QUOTA_AUTH_GEMINI AUTOCODER_QUOTA_AUTH_DROID AUTOCODER_QUOTA_AUTH_PI
export CODEX_AUTH_RC=0 AGENT_AUTH_RC=0
best=$(quota_best_usable)
[ "$best" = "codex" ] && ok "selection skips exhausted claude for codex" || bad "selection skips exhausted claude for codex — $best"

export AUTOCODER_QUOTA_AUTH_CODEX='exit 1'
best=$(quota_best_usable)
[ "$best" = "grok" ] && ok "selection skips an unauthenticated codex" || bad "selection skips an unauthenticated codex — $best"
unset AUTOCODER_QUOTA_AUTH_CODEX

rm -f "$T/bin/codex"
best=$(quota_best_usable)
[ "$best" = "grok" ] && ok "selection skips a codex that is not installed" || bad "selection skips a codex that is not installed — $best"
cp "$T/bin/agent" "$T/bin/codex"

export AUTOCODER_AGENT_PREFERENCE='grok,claude'
best=$(quota_best_usable)
[ "$best" = "grok" ] && ok "AUTOCODER_AGENT_PREFERENCE overrides the default order" || bad "AUTOCODER_AGENT_PREFERENCE — $best"
unset AUTOCODER_AGENT_PREFERENCE

mkdir -p "$T/repo"
printf '%s\n' '{"agentPreference":["gemini","grok"]}' > "$T/repo/.autocoder.json"
best=$(QUOTA_REPO="$T/repo" quota_best_usable)
[ "$best" = "gemini" ] && ok ".autocoder.json agentPreference is used" || bad ".autocoder.json agentPreference is used — $best"
best=$(AUTOCODER_AGENT_PREFERENCE='pi' QUOTA_REPO="$T/repo" quota_best_usable)
[ "$best" = "pi" ] && ok "env preference wins over .autocoder.json" || bad "env preference wins over .autocoder.json — $best"
unset AUTOCODER_AGENT_PREFERENCE QUOTA_REPO

QUOTA_NOW_EPOCH=10000
quota_should_failback grok claude && ok "failback once the preferred reset has passed" || bad "failback once the preferred reset has passed"
rm -f "$QUOTA_STATE_FILE"
quota_should_failback grok claude && bad "no failback without a recorded exhaustion" || ok "no failback without a recorded exhaustion"
quota_state_set exhausted claude 20000 "later"
QUOTA_NOW_EPOCH=15000
quota_should_failback grok claude && bad "no failback while the preferred agent is still exhausted" || ok "no failback while the preferred agent is still exhausted"

[ "$(quota_worker_prompt claude 419)" = "/autocoder:fix 419" ] && ok "claude resume is /autocoder:fix N" || bad "claude resume prompt"
[ "$(quota_worker_prompt grok 419)" = "/fix 419" ] && ok "grok resume is /fix N" || bad "grok resume prompt"
[ "$(quota_worker_prompt codex "")" = "/fix-loop" ] && ok "resume without an issue is /fix-loop" || bad "fix-loop prompt"
MGR=$(quota_manager_prompt_lines claude)
printf '%s\n' "$MGR" | grep -qx '/autocoder:manager-resume --non-interactive' && ok "claude manager resume is prefixed" || bad "claude manager resume — $MGR"
printf '%s\n' "$MGR" | grep -qx '/autocoder:monitor-loop' && ok "claude manager loop is prefixed" || bad "claude manager loop — $MGR"
MGR=$(quota_manager_prompt_lines grok)
printf '%s\n' "$MGR" | grep -qx '/manager-resume --non-interactive' && ok "grok manager resume is bare" || bad "grok manager resume — $MGR"
printf '%s\n' "$MGR" | grep -qx '/monitor-loop' && ok "grok manager loop is bare" || bad "grok manager loop — $MGR"

# The watchdog and the restart path must not reset the worktree or auto-approve tools.
for f in "$SCRIPT" "$LIB" "$SCRIPTS/restart-worker.sh"; do
  if grep -qE 'git[[:space:]]+reset|--yolo|--always-approve|dangerously-skip-permissions' "$f"; then
    bad "$(basename "$f") contains git reset or a tool-approval flag"
  else
    ok "$(basename "$f") has no git reset and no tool-approval flag"
  fi
done
bash "$SCRIPTS/restart-worker.sh" --help | grep -qF -- '--prompt' \
  && ok "restart-worker accepts --prompt" || bad "restart-worker accepts --prompt"

# ── swarm fixtures ───────────────────────────────────────────────────────────
unset QUOTA_NOW_EPOCH QUOTA_REPO AUTOCODER_AGENT_PREFERENCE
REPO="$T/repo"
WT="$T/repo-wt-1"
rm -rf "$REPO" "$WT"
git init -q -b master "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" worktree add -q -b feature/issue-419 "$WT"
mkdir -p "$REPO/.autocoder/swarm"

write_manifest() { # write_manifest <mux> <worker-state>
  local mux="$1" state="$2" worker_target manager_target
  case "$mux" in
    herdr) worker_target=w1:p1; manager_target=${3:-} ;;
    tmux) worker_target=claude-repo:0.1; manager_target= ;;
  esac
  python3 - "$REPO/.autocoder/swarm/claude-repo.json" "$mux" "$WT" "$state" "$worker_target" "${manager_target:-}" "$REPO" <<'PY'
import json, sys
path, mux, wt, state, worker_target, manager_target, root = sys.argv[1:]
def tgt(value):
    if mux == "herdr":
        return {"herdrPane": value or None, "tmuxTarget": None, "cmuxWorkspace": None}
    return {"herdrPane": None, "tmuxTarget": value or None, "cmuxWorkspace": None}
workers = []
if worker_target:
    row = {"number": 1, "worktree": wt, "state": state, "launchMode": "interactive", "commandMode": "agent-input"}
    row.update(tgt(worker_target))
    workers.append(row)
manager = {"launchMode": "interactive", "agentLaunched": True, "pid": None}
if manager_target:
    manager.update(tgt(manager_target))
else:
    manager.update(tgt(""))
data = {
    "version": 1, "session": "claude-repo", "projectRoot": root, "projectName": "repo",
    "agent": "claude", "mux": mux, "state": "running", "workers": workers, "manager": manager,
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
}

agents_json() {
  python3 -c 'import json,sys; print(json.dumps({"result":{"agents":[{"agent":sys.argv[1],"pane_id":sys.argv[2],"agent_status":sys.argv[3]}]}}))' "$1" "$2" "$3"
}

run_watch() { # run_watch <mode> [extra env already exported]
  : > "$T/herdr-argv"
  : > "$T/restart-argv"
  PATH="${QUOTA_TEST_PATH:-$T/bin}:/usr/bin:/bin" \
    HERDR_ARGV="$T/herdr-argv" HERDR_STUB_AGENTS="$T/agents.json" HERDR_STUB_PANES="$T/panes" \
    RESTART_ARGV="$T/restart-argv" QUOTA_FAILOVER_RESTART="$T/bin/restart-worker.sh" \
    QUOTA_STATE_FILE="$T/watch-state.json" QUOTA_FAILOVER_COMMENT=0 \
    AUTOCODER_MUX_SUBMIT_DELAY=0 AUTOCODER_QUOTA_LAUNCH_SETTLE=0 \
    CODEX_AUTH_RC="${CODEX_AUTH_RC:-0}" AGENT_AUTH_RC=0 \
    bash "$SCRIPT" "$@"
}

# Worker on herdr, Claude weekly limit, codex unauthenticated → grok, /fix 419.
printf '%s\n' "$CLAUDE_WEEKLY" > "$T/panes/w1_p1"
agents_json claude w1:p1 idle > "$T/agents.json"
write_manifest herdr running
export CODEX_AUTH_RC=1
OUT=$(run_watch --dry-run --repo "$REPO")
assert_contains "dry-run records claude exhaustion" "RECORD claude" "$OUT"
assert_contains "dry-run switches the worker to grok" "SWITCH worker" "$OUT"
assert_contains "dry-run restart keeps the worktree and mux" "--worktree $WT --mux herdr --agent grok" "$OUT"
assert_contains "dry-run sends /fix 419" "--prompt '/fix 419'" "$OUT"
assert_not_contains "dry-run does not git reset" "git reset" "$OUT"
assert_not_contains "dry-run does not pass --yolo" "--yolo" "$OUT"
assert_not_contains "dry-run does not choose Add funds" "Add funds" "$OUT"
assert_not_contains "dry-run does not launch dangerously-skip-permissions" "dangerously-skip-permissions" "$OUT"
[ ! -s "$T/restart-argv" ] && ok "dry-run does not execute restart-worker" || bad "dry-run executed restart-worker"
assert_not_contains "dry-run does not close the workspace" "workspace close" "$(cat "$T/herdr-argv")"

# Same worker, for real: the stub restart receives that argv, and a second tick
# inside the cooldown does not send it again.
rm -f "$T/watch-state.json"
OUT=$(run_watch --once --repo "$REPO")
assert_contains "once comments the issue" "COMMENT issue=419" "$OUT"
assert_contains "once notifies" "NOTIFY Quota failover: claude → grok" "$OUT"
assert_contains "once restart argv is the grok resume" "--worktree $WT --mux herdr --agent grok --prompt /fix 419" "$(cat "$T/restart-argv")"
assert_contains "once raises a herdr notification" "notification show" "$(cat "$T/herdr-argv")"
OUT=$(run_watch --once --repo "$REPO")
assert_contains "cooldown skips a second worker restart" "SKIP worker" "$OUT"
[ ! -s "$T/restart-argv" ] && ok "cooldown does not execute restart-worker again" || bad "cooldown executed restart again — $(cat "$T/restart-argv")"

# Paused worker is left alone. GitHub text on a codex pane is left alone.
printf '%s\n' "$CLAUDE_WEEKLY" > "$T/panes/w1_p1"
write_manifest herdr paused
rm -f "$T/watch-state.json" "$T/restart-argv"
OUT=$(run_watch --dry-run --repo "$REPO")
assert_not_contains "paused worker is not switched" "SWITCH worker" "$OUT"

printf '%s\n' "$GITHUB_LIMIT" > "$T/panes/w1_p1"
agents_json codex w1:p1 idle > "$T/agents.json"
write_manifest herdr running
rm -f "$T/watch-state.json"
OUT=$(CODEX_AUTH_RC=0 run_watch --dry-run --repo "$REPO")
assert_not_contains "github rate limit does not switch a codex pane" "SWITCH" "$OUT"
assert_contains "github rate limit reports no exhaustion" "OK no agent quota exhaustion" "$OUT"

# tmux capture-pane is read the same way.
printf '%s\n' "$CLAUDE_WEEKLY" > "$T/tmux-pane"
agents_json claude w1:p1 idle > "$T/agents.json"
write_manifest tmux running
rm -f "$T/watch-state.json"
: > "$T/tmux-argv"
OUT=$(CODEX_AUTH_RC=1 TMUX_ARGV="$T/tmux-argv" TMUX_WT="$WT" TMUX_PANE="$T/tmux-pane" run_watch --dry-run --repo "$REPO")
assert_contains "tmux pane text switches the worker" "--mux tmux --agent grok --prompt '/fix 419'" "$OUT"

# Failback: claude's recorded reset has passed and the grok pane is idle.
python3 - "$T/watch-state.json" <<PY
import json
json.dump({"exhausted":{"claude":{"until":1,"reset_text":"past","seen":"x"}},"current":{},"switched":{}}, open("$T/watch-state.json","w"))
PY
printf '%s\n' $'❯\nctx 10%' > "$T/panes/w1_p1"
agents_json grok w1:p1 idle > "$T/agents.json"
write_manifest herdr running
OUT=$(QUOTA_NOW_EPOCH=100000 CODEX_AUTH_RC=0 run_watch --dry-run --repo "$REPO")
assert_contains "idle pane fails back to claude" "FAILBACK worker" "$OUT"
assert_contains "failback prompt is the claude command" "--prompt '/autocoder:fix 419'" "$OUT"

# Manager: one restart, grok --trust, bare resume then monitor-loop, no second pane.
printf '%s\n' "$CLAUDE_WEEKLY" > "$T/panes/w0_p1"
agents_json claude w0:p1 blocked > "$T/agents.json"
python3 - "$REPO/.autocoder/swarm/claude-repo.json" "$REPO" <<'PY'
import json, sys
path, root = sys.argv[1:]
data = {
    "version": 1, "session": "claude-repo", "projectRoot": root, "projectName": "repo",
    "agent": "claude", "mux": "herdr", "state": "running", "workers": [],
    "manager": {"launchMode": "interactive", "herdrPane": "w0:p1", "tmuxTarget": None,
                "cmuxWorkspace": None, "pid": None, "agentLaunched": True},
}
json.dump(data, open(path, "w"))
PY
rm -f "$T/watch-state.json"
unset AUTOCODER_CLAUDE_PERMISSION_MODE AUTOCODER_MANAGER_MODEL MANAGER_MODEL
OUT=$(CODEX_AUTH_RC=1 run_watch --dry-run --repo "$REPO")
assert_contains "manager switch names grok" "SWITCH manager from=claude to=grok mux=herdr" "$OUT"
assert_contains "manager launch is grok --trust --always-approve" "LAUNCH grok --trust --always-approve" "$OUT"
assert_contains "manager prompt is bare resume" "PROMPT /manager-resume --non-interactive" "$OUT"
assert_contains "manager prompt is bare monitor-loop" "PROMPT /monitor-loop" "$OUT"
assert_not_contains "manager dry-run has no autocoder prefix" "/autocoder:" "$OUT"
assert_not_contains "manager launch is not yolo" "--yolo" "$OUT"
assert_not_contains "manager launch does not open a pull request" "gh pr create" "$OUT"

rm -f "$T/watch-state.json" "$T/herdr-argv"
OUT=$(CODEX_AUTH_RC=1 run_watch --once --repo "$REPO")
ARGV=$(cat "$T/herdr-argv")
assert_contains "manager close happens" "workspace close w0" "$ARGV"
assert_contains "manager create happens once" "workspace create" "$ARGV"
assert_contains "manager registers kind grok" "agent start manager-repo --kind grok" "$ARGV"
assert_contains "manager forwards --trust" "-- --trust" "$ARGV"
assert_contains "manager sends resume" "agent prompt w9:p1 /manager-resume --non-interactive" "$ARGV"
assert_contains "manager sends monitor-loop" "agent prompt w9:p1 /monitor-loop" "$ARGV"
assert_not_contains "manager argv has no git reset" "git reset" "$ARGV"
assert_not_contains "manager argv does not buy credits" "Add funds" "$ARGV"
# The new pane still shows the limit and herdr still calls it claude. The
# cooldown must refuse a second manager, which would be a second workspace.
printf '%s\n' "$CLAUDE_WEEKLY" > "$T/panes/w9_p1"
agents_json claude w9:p1 blocked > "$T/agents.json"
OUT=$(CODEX_AUTH_RC=1 run_watch --once --repo "$REPO")
assert_contains "second manager tick is inside the cooldown" "SKIP manager" "$OUT"
assert_not_contains "second tick does not create another workspace" "workspace create" "$(cat "$T/herdr-argv")"

# A held tick lock skips, so two watchdogs cannot both restart the manager.
# The successful switch above rewrote the manifest pane; point it back at the
# exhausted pane so both racers still have something to switch.
python3 - "$REPO/.autocoder/swarm/claude-repo.json" "$REPO" <<'PY'
import json, sys
path, root = sys.argv[1:]
data = {
    "version": 1, "session": "claude-repo", "projectRoot": root, "projectName": "repo",
    "agent": "claude", "mux": "herdr", "state": "running", "workers": [],
    "manager": {"launchMode": "interactive", "herdrPane": "w0:p1", "tmuxTarget": None,
                "cmuxWorkspace": None, "pid": None, "agentLaunched": True},
}
json.dump(data, open(path, "w"))
PY
rm -f "$T/lock-state.json" "$T/herdr-argv"
export HERDR_CREATE_SLEEP=0.8
PATH="$T/bin:/usr/bin:/bin" HERDR_ARGV="$T/herdr-argv" HERDR_STUB_AGENTS="$T/agents.json" \
  HERDR_STUB_PANES="$T/panes" RESTART_ARGV="$T/restart-argv" QUOTA_FAILOVER_RESTART="$T/bin/restart-worker.sh" \
  QUOTA_STATE_FILE="$T/lock-state.json" AUTOCODER_MUX_SUBMIT_DELAY=0 AUTOCODER_QUOTA_LAUNCH_SETTLE=0 \
  CODEX_AUTH_RC=1 AGENT_AUTH_RC=0 \
  bash "$SCRIPT" --once --repo "$REPO" >"$T/lock-a.out" 2>&1 &
sleep 0.2
PATH="$T/bin:/usr/bin:/bin" HERDR_ARGV="$T/herdr-argv" HERDR_STUB_AGENTS="$T/agents.json" \
  HERDR_STUB_PANES="$T/panes" RESTART_ARGV="$T/restart-argv" QUOTA_FAILOVER_RESTART="$T/bin/restart-worker.sh" \
  QUOTA_STATE_FILE="$T/lock-state.json" AUTOCODER_MUX_SUBMIT_DELAY=0 AUTOCODER_QUOTA_LAUNCH_SETTLE=0 \
  CODEX_AUTH_RC=1 AGENT_AUTH_RC=0 \
  bash "$SCRIPT" --once --repo "$REPO" >"$T/lock-b.out" 2>&1 || true
wait || true
unset HERDR_CREATE_SLEEP
LOCK_OUT=$(cat "$T/lock-a.out" "$T/lock-b.out")
assert_contains "second tick sees the lock" "SKIP tick lock held" "$LOCK_OUT"
[ "$(grep -c 'workspace create' "$T/herdr-argv")" = "1" ] \
  && ok "lock allows one manager create" \
  || bad "lock allows one manager create — $(grep -c 'workspace create' "$T/herdr-argv")"

# ── Claude, Codex, and Grok are interchangeable ──────────────────────────────
unset AUTOCODER_AGENT_PREFERENCE QUOTA_REPO QUOTA_NOW_EPOCH
PREF=$(quota_preference | head -3 | paste -sd, -)
[ "$PREF" = "claude,codex,grok" ] \
  && ok "default preference starts claude, codex, grok" \
  || bad "default preference starts claude, codex, grok — $PREF"
for a in claude codex grok; do
  quota_preference | grep -qx "$a" && ok "default preference includes $a" || bad "default preference includes $a"
done

# Launch flag + resume text for each of the three, worker and manager.
mkdir -p "$T/goalsbin"
cp "$T/bin/agent" "$T/goalsbin/claude"
cp "$T/bin/herdr" "$T/goalsbin/herdr"
cat > "$T/goalsbin/codex" <<'SH'
#!/bin/sh
case "$1" in
  --version) echo "codex-cli 0.0.0-quota-goals" ;;
  features) echo "goals    true" ;;
  login) exit 0 ;;
esac
exit 0
SH
chmod +x "$T/goalsbin/codex"
rm -f /tmp/codex-goals-probe-codex-cli-0.0.0-quota-goals
MATRIX=$(PATH="$T/goalsbin:/usr/bin:/bin" bash -c '
  source "$1"; source "$2"
  out() { printf "%s\n" "$1"; }
  resolve_worker_launch claude "$3" herdr >/dev/null
  out "claude-launch $AGENT_LAUNCH_CMD"
  out "claude-worker $(quota_worker_prompt claude 7)"
  out "claude-mgr"
  quota_manager_prompt_lines claude
  resolve_worker_launch grok "$3" herdr >/dev/null
  out "grok-launch $AGENT_LAUNCH_CMD"
  out "grok-worker $(quota_worker_prompt grok 7)"
  out "grok-mgr"
  quota_manager_prompt_lines grok
  resolve_worker_launch codex "$3" herdr >/dev/null
  out "codex-launch $AGENT_LAUNCH_CMD"
  out "codex-worker $WORKER_CMD"
  out "codex-mgr $MANAGER_CMD"
' _ "$LIB" "$SCRIPTS/worker-launch-lib.sh" "$ROOT")
assert_contains "claude launch auto-approves" "claude-launch claude --permission-mode bypassPermissions" "$MATRIX"
assert_contains "claude worker resumes the issue" "claude-worker /autocoder:fix 7" "$MATRIX"
assert_contains "claude manager resumes then monitors" "/autocoder:manager-resume --non-interactive" "$MATRIX"
assert_contains "claude manager loop" "/autocoder:monitor-loop" "$MATRIX"
assert_not_contains "claude launch is not the consent-dialog flag" "dangerously-skip-permissions" "$MATRIX"
assert_contains "grok launch auto-approves" "grok-launch grok --trust --always-approve" "$MATRIX"
assert_contains "grok worker resumes the issue" "grok-worker /fix 7" "$MATRIX"
assert_contains "grok manager resumes" "/manager-resume --non-interactive" "$MATRIX"
assert_contains "grok manager loop" "/monitor-loop" "$MATRIX"
assert_contains "codex launch is approval-never" "codex-launch codex --ask-for-approval never" "$MATRIX"
assert_contains "codex worker goal lands through the merge gate" "merge-to-integration.sh" "$MATRIX"
assert_contains "codex worker goal does not open a PR" "Do not open a pull request." "$MATRIX"
assert_contains "codex manager goal does not open a PR" "codex-mgr /goal" "$MATRIX"
assert_not_contains "codex resume is not a pull request" "gh pr create" "$MATRIX"

# One swarm, three panes, three agents. Only the exhausted pane moves.
mkdir -p "$T/wt-grok" "$T/wt-codex"
printf '%s\n' "$CLAUDE_WEEKLY" > "$T/panes/w1_p1"
printf '%s\n' $'❯\nidle grok\n' > "$T/panes/w2_p1"
printf '%s\n' $'❯\nidle codex\n' > "$T/panes/w3_p1"
python3 -c 'import json,sys; print(json.dumps({"result":{"agents":[
  {"agent":"claude","pane_id":"w1:p1","agent_status":"blocked"},
  {"agent":"grok","pane_id":"w2:p1","agent_status":"idle"},
  {"agent":"codex","pane_id":"w3:p1","agent_status":"idle"}]}}))' > "$T/agents.json"
python3 - "$REPO/.autocoder/swarm/claude-repo.json" "$REPO" "$WT" "$T/wt-grok" "$T/wt-codex" <<'PY'
import json, sys
path, root, wt, grok, codex = sys.argv[1:]
def worker(n, worktree, pane, agent):
    return {"number": n, "worktree": worktree, "state": "running", "agent": agent,
            "herdrPane": pane, "tmuxTarget": None, "cmuxWorkspace": None}
data = {
    "version": 1, "session": "claude-repo", "projectRoot": root, "projectName": "repo",
    "agent": "claude", "mux": "herdr", "state": "running",
    "workers": [worker(1, wt, "w1:p1", "claude"), worker(2, grok, "w2:p1", "grok"),
                worker(3, codex, "w3:p1", "codex")],
    "manager": {"herdrPane": None},
}
json.dump(data, open(path, "w"))
PY
rm -f "$T/watch-state.json"
OUT=$(CODEX_AUTH_RC=0 run_watch --dry-run --repo "$REPO")
assert_contains "only the exhausted pane is switched" "SWITCH worker worktree=$WT " "$OUT"
assert_not_contains "the grok pane stays on grok" "SWITCH worker worktree=$T/wt-grok" "$OUT"
assert_not_contains "the codex pane stays on codex" "SWITCH worker worktree=$T/wt-codex" "$OUT"
assert_contains "the exhausted claude pane moves to codex" "--agent codex" "$OUT"

# Codex with /goal: worker and manager resume through that goal, auto-approved.
printf '%s\n' "$CLAUDE_WEEKLY" > "$T/panes/w0_p1"
printf '%s\n' "$CLAUDE_WEEKLY" > "$T/panes/w1_p1"
python3 -c 'import json,sys; print(json.dumps({"result":{"agents":[
  {"agent":"claude","pane_id":"w0:p1","agent_status":"blocked"},
  {"agent":"claude","pane_id":"w1:p1","agent_status":"blocked"}]}}))' > "$T/agents.json"
python3 - "$REPO/.autocoder/swarm/claude-repo.json" "$REPO" "$WT" <<'PY'
import json, sys
path, root, wt = sys.argv[1:]
data = {
    "version": 1, "session": "claude-repo", "projectRoot": root, "projectName": "repo",
    "agent": "claude", "mux": "herdr", "state": "running",
    "workers": [{"number": 1, "worktree": wt, "state": "running", "agent": "claude",
                 "herdrPane": "w1:p1", "tmuxTarget": None, "cmuxWorkspace": None}],
    "manager": {"launchMode": "interactive", "agent": "claude", "herdrPane": "w0:p1",
                "tmuxTarget": None, "cmuxWorkspace": None, "pid": None},
}
json.dump(data, open(path, "w"))
PY
rm -f "$T/watch-state.json"
OUT=$(QUOTA_TEST_PATH="$T/goalsbin" CODEX_AUTH_RC=0 run_watch --dry-run --repo "$REPO")
assert_contains "codex worker launch is approval-never" "LAUNCH codex --ask-for-approval never" "$OUT"
assert_contains "codex worker restart carries the goal" "--agent codex --prompt '/goal" "$OUT"
assert_contains "codex manager resumes with its goal" "PROMPT /goal Monitor and coordinate workers" "$OUT"
assert_not_contains "codex manager is not given the claude resume command" "PROMPT /manager-resume" "$OUT"
assert_not_contains "codex failover does not open a pull request" "gh pr create" "$OUT"
assert_not_contains "codex failover does not choose Add funds" "Add funds" "$OUT"

# tmux restart finds the pane by cwd when the new agent's session does not exist.
: > "$T/tmux-argv"
export TMUX_ARGV="$T/tmux-argv" TMUX_WT="$WT" TMUX_PANE="$T/tmux-pane"
unset ISSUE_SOURCE ISSUE_DIR ISSUE_BACKEND
if PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" bash "$SCRIPTS/restart-worker.sh" \
     --worktree "$WT" --mux tmux --agent grok --prompt '/fix 419' >"$T/restart.out" 2>"$T/restart.err"; then
  ok "tmux restart does not require the new agent's session"
else
  bad "tmux restart does not require the new agent's session — $(cat "$T/restart.err" "$T/restart.out")"
fi
assert_contains "tmux restart respawns the cwd pane" "respawn-pane -k -t claude-repo:0.1" "$(cat "$T/tmux-argv")"
assert_not_contains "tmux restart error is not a missing session" "No tmux session" "$(cat "$T/restart.err" "$T/restart.out")"

# --ensure installs one cron line and keeps the others.
# PATH is this test's fakes plus the real PATH minus crontab, systemctl,
# loginctl, launchctl, uname and pgrep. A GitHub runner has a real crontab
# and a systemd user manager; leaving them on PATH makes "no crontab" and
# "no scheduler" cases install the host's cron instead of the fake.
SAFEBIN="$T/safebin"
mkdir -p "$SAFEBIN"
IFS=: read -ra _dirs <<< "$PATH"
for _d in "${_dirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    _n=${_f##*/}
    case "$_n" in crontab|systemctl|loginctl|launchctl|uname|pgrep) continue ;; esac
    [ -e "$SAFEBIN/$_n" ] && continue
    [ -x "$_f" ] && [ ! -d "$_f" ] && ln -s "$_f" "$SAFEBIN/$_n" 2>/dev/null
  done
done
SCHEDPATH="$T/bin:$SAFEBIN"
# GitHub Actions sets XDG_CONFIG_HOME outside $HOME. Units follow that
# variable, so the scratch home must own it or later cases see a leftover timer.
export XDG_CONFIG_HOME="$T/home/.config"
# A cron daemon is "running", so a systemd user manager is not chosen.
cat > "$T/bin/pgrep" <<'STUB'
#!/bin/bash
if [ "${1:-}" = -x ] && { [ "${2:-}" = cron ] || [ "${2:-}" = crond ]; }; then
  [ "${FAKE_CROND:-yes}" = yes ]; exit
fi
exit 1
STUB
chmod +x "$T/bin/pgrep"
export CRONTAB_FILE="$T/crontab"
echo "0 3 * * * existing-job" > "$CRONTAB_FILE"
OUT=$(FAKE_CROND=yes PATH="$SCHEDPATH" bash "$SCRIPT" --ensure --repo "$REPO")
assert_contains "ensure installs the entry" "installed cron entry" "$OUT"
OUT=$(FAKE_CROND=yes PATH="$SCHEDPATH" bash "$SCRIPT" --ensure --repo "$REPO")
assert_contains "ensure is idempotent" "already installed" "$OUT"
[ "$(grep -c 'autocoder-quota-failover:' "$CRONTAB_FILE")" = "1" ] \
  && ok "exactly one quota cron line" || bad "exactly one quota cron line — $(cat "$CRONTAB_FILE")"
assert_contains "existing cron jobs are preserved" "existing-job" "$(cat "$CRONTAB_FILE")"
assert_contains "cron line runs --once" "--once" "$(cat "$CRONTAB_FILE")"
if OUT=$(FAKE_CROND=yes PATH="$SCHEDPATH" timeout 3 bash "$SCRIPT" --loop --repo "$REPO" 2>&1); then
  bad "--loop with cron exits non-zero"
else
  ok "--loop with cron exits non-zero"
fi
assert_contains "--loop names the existing scheduler" "already scheduled via cron" "$OUT"

# No crontab: a systemd user timer, with the linger hint, and a second run does not also write cron.
mv "$T/bin/crontab" "$T/bin/crontab.off"
mkdir -p "$T/sysd"
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$SYSD/calls"
[ "${1:-}" = "--user" ] || exit 1
shift
[ "${SYSTEMCTL_DOWN:-0}" = 1 ] && exit 1
case "$1" in
  show-environment) echo "HOME=$HOME"; exit 0 ;;
  daemon-reload) exit 0 ;;
  enable) shift; [ "${1:-}" = "--now" ] && shift; echo "$1" >> "$SYSD/enabled"; exit 0 ;;
esac
exit 0
EOF
cat > "$T/bin/loginctl" <<'EOF'
#!/bin/bash
echo "Linger=${FAKE_LINGER:-no}"
EOF
chmod +x "$T/bin/systemctl" "$T/bin/loginctl"
OUT=$(SYSD="$T/sysd" FAKE_LINGER=no SYSTEMCTL_DOWN=0 PATH="$SCHEDPATH" bash "$SCRIPT" --ensure --repo "$REPO" 2>&1)
assert_contains "systemd ensure names the timer" "installed systemd user timer" "$OUT"
assert_contains "systemd ensure notes linger" "loginctl enable-linger" "$OUT"
UNIT=$(find "$XDG_CONFIG_HOME/systemd/user" -name 'autocoder-quota-failover-*.timer' 2>/dev/null | head -1)
[ -n "$UNIT" ] && ok "systemd timer file written" || bad "systemd timer file written"
grep -q 'OnUnitInactiveSec=120s' "$UNIT" && ok "quota timer is every 2 minutes" || bad "timer interval: $(cat "$UNIT" 2>/dev/null)"
OUT=$(SYSD="$T/sysd" PATH="$SCHEDPATH" bash "$SCRIPT" --ensure --repo "$REPO" 2>&1)
assert_contains "systemd re-run is idempotent" "systemd entry already installed" "$OUT"
mv "$T/bin/crontab.off" "$T/bin/crontab"
[ "$(grep -c 'autocoder-quota-failover:' "$CRONTAB_FILE")" = "1" ] \
  && ok "systemd ensure did not add a second cron line" || bad "systemd ensure wrote cron: $(cat "$CRONTAB_FILE")"

# macOS: launchd, even if crontab is present.
REAL_UNAME=$(command -v uname)
cat > "$T/bin/uname" <<EOF
#!/bin/bash
if [ "\${1:-}" = -s ] && [ -n "\${FAKE_UNAME:-}" ]; then echo "\$FAKE_UNAME"; exit 0; fi
exec "$REAL_UNAME" "\$@"
EOF
cat > "$T/bin/launchctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$SYSD/launchctl"
exit 0
EOF
chmod +x "$T/bin/uname" "$T/bin/launchctl"
: > "$CRONTAB_FILE"
echo "0 3 * * * existing-job" > "$CRONTAB_FILE"
rm -rf "$XDG_CONFIG_HOME/systemd" "$HOME/Library"
OUT=$(FAKE_UNAME=Darwin FAKE_CROND=yes SYSD="$T/sysd" PATH="$SCHEDPATH" bash "$SCRIPT" --ensure --repo "$REPO" 2>&1)
assert_contains "launchd ensure names the agent" "installed launchd agent" "$OUT"
PLIST=$(find "$HOME/Library/LaunchAgents" -name 'com.autocoder.quota-failover.*.plist' 2>/dev/null | head -1)
[ -n "$PLIST" ] && ok "LaunchAgent plist written" || bad "LaunchAgent plist written"
grep -q '<integer>120</integer>' "$PLIST" && ok "launchd interval is 120s" || bad "plist interval"
grep -q 'autocoder-quota-failover:' "$CRONTAB_FILE" \
  && bad "launchd ensure also wrote cron" || ok "launchd ensure leaves crontab alone"

# Nothing available.
rm -f "$T/bin/crontab" "$T/bin/launchctl"
rm -rf "$HOME/Library" "$XDG_CONFIG_HOME/systemd"
OUT=$(FAKE_UNAME= SYSTEMCTL_DOWN=1 SYSD="$T/sysd" PATH="$SCHEDPATH" bash "$SCRIPT" --ensure --repo "$REPO" 2>&1); RC=$?
[ "$RC" -ne 0 ] && ok "no scheduler exits non-zero" || bad "no scheduler exits non-zero — rc $RC: $OUT"
assert_contains "no scheduler names --loop" "--loop" "$OUT"
assert_contains "no scheduler says none was found" "No scheduler available" "$OUT"

if bash "$SCRIPT" --bogus >/dev/null 2>&1; then bad "unknown flag exits non-zero"; else ok "unknown flag exits non-zero"; fi
if bash "$SCRIPT" >/dev/null 2>&1; then bad "no mode exits non-zero"; else ok "no mode exits non-zero"; fi

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
