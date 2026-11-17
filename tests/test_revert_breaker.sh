#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_revert_breaker.sh — the revert circuit breaker (#252).
# A private temp repo with the file backend and a stub `gh`; nothing reaches a real tracker.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/plugins/autocoder/scripts"
BREAKER="$SCRIPTS/revert-breaker.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 — '$2' not in: $3"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset ISSUE_SOURCE ISSUE_BACKEND ISSUE_DIR_PATH
export AUTOCODER_TMP="$TMP/private"; mkdir -p -m 700 "$AUTOCODER_TMP"

# Stub gh: logs every call; `pr view` finds no PR; `pr create` prints a URL, or fails when
# GH_FAIL is set.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view")   exit 1 ;;
  "pr create") [ -n "${GH_FAIL:-}" ] && { echo "boom" >&2; exit 1; }; echo "https://example.invalid/pull/7" ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log"
: > "$GH_LOG"

git init -q --bare -b master "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
REPO="$TMP/repo"
cd "$REPO" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false
mkdir -p .issues
config() { printf '{"issueSource": "file"%s}\n' "${1:+, \"revertBreaker\": $1}" > .autocoder.json; }
config
echo '.autocoder.json' > .git/info/exclude; echo '.issues/' >> .git/info/exclude

N=0
commit() {  # commit <message paragraphs...>
  N=$((N + 1)); echo "$N" > f; git add f
  local args=(); for p in "$@"; do args+=(-m "$p"); done
  git commit -q "${args[@]}"
}
revert_of() { commit "Revert autocoder push abc$1 (issue #$1)" "Autocoder-Reverts: abc$1
Autocoder-Reverts-Issue: $1"; }

# Ten landed issues, one sentinel revert: 10% — below the default 15%.
for i in 1 2 3 4 5 6 7 8 9 10; do commit "#$i: change $i"; done
revert_of 4
git push -q origin master

# shellcheck source=/dev/null
source "$SCRIPTS/issue-fns.sh"
breakers() { issue_list --state all --label revert-breaker | jq -c '[.[] | select(.state == "OPEN") | .number]'; }

# ── below threshold ──────────────────────────────────────────────────────────
OUT=$(bash "$BREAKER" --ref origin/master); RC=$?
eq  "below threshold: exit 0" 0 "$RC"
has "below threshold: says it holds" "Revert breaker holds" "$OUT"
eq  "below threshold: no breaker issue" "[]" "$(breakers)"
bash "$BREAKER" --active >/dev/null; eq "below threshold: --active says closed" 1 "$?"

# Two reverts of ten = 20%, but minReverts 3 holds it.
revert_of 7; git push -q origin master
config '{"minReverts": 3}'
bash "$BREAKER" --ref origin/master >/dev/null
eq "minReverts holds the breaker" "[]" "$(breakers)"

# ── off ──────────────────────────────────────────────────────────────────────
config '"off"'
OUT=$(bash "$BREAKER" --ref origin/master); RC=$?
eq  "off: exit 0" 0 "$RC"
has "off: says so" "off" "$OUT"
eq  "off: no breaker issue" "[]" "$(breakers)"

# ── trips ────────────────────────────────────────────────────────────────────
config
OUT=$(bash "$BREAKER" --ref origin/master); RC=$?
eq  "trip: exit 0" 0 "$RC"
has "trip: announces it" "Revert breaker tripped" "$OUT"
OPEN=$(breakers)
eq  "trip: exactly one breaker issue" 1 "$(jq length <<<"$OPEN")"
B=$(jq -r '.[0]' <<<"$OPEN")
J=$(issue_get "$B")
eq  "trip: labels" '["needs-approval","revert-breaker"]' "$(jq -c '[.labels[].name] | sort' <<<"$J")"
BODY=$(jq -r .body <<<"$J")
has "trip: body names the window" "newest 20 landed issues on \`origin/master\` (10 found)" "$BODY"
has "trip: body names the rate"   "**Reverts**: 2 (20.0%)" "$BODY"
has "trip: body names the issues" "#4, #7" "$BODY"
has "trip: body says how to restore" "Close this issue" "$BODY"

OUT=$(bash "$BREAKER" --ref origin/master); RC=$?
eq  "second trip: exit 0" 0 "$RC"
has "second trip: points at the open one" "already open as #${B}" "$OUT"
eq  "second trip: still exactly one" 1 "$(jq length <<<"$(breakers)")"

# With the file backend's approval gate on, the breaker issue (never approved) stays visible.
OUT=$(AUTOCODER_REQUIRED_LABEL=approved bash "$BREAKER" --ref origin/master)
has "approval gate: a trip still sees the open breaker" "already open as #${B}" "$OUT"
eq  "approval gate: --active still finds it" "$B" "$(AUTOCODER_REQUIRED_LABEL=approved bash "$BREAKER" --active)"

A=$(bash "$BREAKER" --active); RC=$?
eq "--active: exit 0 while open" 0 "$RC"
eq "--active: prints the issue" "$B" "$A"
config '"off"'
bash "$BREAKER" --active >/dev/null; eq "--active: off overrides an open issue" 1 "$?"
config

# ── bad settings ─────────────────────────────────────────────────────────────
for bad_cfg in '{"threshold": 0}' '{"threshold": 2}' '{"window": "20"}' '{"minReverts": 0}' '{"windo": 5}' '"on"'; do
  config "$bad_cfg"
  bash "$BREAKER" --ref origin/master >/dev/null 2>&1; eq "bad setting $bad_cfg: check exits 2" 2 "$?"
  bash "$BREAKER" --active >/dev/null 2>&1;            eq "bad setting $bad_cfg: --active exits 2" 2 "$?"
done
config

# ── landing while open: a PR, and the issue parked ───────────────────────────
W=$(issue_create --title "work" --body "b" --label P2 | jq -r .number)
issue_claim "$W" >/dev/null
git checkout -q -b "feature/issue-$W"; commit "#$W: the work"
SUM="$TMP/summary.md"; printf '## Summary\nthe fix\n' > "$SUM"
: > "$GH_LOG"
OUT=$(bash "$SCRIPTS/merge-launch.sh" --feature "feature/issue-$W" --issue "$W" --integration master \
        --test-cmd true --summary-file "$SUM" --own-issue 2>&1); RC=$?
eq  "open breaker: merge-launch exits 0" 0 "$RC"
has "open breaker: says it lands as a PR" "landing issue #${W} as a pull request" "$OUT"
eq  "open breaker: branch pushed" "$(git rev-parse HEAD)" "$(git ls-remote origin "refs/heads/feature/issue-$W" | cut -f1)"
has "open breaker: PR opened against master" "pr create --base master --head feature/issue-$W" "$(cat "$GH_LOG")"
has "open breaker: PR body carries the summary" "the fix" "$(cat "$GH_LOG")"
has "open breaker: PR body names the breaker" "(#${B})" "$(cat "$GH_LOG")"
LBL=$(issue_get "$W" | jq -c '[.labels[].name] | sort')
eq  "open breaker: issue parked under awaiting-integration" '["P2","awaiting-integration"]' "$LBL"
has "open breaker: issue comment links the PR" "https://example.invalid/pull/7" "$(issue_get "$W" | jq -r '.body, (.comments[]?.body)')"
ls "$AUTOCODER_TMP"/autocoder-merge-* >/dev/null 2>&1 && bad "open breaker: no merge job started" || ok "open breaker: no merge job started"

# A failed PR leaves the label alone.
W2=$(issue_create --title "work2" --body "b" --label P2 | jq -r .number)
issue_claim "$W2" >/dev/null
git checkout -q -b "feature/issue-$W2" master; commit "#$W2: more work"
GH_FAIL=1 bash "$SCRIPTS/merge-launch.sh" --feature "feature/issue-$W2" --issue "$W2" --integration master \
  --test-cmd true --own-issue >/dev/null 2>&1; RC=$?
eq "PR failure: exit 1" 1 "$RC"
eq "PR failure: issue keeps working" '["P2","working"]' "$(issue_get "$W2" | jq -c '[.labels[].name] | sort')"

# No gh: the branch is pushed for review and the issue parked with a note; nothing stalls.
W3=$(issue_create --title "work3" --body "b" --label P2 | jq -r .number)
issue_claim "$W3" >/dev/null
git checkout -q -b "feature/issue-$W3" master; commit "#$W3: third work"
: > "$GH_LOG"
OUT=$(AUTOCODER_GH=/nonexistent/gh bash "$SCRIPTS/merge-launch.sh" --feature "feature/issue-$W3" --issue "$W3" \
        --integration master --own-issue 2>&1); RC=$?
eq  "no gh: exit 0" 0 "$RC"
has "no gh: says the branch is pushed for review" "pushed for a human to review" "$OUT"
eq  "no gh: branch pushed" "$(git rev-parse HEAD)" "$(git ls-remote origin "refs/heads/feature/issue-$W3" | cut -f1)"
eq  "no gh: issue parked" '["P2","awaiting-integration"]' "$(issue_get "$W3" | jq -c '[.labels[].name] | sort')"
eq  "no gh: no gh call" "" "$(cat "$GH_LOG")"

# ── closing it restores merge ────────────────────────────────────────────────
issue_close "$B" --comment "cause understood" >/dev/null
bash "$BREAKER" --active >/dev/null; eq "closed: --active exits 1" 1 "$?"
: > "$GH_LOG"
# No test command anywhere and a code change: the merge path refuses before launching,
# which shows the launch took the merge path, not the PR path.
OUT=$(bash "$SCRIPTS/merge-launch.sh" --feature "feature/issue-$W2" --issue "$W2" --integration master --own-issue 2>&1)
has "closed: merge-launch takes the merge path" "no test command" "$OUT"
eq  "closed: no PR opened" "" "$(grep 'pr create' "$GH_LOG")"

# A bad setting is reported at launch, and landing goes on as configured.
config '{"threshold": 5}'
OUT=$(bash "$SCRIPTS/merge-launch.sh" --feature "feature/issue-$W2" --issue "$W2" --integration master --own-issue 2>&1)
has "bad setting at launch: reported" "Revert breaker check failed" "$OUT"
has "bad setting at launch: takes the merge path" "no test command" "$OUT"
config

# An unconfigured repo: no tracker to read, and nothing gets written.
git init -q "$TMP/bare-repo"
( cd "$TMP/bare-repo" && unset ISSUE_SOURCE && bash "$BREAKER" --active >/dev/null 2>&1; echo "rc=$?" ) > "$TMP/unconf.out"
eq "unconfigured: --active says closed" "rc=1" "$(cat "$TMP/unconf.out")"
[ -e "$TMP/bare-repo/.autocoder.json" ] && bad "unconfigured: no .autocoder.json written" || ok "unconfigured: no .autocoder.json written"

# ── the sentinel runs the breaker after every revert ─────────────────────────
sed -n '/^finish_revert()/,/^}/p' "$SCRIPTS/main-sentinel.sh" | grep -q 'revert-breaker.sh' \
  && ok "sentinel: finish_revert runs revert-breaker.sh" || bad "sentinel: finish_revert runs revert-breaker.sh"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
