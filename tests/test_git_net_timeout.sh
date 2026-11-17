#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_git_net_timeout.sh — worker-path git network calls are bounded (#220).
#
# A stalled HTTPS connection left resolve_feature_sha's `git fetch` (merge-launch.sh)
# hanging for minutes, so the worker never returned and the issue sat under `working`.
# Now a stall turns into a fast, clean refusal; claimed-issue-numbers.sh fails open.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/plugins/autocoder/scripts"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

command -v timeout >/dev/null || { echo "SKIP: no coreutils timeout"; echo "Tests: 0 failed, 0 passed, 0 total"; exit 0; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REAL_GIT=$(command -v git)

# A git that hangs on any network verb, like a stalled connection; everything else is real.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/git" <<STUB
#!/bin/bash
for a in "\$@"; do case "\$a" in fetch|ls-remote) exec sleep 300 ;; esac; done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$TMP/bin/git"

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/w"; cd "$TMP/w" || exit 1
git config user.email t@example.com; git config user.name T
git remote add origin "$TMP/origin.git"
git commit -q --allow-empty -m base; git branch -M master
git checkout -q -b feature/issue-22001; git commit -q --allow-empty -m fix

# ── resolve_feature_sha: a stalled fetch refuses fast instead of hanging ────
START=$SECONDS
OUT=$(PATH="$TMP/bin:$PATH" AUTOCODER_GIT_TIMEOUT=2 bash -c \
  "source '$S/feature-ref-fns.sh'; resolve_feature_sha '$TMP/w' feature/issue-22001" 2>&1); RC=$?
ELAPSED=$((SECONDS - START))
eq "stalled fetch: resolve refuses (exit 1)" "1" "$RC"
[ "$ELAPSED" -lt 20 ] && ok "returned in ${ELAPSED}s, not hung" || bad "took ${ELAPSED}s"
echo "$OUT" | grep -q "not falling back to the local branch" && ok "refusal says why" || bad "output: $OUT"
echo "$OUT" | grep -q "timed out" && ok "a timed-out fetch refuses at once (no second stalled ls-remote)" || bad "no timeout message: $OUT"
[ "$ELAPSED" -lt 6 ] && ok "one deadline, not two (${ELAPSED}s)" || bad "took ${ELAPSED}s: fetch and ls-remote both waited"

# Healthy remote: unchanged behaviour (fetch succeeds through git_net).
git push -q origin feature/issue-22001
SHA=$(AUTOCODER_GIT_TIMEOUT=10 bash -c "source '$S/feature-ref-fns.sh'; resolve_feature_sha '$TMP/w' feature/issue-22001" 2>/dev/null)
eq "healthy remote: resolves to the pushed sha" "$(git rev-parse HEAD)" "$SHA"

# ── claimed-issue-numbers.sh: a stall fails open fast ──────────────────────
START=$SECONDS
OUT=$(PATH="$TMP/bin:$PATH" AUTOCODER_GIT_TIMEOUT=2 bash "$S/claimed-issue-numbers.sh" origin 2>/dev/null); RC=$?
ELAPSED=$((SECONDS - START))
eq "stalled ls-remote: fails open with []" "0 []" "$RC $OUT"
[ "$ELAPSED" -lt 20 ] && ok "claim scan returned in ${ELAPSED}s" || bad "claim scan took ${ELAPSED}s"

# ── git_net itself ──────────────────────────────────────────────────────────
# shellcheck source=../plugins/autocoder/scripts/git-net-fns.sh
source "$S/git-net-fns.sh"
eq "git_net passes through a normal command" "$(git rev-parse HEAD)" "$(git_net rev-parse HEAD)"
AUTOCODER_GIT_TIMEOUT=bogus git_net rev-parse HEAD >/dev/null 2>&1 && ok "a bad AUTOCODER_GIT_TIMEOUT falls back to the default" || bad "bad timeout value broke git_net"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
