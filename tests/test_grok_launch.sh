#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# Grok is a launcher agent: bare slash commands, `grok --trust` for folder
# trust, and no auto-answer of tool-permission prompts.
set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
BASH_BIN=$(command -v bash)
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/tmux"
chmod +x "$TMP/bin/tmux"
# herdr stub records its argv. stdout is discarded by start_herdr_agent.
cat > "$TMP/bin/herdr" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${HERDR_ARGV_CAPTURE:?}"
exit 0
EOF
chmod +x "$TMP/bin/herdr"

# ── launch resolution ────────────────────────────────────────────────────────
RESOLVE=$(bash -c 'source "$1"; resolve_worker_launch grok "$2" herdr >/dev/null; printf "%s|%s|%s|%s|%s|%s" "$AGENT_LAUNCH_CMD" "$WORKER_CMD" "$MANAGER_LAUNCH_CMD" "$MANAGER_CMD" "$WORKER_COMMAND_MODE" "$MANAGER_COMMAND_MODE"' _ "$SCRIPTS/worker-launch-lib.sh" "$ROOT")
case "$RESOLVE" in
  "grok --trust --always-approve|/fix-loop|grok --trust --always-approve|/monitor-loop|agent-input|agent-input")
    ok "resolve_worker_launch grok: --trust, --always-approve, bare slash commands" ;;
  *) bad "resolve_worker_launch grok: $RESOLVE" ;;
esac
case "$RESOLVE" in
  *--yolo*|*dangerously-skip-permissions*|*bypassPermissions*)
    bad "grok launch uses a flag other than --always-approve" ;;
  *--always-approve*)
    ok "grok launch auto-approves with --always-approve" ;;
  *) bad "grok launch is missing --always-approve: $RESOLVE" ;;
esac

# ── herdr registers --kind grok and forwards --trust ─────────────────────────
CAPTURE="$TMP/herdr-argv"
: > "$CAPTURE"
HERDR_ARGV_CAPTURE="$CAPTURE" PATH="$TMP/bin:$PATH" "$BASH_BIN" -c \
  'source "$1"; source "$2"; launch_herdr_agent wt1-proj grok w1:p1 "grok --trust --always-approve" >/dev/null' \
  _ "$SCRIPTS/mux-send-lib.sh" "$SCRIPTS/worker-launch-lib.sh"
got=$(cat "$CAPTURE")
case "$got" in
  *"agent start wt1-proj --kind grok --pane w1:p1 -- --trust --always-approve"*)
    ok "herdr agent start --kind grok forwards --trust and --always-approve" ;;
  *) bad "herdr registration was: $got" ;;
esac

# ── help and validation ──────────────────────────────────────────────────────
HELP=$(bash "$SCRIPTS/start-parallel-agents.sh" --help)
grep -Fq -- "--agent claude|gemini|codex|droid|pi|grok" <<<"$HELP" \
  && ok "start-parallel help lists grok" || bad "start-parallel help omits grok"
grep -Fq -- "--agent grok" <<<"$HELP" \
  && ok "start-parallel help shows a grok example" || bad "start-parallel help has no grok example"

for pair in \
  "add-worker.sh|--agent claude|gemini|codex|droid|grok" \
  "restart-worker.sh|--agent claude|gemini|codex|droid|grok" \
  "remove-worker.sh|--agent claude|gemini|codex|droid|grok" \
  "start-workers.sh|--agent claude|gemini|codex|droid|grok"
do
  f="${pair%%|*}"
  needle="${pair#*|}"
  h=$(bash "$SCRIPTS/$f" --help 2>&1 || true)
  grep -Fq -- "$needle" <<<"$h" && ok "$f help lists grok" || bad "$f help omits grok ($h)"
done

# PATH is only the stub dir, so a grok installed elsewhere cannot answer.
UNK=$(PATH="$TMP/bin:/usr/bin:/bin" "$BASH_BIN" "$SCRIPTS/start-parallel-agents.sh" --mux tmux --agent nope 2>&1) || true
grep -Fq "Unknown agent framework 'nope'" <<<"$UNK" \
  && ok "unknown agent is still rejected" || bad "unknown agent message: $UNK"
grep -Fq "grok" <<<"$UNK" \
  && ok "unknown-agent message names grok" || bad "unknown-agent message omits grok: $UNK"

MISS=$(PATH="$TMP/bin:/usr/bin:/bin" "$BASH_BIN" "$SCRIPTS/start-parallel-agents.sh" --mux tmux --agent grok 2>&1) || true
grep -Fq "grok command is not installed" <<<"$MISS" \
  && ok "missing grok binary is reported as not installed" || bad "missing grok: $MISS"
grep -Fq "Unknown agent" <<<"$MISS" \
  && bad "missing grok was treated as an unknown agent" \
  || ok "missing grok is not an unknown agent"

AHELP=$(bash "$ROOT/.agent/scripts/start-parallel-agents.sh" --help)
grep -Fq -- "--agent claude|gemini|codex|droid|grok" <<<"$AHELP" \
  && ok "antigravity launcher help lists grok" || bad "antigravity help omits grok"
AMISS=$(PATH="$TMP/bin:/usr/bin:/bin" "$BASH_BIN" "$ROOT/.agent/scripts/start-parallel-agents.sh" --mux tmux --agent grok 2>&1) || true
grep -Fq "grok command is not installed" <<<"$AMISS" \
  && ok "antigravity launcher accepts --agent grok" || bad "antigravity --agent grok: $AMISS"

# ── ctl accepts grok (the allow-list, not a Claude plugin install) ───────────
# The stub tmux is first on PATH, and /usr/bin:/bin supply dirname and git.
# grok is not on this PATH (this environment has none; a copy under $TMP/bin
# is not installed), so start-parallel exits before opening a session.
REPO="$TMP/repo"
git init -q "$REPO"
CTL_OUT=$(PATH="$TMP/bin:/usr/bin:/bin" "$BASH_BIN" "$SCRIPTS/autocoder-ctl.sh" start "$REPO" --agent grok --no-plugin-install --mux tmux 2>"$TMP/ctl.err" || true)
if python3 - "$CTL_OUT" << 'PY'
import json, sys
raw = [ln for ln in sys.argv[1].splitlines() if ln.startswith("{")]
if not raw:
    sys.exit(1)
detail = json.loads(raw[-1]).get("detail")
text = detail if isinstance(detail, str) else json.dumps(detail)
sys.exit(0 if "unknown agent" not in text else 1)
PY
then ok "ctl accepts --agent grok"
else bad "ctl rejected grok: $CTL_OUT"
fi

# ── docs name folder trust, tool auto-approve, and the credit refusal ───────
for f in "$ROOT/docs/GROK.md" "$ROOT/plugins/autocoder/README.md" "$ROOT/plugins/autocoder/CHANGELOG.md"; do
  grep -Fq -- "--trust" "$f" && grep -Fq -- "--always-approve" "$f" && grep -Fq -- "Add funds" "$f" \
    && ok "$(basename "$f") documents --trust, --always-approve, and not buying credits" \
    || bad "$f does not document trust, always-approve, and the credit refusal"
done

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
