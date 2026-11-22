#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_review_blocked_gui.sh — the /review-blocked-gui command (#314, part of #308).
#
# The Claude and Antigravity copies match apart from the SCRIPT_DIR resolver. The
# command's Instructions block, run in a private temp repo on the file backend,
# starts review-blocked-server.py, prints a working tokenised URL, names the issues
# that lack an analysis, reuses a running server, and stops it with --stop. The
# page ships next to the server in every package, and the command is registered in
# the help, the docs and the CHANGELOG.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
CMD="$ROOT/plugins/autocoder/commands/review-blocked-gui.md"
AG="$ROOT/.agent/workflows/review-blocked-gui.md"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
has() { if printf '%s' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1 — no /$3/ in: $(printf '%s' "$2" | head -c 400)"; fi; }

for f in "$CMD" "$AG"; do [ -f "$f" ] || { bad "missing $f"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }; done

# ── Parity: the two copies differ only in the resolver lines ────────────────
_body() { grep -vE 'then echo "\$d"|plugins/cache' "$1"; }
[ "$(_body "$CMD")" = "$(_body "$AG")" ] && ok "the Claude and Antigravity copies match (resolver aside)" \
  || bad "review-blocked-gui.md differs between plugins/ and .agent/: $(diff <(_body "$CMD") <(_body "$AG") | head -5)"

# ── Registration ─────────────────────────────────────────────────────────────
for f in plugins/autocoder/commands/autocoder-help.md .agent/workflows/autocoder-help.md \
         plugins/autocoder/README.md docs/maintaining.md; do
  grep -q '/review-blocked-gui' "$ROOT/$f" && ok "$f lists /review-blocked-gui" || bad "$f does not list /review-blocked-gui"
done
UNRELEASED=$(sed -n '/^## \[Unreleased\]/,/^## \[[0-9]/p' "$ROOT/plugins/autocoder/CHANGELOG.md" 2>/dev/null)
has "the CHANGELOG notes the command under [Unreleased]" "$UNRELEASED" '/review-blocked-gui'

# ── Packaging: the page ships wherever the server does ──────────────────────
for d in plugins/autocoder/scripts .agent/scripts .pi/scripts codex-plugins/autocoder/scripts \
         .factory-plugin/plugins/autocoder/scripts skills/autocoder/scripts; do
  [ -f "$ROOT/$d/review-blocked-server.py" ] || continue
  if cmp -s "$SCRIPTS/review-blocked-ui.html" "$ROOT/$d/review-blocked-ui.html"; then
    ok "$d ships the review page beside the server"
  else
    bad "$d ships review-blocked-server.py without a current review-blocked-ui.html"
  fi
done
[ -f "$ROOT/.agent/scripts/review-blocked-server.py" ] && ok ".agent/scripts carries the server the Antigravity command runs" \
  || bad ".agent/scripts has no review-blocked-server.py"

# ── The Instructions block, end to end ─────────────────────────────────────
TMP=$(mktemp -d)
BLOCK="$TMP/block.sh"
awk '/^## Instructions/ {on=1; next} on && /^```bash$/ {grab=1; next} grab && /^```$/ {exit} grab {print}' "$CMD" > "$BLOCK"
[ -s "$BLOCK" ] && ok "the command has an Instructions bash block" || bad "no Instructions bash block in $CMD"

cleanup() {
  local pidf="$TMP/repo/.git/autocoder-review-blocked-server.pid"
  [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null
  rm -rf "$TMP" 2>/dev/null || { sleep 1; rm -rf "$TMP"; }
}
trap cleanup EXIT
unset ISSUE_SOURCE ISSUE_BACKEND ISSUE_DIR AUTOCODER_BLOCKED_CACHE_DIR
export AUTOCODER_ISSUE_EVENTS="$TMP/issue-events.jsonl"

git init -q "$TMP/repo"; cd "$TMP/repo" || exit 1
git config user.email t@example.com; git config user.name T
printf '{"issueSource": "file"}\n' > .autocoder.json
mkdir -p plugins/autocoder; ln -s "$SCRIPTS" plugins/autocoder/scripts
echo a > a; git add a .autocoder.json; git commit -qm base

IF() { ( source "$SCRIPTS/issue-fns.sh" >/dev/null 2>&1; "$@" ); }
N=$(IF issue_create --title "Pick a storage backend" --body "two options" | jq -r .number)
IF issue_update "$N" --add-label needs-design >/dev/null 2>&1

run() { bash "$BLOCK" "$@" 2>&1; }
PID_FILE="$TMP/repo/.git/autocoder-review-blocked-server.pid"
LOG_FILE="$TMP/repo/.git/autocoder-review-blocked-server.log"

OUT=$(run)
has "the command starts the server" "$OUT" 'Started the review server'
URL=$(printf '%s\n' "$OUT" | sed -n 's/^🔗 Open: //p' | head -1)
has "it prints a tokenised 127.0.0.1 URL" "$URL" '^http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+$'
has "it counts the issue with no analysis" "$OUT" '1 blocked issue\(s\); 1 without an analysis'
has "it suggests /review-blocked --prepare for that issue" "$OUT" 'Run /review-blocked --prepare first'
printf '%s' "$OUT" | grep -q "for #$N\." && ok "the suggestion names #$N" || bad "the suggestion does not name #$N: $OUT"

BASE=${URL%%/\?*}; TOKEN=${URL##*token=}
PAGE=$(curl -s "$URL")
printf '%s' "$PAGE" | grep -q 'Content-Security-Policy' && ok "the URL serves the review page" \
  || bad "the URL does not serve review-blocked-ui.html: $(printf '%s' "$PAGE" | head -c 200)"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/issues")" = 403 ] && ok "the API refuses a request without the token" \
  || bad "the API answered without the token"
[ "$(curl -s -H "X-Review-Token: $TOKEN" "$BASE/api/issues" | jq '.issues | length')" = 1 ] \
  && ok "the token in the printed URL works" || bad "the printed token does not open the API"

MODE=$(stat -c '%a' "$LOG_FILE" 2>/dev/null || stat -f '%Lp' "$LOG_FILE")
[ "$MODE" = 600 ] && ok "the log holding the token is owner-only" || bad "the log is mode $MODE, want 600"

PID1=$(cat "$PID_FILE")
OUT2=$(run)
has "a second run reuses the running server" "$OUT2" 'already running'
[ "$(cat "$PID_FILE")" = "$PID1" ] && ok "it starts no second server" || bad "the pid changed: $PID1 -> $(cat "$PID_FILE")"
[ "$(printf '%s\n' "$OUT2" | sed -n 's/^🔗 Open: //p')" = "$URL" ] && ok "it prints the same URL" || bad "the second run printed another URL"

OUT3=$(run --stop)
has "--stop stops the server" "$OUT3" 'Stopped the review server'
for _ in $(seq 1 50); do kill -0 "$PID1" 2>/dev/null || break; sleep 0.1; done
kill -0 "$PID1" 2>/dev/null && bad "the server is still running after --stop" || ok "the server process is gone"
[ ! -e "$PID_FILE" ] && [ ! -e "$LOG_FILE" ] && ok "--stop removes the pid file and the log" || bad "--stop left the pid file or log behind"
has "--stop with nothing running says so" "$(run --stop)" 'No review server is running'

# A stale pid file naming some other live process is not mistaken for the server.
sleep 30 & OTHER=$!
echo "$OTHER" > "$PID_FILE"
OUT4=$(run)
has "a pid file naming another process does not count as a running server" "$OUT4" 'Started the review server'
kill -0 "$OTHER" 2>/dev/null && ok "that other process is left alone" || bad "the command killed an unrelated process"
kill "$OTHER" 2>/dev/null
run --stop >/dev/null

# A server that cannot start is reported, not hidden.
python3 -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); print(s.getsockname()[1], flush=True); time.sleep(30)' > "$TMP/port" &
HOLDER=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
BUSY=$(cat "$TMP/port")
OUT5=$(run --port "$BUSY"); RC=$?
[ "$RC" -ne 0 ] && ok "a port in use fails the command (rc $RC)" || bad "a port in use exited 0"
has "and says why" "$OUT5" 'did not start.*|cannot listen'
kill "$HOLDER" 2>/dev/null

run --bogus >/dev/null; [ $? -eq 2 ] && ok "an unknown argument exits 2" || bad "an unknown argument did not exit 2"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
