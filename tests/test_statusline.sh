#!/bin/bash
# tests/test_statusline.sh — pin the swarm status line and its installer.
#
# The status line is the manager's only cheap read on worker context pressure
# (capture-pane shows it on every worker pane), so two failure modes matter more
# than the pretty formatting:
#
#   1. A segment that renders a WRONG number instead of staying silent. The
#      session JSON legitimately omits context_window before the first API call
#      and after /compact, and omits rate_limits entirely on Vertex and raw API
#      keys. `// 0` on either of those reports a healthy 0% for a worker that is
#      actually at 95%, which is worse than showing nothing.
#   2. An installer that clobbers settings.json. It holds model, env and
#      enabledPlugins; rewriting the file to set one key has to preserve the rest
#      and must not touch a status line the user configured themselves.
#
# Runs against real temp HOMEs, not mocks. Skips cleanly when jq is absent.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SL="$ROOT/plugins/autocoder/scripts/statusline.sh"
INST="$ROOT/plugins/autocoder/scripts/install-statusline.sh"

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — want '$want', got '$got'"; FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" hay="$3"
  case "$hay" in
    *"$needle"*) echo "PASS: $label"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL: $label — '$needle' not in: $hay"; FAIL=$((FAIL + 1)) ;;
  esac
}

assert_not_contains() {
  local label="$1" needle="$2" hay="$3"
  case "$hay" in
    *"$needle"*) echo "FAIL: $label — '$needle' unexpectedly in: $hay"; FAIL=$((FAIL + 1)) ;;
    *) echo "PASS: $label"; PASS=$((PASS + 1)) ;;
  esac
}

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  echo "0 passed / 0 failed / 0 total"
  exit 0
fi

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── A real git worktree, so the worktree/branch segments exercise the same
#    detection path a worker does rather than a stubbed one.
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main 2>/dev/null
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo x > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm init
WT="$TMP/repo-wt-3"
git -C "$REPO" worktree add -q -b feature/issue-264 "$WT" 2>/dev/null

# ── Test 1: the headline format the swarm reads.
OUT=$(printf '%s' "{
  \"model\":{\"display_name\":\"Sonnet 5\"},
  \"workspace\":{\"current_dir\":\"$WT\"},
  \"context_window\":{\"used_percentage\":47,\"context_window_size\":1000000}
}" | bash "$SL")
assert_contains "context renders with 1M window" "ctx 47% of 1M" "$OUT"
assert_contains "model renders" "Sonnet 5" "$OUT"
assert_contains "repo name renders in a worktree" "repo repo" "$OUT"
assert_contains "worktree name renders" "wt repo-wt-3" "$OUT"
assert_contains "branch renders" "branch feature/issue-264" "$OUT"

# ── Test 2: a 200k window must NOT claim to be 1M.
OUT=$(printf '%s' '{"context_window":{"used_percentage":8,"context_window_size":200000}}' | bash "$SL")
assert_contains "200k window renders bare percent" "ctx 8%" "$OUT"
assert_not_contains "200k window does not claim 1M" "1M" "$OUT"

# ── Test 3: THE regression that matters. No context_window in the payload
#    (pre-first-call, post-/compact) must render nothing — never 0%.
OUT=$(printf '%s' '{"model":{"display_name":"Opus"}}' | bash "$SL")
assert_eq "absent context renders no ctx segment at all" "Opus" "$OUT"
assert_not_contains "absent context never renders 0%" "ctx 0%" "$OUT"

# ── Test 4: absent rate_limits (Vertex / raw API key) must stay silent too.
OUT=$(printf '%s' '{"model":{"display_name":"Opus"}}' | bash "$SL")
assert_not_contains "absent quota renders no 5h" "5h" "$OUT"
assert_not_contains "absent quota renders no 7d" "7d" "$OUT"
OUT=$(printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":23.5},"seven_day":{"used_percentage":41.2}}}' | bash "$SL")
assert_contains "present quota renders 5h" "5h 24%" "$OUT"
assert_contains "present quota renders 7d" "7d 41%" "$OUT"

# ── Test 5: empty payload produces empty output and exit 0, not a stray
#    separator or a jq error on the pane.
OUT=$(printf '%s' '{}' | bash "$SL" 2>&1); RC=$?
assert_eq "empty payload exits 0" "0" "$RC"
assert_eq "empty payload prints nothing" "" "$OUT"

# ── Test 6: a plain (non-worktree) checkout reports branch but no wt, since
#    "wt repo" for the main checkout would be noise on the manager's pane.
OUT=$(printf '%s' "{\"workspace\":{\"current_dir\":\"$REPO\"}}" | bash "$SL")
assert_contains "main checkout still shows branch" "branch main" "$OUT"
assert_not_contains "main checkout shows no wt segment" "wt " "$OUT"
# The repo segment is the half that must survive here: with no wt to name it,
# it is the only thing identifying which project the pane belongs to.
assert_contains "main checkout still shows repo" "repo repo" "$OUT"

# ── Test 6b: outside a git repo the repo segment stays silent rather than
#    naming whatever directory happens to be the parent.
OUT=$(printf '%s' "{\"model\":{\"display_name\":\"Opus\"},\"workspace\":{\"current_dir\":\"$TMP\"}}" | bash "$SL")
assert_eq "non-repo cwd renders no repo segment" "Opus" "$OUT"

# ── Test 7: installer writes settings.json and preserves every other key.
H="$TMP/home1"; mkdir -p "$H/.claude"
cat > "$H/.claude/settings.json" <<'JSON'
{"model":"claude-opus-5","env":{"FOO":"bar"},"enabledPlugins":{"autocoder@local":true}}
JSON
OUT=$(HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" bash "$INST" 2>&1); RC=$?
assert_eq "installer succeeds on existing settings" "0" "$RC"
assert_eq "statusLine command is set" "$H/.claude/autocoder-statusline.sh" \
  "$(HOME="$H" jq -r '.statusLine.command' "$H/.claude/settings.json" | sed "s|^~|$H|")"
assert_eq "statusLine type is command" "command" "$(jq -r '.statusLine.type' "$H/.claude/settings.json")"
assert_eq "model key preserved" "claude-opus-5" "$(jq -r '.model' "$H/.claude/settings.json")"
assert_eq "env key preserved" "bar" "$(jq -r '.env.FOO' "$H/.claude/settings.json")"
assert_eq "enabledPlugins preserved" "true" "$(jq -r '.enabledPlugins["autocoder@local"]' "$H/.claude/settings.json")"
assert_eq "renderer copied and executable" "yes" \
  "$([ -x "$H/.claude/autocoder-statusline.sh" ] && echo yes || echo no)"

# ── Test 8: rerunning is idempotent — no duplicate keys, no churn.
BEFORE=$(cat "$H/.claude/settings.json")
HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" bash "$INST" --quiet >/dev/null 2>&1
assert_eq "second run leaves settings byte-identical" "$BEFORE" "$(cat "$H/.claude/settings.json")"

# ── Test 9: a foreign status line is LEFT ALONE. Stomping a status line the
#    user wrote themselves is the one thing this installer must never do.
H2="$TMP/home2"; mkdir -p "$H2/.claude"
cat > "$H2/.claude/settings.json" <<'JSON'
{"statusLine":{"type":"command","command":"~/.claude/my-own-thing.sh"}}
JSON
OUT=$(HOME="$H2" CLAUDE_CONFIG_DIR="$H2/.claude" bash "$INST" 2>&1)
assert_eq "foreign statusLine untouched" "~/.claude/my-own-thing.sh" \
  "$(jq -r '.statusLine.command' "$H2/.claude/settings.json")"
assert_contains "skip is explained, not silent" "existing status line" "$OUT"

# ── Test 10: --force does take it over, for the operator who asks.
HOME="$H2" CLAUDE_CONFIG_DIR="$H2/.claude" bash "$INST" --force --quiet >/dev/null 2>&1
assert_contains "--force takes over" "autocoder-statusline.sh" \
  "$(jq -r '.statusLine.command' "$H2/.claude/settings.json")"

# ── Test 11: no settings.json at all (fresh box) — must create, not crash.
H3="$TMP/home3"
OUT=$(HOME="$H3" CLAUDE_CONFIG_DIR="$H3/.claude" bash "$INST" 2>&1); RC=$?
assert_eq "fresh home succeeds" "0" "$RC"
assert_contains "fresh home gets a statusLine" "autocoder-statusline.sh" \
  "$(jq -r '.statusLine.command' "$H3/.claude/settings.json" 2>/dev/null)"

# ── Test 12: malformed settings.json must be REFUSED, not overwritten. A
#    truncated file is recoverable; a file we replaced is not.
H4="$TMP/home4"; mkdir -p "$H4/.claude"
printf '{"model": "opus"' > "$H4/.claude/settings.json"   # truncated on purpose
BEFORE=$(cat "$H4/.claude/settings.json")
OUT=$(HOME="$H4" CLAUDE_CONFIG_DIR="$H4/.claude" bash "$INST" 2>&1); RC=$?
assert_eq "malformed settings is an error" "1" "$RC"
assert_eq "malformed settings left untouched" "$BEFORE" "$(cat "$H4/.claude/settings.json")"

# ── Test 13: the launch scripts actually call it. A perfect installer nobody
#    invokes is the failure this whole feature is one step away from.
assert_eq "worker-launch-lib defines ensure_statusline" "yes" \
  "$(grep -q '^ensure_statusline()' "$ROOT/plugins/autocoder/scripts/worker-launch-lib.sh" && echo yes || echo no)"
for s in start-parallel-agents.sh add-worker.sh restart-worker.sh; do
  assert_eq "$s calls ensure_statusline" "yes" \
    "$(grep -q '^ensure_statusline' "$ROOT/plugins/autocoder/scripts/$s" && echo yes || echo no)"
done

# ── Test 14: the installer resolves its renderer from the lib dir, not from a
#    repo_root walk. That walk is what broke worker relaunch in issue #94, and
#    it breaks identically here under an installed (version-scoped) plugin.
assert_eq "ensure_statusline resolves via WORKER_LAUNCH_LIB_DIR" "yes" \
  "$(grep -A6 '^ensure_statusline()' "$ROOT/plugins/autocoder/scripts/worker-launch-lib.sh" \
     | grep -q 'WORKER_LAUNCH_LIB_DIR' && echo yes || echo no)"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
