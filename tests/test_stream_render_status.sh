#!/bin/bash
# tests/test_stream_render_status.sh — stream-render.sh renders a worker's status
# line from the stream-json it already reads (#132).
#
# Headless `claude -p` has no TUI, so the statusline.sh hook never runs, and a
# worker pane showed no `ctx NN%` for monitor-workers' `grep -oE 'ctx [0-9]+%'`.
# The line must use the same wording, appear only when the whole-point percentage
# moves, and leave the existing event rendering unchanged.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/plugins/autocoder/scripts/stream-render.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git init -q -b master "$TMP/repo"
git -C "$TMP/repo" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m base
git -C "$TMP/repo" worktree add -q -b feature/issue-7 "$TMP/repo-wt-1" 2>/dev/null
WT="$TMP/repo-wt-1"

init()  { printf '{"type":"system","subtype":"init","session_id":"abcdef123456","model":"%s","cwd":"%s"}\n' "$1" "$2"; }
asst()  { # asst <cache_read_tokens> [model]
  printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":%s},"content":[{"type":"text","text":"step"}]}}\n' "${2:-claude-sonnet-5-5}" "$1"
}
status() { grep '^── ' ; }

# ── 1. 200k model: line appears, same wording the manager greps for ─────────
OUT=$( { init claude-sonnet-5-5 "$WT"; asst 49000; } | bash "$R")
eq "status line rendered" "── ctx 25% | Sonnet 5.5 | wt repo-wt-1 | branch feature/issue-7" "$(printf '%s\n' "$OUT" | status)"
eq "the manager's grep reads it" "ctx 25%" "$(printf '%s\n' "$OUT" | grep -oE 'ctx [0-9]+%' | tail -1)"
printf '%s\n' "$OUT" | grep -q '› step' && ok "assistant text still rendered" || bad "assistant text lost"
printf '%s\n' "$OUT" | grep -q '▸ session abcdef12' && ok "init line still rendered" || bad "init line lost"

# ── 2. Throttled: one line per whole-point move ─────────────────────────────
OUT=$( { init claude-sonnet-5-5 "$WT"; asst 49000; asst 49100; asst 49200; asst 51000; } | bash "$R")
eq "two lines for 25%,25%,25%,26%" "2" "$(printf '%s\n' "$OUT" | status | wc -l | tr -d ' ')"
eq "latest reading is 26%" "ctx 26%" "$(printf '%s\n' "$OUT" | grep -oE 'ctx [0-9]+%' | tail -1)"

# ── 3. A drop (after compaction) is shown too ───────────────────────────────
OUT=$( { init claude-sonnet-5-5 "$WT"; asst 150000; asst 9000; } | bash "$R")
eq "drop after compaction is shown" "ctx 5%" "$(printf '%s\n' "$OUT" | grep -oE 'ctx [0-9]+%' | tail -1)"

# ── 4. Window: [1m] model, and the env override ─────────────────────────────
OUT=$( { init 'claude-opus-5-5[1m]' "$WT"; asst 259000 'claude-opus-5-5[1m]'; } | bash "$R")
eq "[1m] model reads of 1M" "── ctx 26% of 1M | Opus 5.5 | wt repo-wt-1 | branch feature/issue-7" "$(printf '%s\n' "$OUT" | status)"
OUT=$( { init claude-sonnet-5-5 "$WT"; asst 499000; } | AUTOCODER_CTX_WINDOW=1000000 bash "$R")
eq "AUTOCODER_CTX_WINDOW overrides" "ctx 50%" "$(printf '%s\n' "$OUT" | grep -oE 'ctx [0-9]+%' | tail -1)"

# ── 5. Branch is read live, so it follows the worker ────────────────────────
git -C "$WT" checkout -q -b feature/issue-8
OUT=$( { init claude-sonnet-5-5 "$WT"; asst 49000; } | bash "$R")
printf '%s\n' "$OUT" | status | grep -q 'branch feature/issue-8$' && ok "branch read live" || bad "branch stale: $(printf '%s\n' "$OUT" | status)"

# ── 6. Degrades: no init, no usage, non-JSON lines ──────────────────────────
OUT=$( { asst 49000; echo 'plain crash text'; echo '{"type":"assistant","message":{"content":[{"type":"text","text":"no usage"}]}}'; } | bash "$R")
eq "no init: ctx and model still shown" "── ctx 25% | Sonnet 5.5" "$(printf '%s\n' "$OUT" | status)"
printf '%s\n' "$OUT" | grep -qx 'plain crash text' && ok "non-JSON passes through" || bad "non-JSON lost"
printf '%s\n' "$OUT" | grep -q 'no usage' && ok "usage-less event still rendered" || bad "usage-less event lost"
eq "usage-less event adds no status line" "1" "$(printf '%s\n' "$OUT" | status | wc -l | tr -d ' ')"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
