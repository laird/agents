#!/bin/bash
# tests/test_merge_net_timeout.sh — the detached merge job's own network calls are bounded
# (#234). A stalled push used to hang merge-to-integration.sh for as long as the
# connection did, with the issue stuck under `merging`. With git_net_long the push gives
# up after AUTOCODER_GIT_TIMEOUT_LONG, the retry loop and fallback run, and the job ends
# with a clear failure instead of hanging.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/plugins/autocoder/scripts"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
command -v timeout >/dev/null || { echo "SKIP: no coreutils timeout"; echo "Tests: 0 failed, 0 passed, 0 total"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file AUTOCODER_SPOT_CHECK_RATE=0 AUTOCODER_MERGE_QUEUE=0
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache" AUTOCODER_MERGE_EVENTS="$TMP/events.jsonl"
REAL_GIT=$(command -v git)

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/w"; cd "$TMP/w" || exit 1
git config user.email t@example.com; git config user.name T
git remote add origin "$TMP/origin.git"
echo base > README.md; git add -A; git commit -q -m base; git branch -M master; git push -q origin master
git checkout -q -b feature/issue-23401; echo fix > fix.txt; git add -A; git commit -q -m fix
git push -q origin feature/issue-23401

# A git whose pushes stall like a dead connection; everything else is real.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/git" <<STUB
#!/bin/bash
for a in "\$@"; do [ "\$a" = push ] && { echo \$\$ >> "$TMP/stalled.pids"; exec sleep 600; }; done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$TMP/bin/git"
# No GitHub API fallback in this sandbox: make it fail fast rather than reach the network.
cat > "$TMP/bin/python3" <<STUB
#!/bin/bash
case "\$1" in *api-push.py) echo "api fallback disabled in test" >&2; exit 1 ;; esac
exec $(command -v python3) "\$@"
STUB
chmod +x "$TMP/bin/python3"

START=$SECONDS
OUT=$(PATH="$TMP/bin:$PATH" AUTOCODER_GIT_TIMEOUT_LONG=2 timeout 240 bash "$S/merge-to-integration.sh" \
  --feature feature/issue-23401 --issue 23401 --integration master --test-cmd true 2>&1); RC=$?
ELAPSED=$((SECONDS - START))
[ "$RC" -ne 124 ] && ok "the job ended on its own (rc=$RC, ${ELAPSED}s), not killed by the outer timeout" \
  || bad "the job hung on the stalled push: $(tail -5 <<<"$OUT")"
[ "$RC" -ne 0 ] && ok "a push that never completes is reported as a failure" || bad "rc 0 despite no push"
echo "$OUT" | grep -q "Could not publish" && ok "says it could not publish" || bad "output: $(tail -8 <<<"$OUT")"
[ "$(git -C "$TMP/origin.git" rev-parse master)" = "$(git -C "$TMP/w" rev-parse master)" ] \
  && ok "nothing landed on origin/master" || bad "origin/master moved"
LEFT=""; for p in $(cat "$TMP/stalled.pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && { LEFT="$LEFT $p"; kill "$p" 2>/dev/null; }; done
[ -s "$TMP/stalled.pids" ] && ok "the stalled push was really attempted ($(wc -l < "$TMP/stalled.pids") time(s))" || bad "no push was ever attempted"
[ -z "$LEFT" ] && ok "no stalled push left running" || bad "stalled push process(es) left running:$LEFT"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
