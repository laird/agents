#!/bin/bash
# tests/test_ci_watch.sh — ci-watch.sh turns a red GitHub Actions run on the integration
# branch into one P0 test-failure issue, updates it for a later red commit, closes it when a
# later commit is green, and stays silent for pending, missing or non-GitHub CI. The
# post-merge sentinel calls it on every tick.
# Hermetic: a stubbed `gh` serves recorded `gh run list/view --json` fixtures, the issue
# layer is the file backend in a temp dir, and the GitHub origin is redirected to a local
# bare repo with url.<path>.insteadOf.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CIW="$ROOT/plugins/autocoder/scripts/ci-watch.sh"
SENTINEL="$ROOT/plugins/autocoder/scripts/main-sentinel.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset ISSUE_BACKEND

GH_URL="https://github.com/acme/widget.git"
FIX="$TMP/fixtures"; GHLOG="$TMP/gh.log"
mkdir -p "$TMP/bin" "$FIX" "$TMP/state" "$TMP/tmp"
: > "$GHLOG"
# gh stub: `run list --commit <sha>` → $FIX/runs-<sha>.json (or []), `run view <id>` →
# $FIX/jobs-<id>.json. Every call is logged so the tests can count them.
cat > "$TMP/bin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$GHLOG"
if [ "\$1 \$2" = "run list" ]; then
  while [ \$# -gt 0 ]; do [ "\$1" = --commit ] && { sha="\$2"; break; }; shift; done
  cat "$FIX/runs-\$sha.json" 2>/dev/null || echo '[]'; exit 0
fi
if [ "\$1 \$2" = "run view" ]; then cat "$FIX/jobs-\$3.json" 2>/dev/null || echo '{"jobs":[]}'; exit 0; fi
exit 1
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

ISSUES="$TMP/.issues"
mkdir -p "$ISSUES/open" "$ISSUES/working" "$ISSUES/blocked" "$ISSUES/closed"
echo 100 > "$ISSUES/.seq"
export ISSUE_SOURCE=file ISSUE_DIR_PATH="$ISSUES"
export AUTOCODER_SENTINEL_STATE_DIR="$TMP/state" AUTOCODER_TMP="$TMP/tmp" AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export AUTOCODER_CI_WATCH_INTERVAL=0

git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
REPO="$TMP/repo"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name T
git -C "$REPO" checkout -q -b main
git -C "$REPO" remote set-url origin "$GH_URL"
git -C "$REPO" config "url.$TMP/origin.git.insteadOf" "$GH_URL"
commit() { echo "$1" > "$REPO/f"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "$1"; git -C "$REPO" rev-parse HEAD; }
A=$(commit a); B=$(commit b); C=$(commit c); D=$(commit d); E=$(commit e)
git -C "$REPO" push -q origin main 2>/dev/null
git -C "$REPO" update-ref "refs/autocoder/tips/main/$A-41" "$A"
git -C "$REPO" update-ref "refs/autocoder/tips/main/$B-57" "$B"

cat > "$FIX/runs-$A.json" <<'EOF'
[{"databaseId":11,"conclusion":"failure","name":"Tests","status":"completed"},
 {"databaseId":12,"conclusion":"success","name":"Lint","status":"completed"}]
EOF
cat > "$FIX/jobs-11.json" <<'EOF'
{"jobs":[{"name":"test (macos-latest)","conclusion":"failure","steps":[
  {"name":"Checkout","conclusion":"success"},{"name":"Run suite","conclusion":"failure"}]},
 {"name":"test (ubuntu-latest)","conclusion":"success","steps":[]}]}
EOF
cat > "$FIX/runs-$B.json" <<'EOF'
[{"databaseId":21,"conclusion":"timed_out","name":"Tests","status":"completed"}]
EOF
cat > "$FIX/jobs-21.json" <<'EOF'
{"jobs":[{"name":"test (windows-latest)","conclusion":"timed_out","steps":[{"name":"Build","conclusion":"timed_out"}]}]}
EOF
cat > "$FIX/runs-$C.json" <<'EOF'
[{"databaseId":31,"conclusion":"","name":"Tests","status":"in_progress"},
 {"databaseId":32,"conclusion":"failure","name":"Lint","status":"completed"}]
EOF
cat > "$FIX/runs-$D.json" <<'EOF'
[{"databaseId":41,"conclusion":"success","name":"Tests","status":"completed"},
 {"databaseId":42,"conclusion":"skipped","name":"Docs","status":"completed"}]
EOF

ciw() { bash "$CIW" --repo "$REPO" --integration main "$@"; }
open_ci() { grep -l "^title: *\"\?CI red on main" "$ISSUES"/open/*.md 2>/dev/null; }
closed_ci() { grep -l "^title: *\"\?CI red on main" "$ISSUES"/closed/*.md 2>/dev/null; }
n_ci() { { open_ci; closed_ci; } | wc -l; }

echo "── 1. green, pending or no runs: no issue ──"
ciw "$E" >/dev/null; RC=$?
check "no runs: exit 0, no issue" '[ "$RC" -eq 0 ] && [ "$(n_ci)" -eq 0 ]'
ciw "$C" >/dev/null; RC=$?
check "a run still in progress: exit 0, no issue yet (even with another failed)" '[ "$RC" -eq 0 ] && [ "$(n_ci)" -eq 0 ]'
check "pending is not a verdict: state does not mark it done" '! grep -q "^done_sha=$C" "$TMP"/state/*.ci'

echo "── 2. red completed run: opens a P0 test-failure issue ──"
OUT=$(ciw "$A"); RC=$?
F=$(open_ci)
check "exit 0 and one open CI issue" '[ "$RC" -eq 0 ] && [ "$(echo "$F" | grep -c .)" -eq 1 ]'
check "labelled P0 and test-failure" 'grep -q "P0" "$F" && grep -q "test-failure" "$F"'
check "names the failing workflow, job and step" 'grep -q "Tests" "$F" && grep -q "test (macos-latest)" "$F" && grep -q "Run suite" "$F"'
check "does not list the passing job or workflow" '! grep -q "ubuntu-latest" "$F" && ! grep -q "Lint" "$F"'
check "names the sha and the landing issue" 'grep -q "$A" "$F" && grep -q "#41" "$F"'
check "reports what it did" 'grep -q "filed" <<< "$OUT"'

echo "── 3. a reported sha is not re-reported ──"
: > "$GHLOG"
cp "$F" "$TMP/before.md"
ciw "$A" >/dev/null
check "same sha again: no gh call, issue unchanged" '[ ! -s "$GHLOG" ] && cmp -s "$F" "$TMP/before.md"'

echo "── 4. a second red sha updates the same issue ──"
OUT=$(ciw "$B")
check "still exactly one CI issue" '[ "$(n_ci)" -eq 1 ] && [ "$(open_ci)" = "$F" ]'
check "the update names the new sha, job, step and landing issue" 'grep -q "$B" "$F" && grep -q "windows-latest" "$F" && grep -q "Build" "$F" && grep -q "#57" "$F"'
check "reports the update" 'grep -q "updated" <<< "$OUT"'

echo "── 5. a stale green sha does not close a newer red report ──"
cat > "$FIX/runs-$A.json" <<'EOF'
[{"databaseId":13,"conclusion":"success","name":"Tests","status":"completed"}]
EOF
sed -i '/^done_sha=/d' "$TMP"/state/*.ci
ciw "$A" >/dev/null
check "green on an ancestor of the red sha leaves the issue open" '[ -n "$(open_ci)" ]'

echo "── 6. a later green run closes the open CI issue ──"
OUT=$(ciw "$D")
check "issue closed with a comment naming the green sha" '[ -z "$(open_ci)" ] && [ -n "$(closed_ci)" ] && grep -q "green" "$(closed_ci)" && grep -q "$D" "$(closed_ci)"'
check "reports the close" 'grep -q "closed" <<< "$OUT"'

echo "── 7. rate limit ──"
: > "$GHLOG"
AUTOCODER_CI_WATCH_INTERVAL=3600 ciw "$E" >/dev/null
check "a check inside the interval makes no gh call" '[ ! -s "$GHLOG" ]'

echo "── 8. no gh, no GitHub remote: silent no-op ──"
# A PATH with every system tool except gh.
mkdir -p "$TMP/nogh"
for f in /usr/bin/* /bin/*; do
  n=$(basename "$f"); [ "$n" = gh ] || [ -e "$TMP/nogh/$n" ] || ln -s "$f" "$TMP/nogh/$n"
done
OUT=$(PATH="$TMP/nogh" bash "$CIW" --repo "$REPO" --integration main "$A" 2>&1); RC=$?
check "no gh: exit 0, no output" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'
LOCAL="$TMP/local"; git clone -q "$TMP/origin.git" "$LOCAL" 2>/dev/null
: > "$GHLOG"
OUT=$(bash "$CIW" --repo "$LOCAL" --integration main "$A" 2>&1); RC=$?
check "non-GitHub origin: exit 0, no output, no gh call" '[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -s "$GHLOG" ]'
OUT=$(bash "$CIW" --repo "$REPO" --integration main 0000000000000000000000000000000000000000 2>&1); RC=$?
check "unknown sha: exit 0, no output" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

echo "── 8b. a failed issue write is retried, not lost ──"
F2=$(commit f2); git -C "$REPO" update-ref "refs/autocoder/tips/main/$F2-PROJ-7" "$F2"
cat > "$FIX/runs-$F2.json" <<'EOF'
[{"databaseId":61,"conclusion":"failure","name":"Tests `x` @org/team [l](https://e)","status":"completed"}]
EOF
cat > "$FIX/jobs-61.json" <<'EOF'
{"jobs":[{"name":"job `y` @someone","conclusion":"failure","steps":[{"name":"step <b>","conclusion":"failure"}]}]}
EOF
chmod a-w "$ISSUES/open"
OUT=$(ciw "$F2" 2>&1); RC=$?
chmod u+w "$ISSUES/open"
check "create fails: exit 0, nothing filed, sha not marked done" '[ "$RC" -eq 0 ] && [ -z "$(open_ci)" ] && ! grep -q "^done_sha=$F2" "$TMP"/state/*.ci'
OUT=$(ciw "$F2"); F=$(open_ci)
check "the next call files it" '[ -n "$F" ] && grep -q "$F2" "$F" && grep -q "filed" <<< "$OUT"'
check "untrusted names cannot mention, link or leave a code span" '! grep -q "@" "$F" && ! grep -q "\[l\]" "$F" && ! grep -q "<b>" "$F" && grep -q "job \`job  y   someone\`" "$F"'
check "a Jira-style landing key is named as-is" 'grep -q "Landed by: PROJ-7" "$F"'
check "runs are asked for on the integration branch only" 'grep -q -- "--branch main" "$GHLOG"'
rm -f "$F"

echo "── 8c. an integration branch with a slash keeps its state ──"
: > "$GHLOG"
ciw --integration release/1.0 "$E" >/dev/null 2>&1
check "state saved under a flattened name" 'ls "$TMP"/state/*-release_1.0.ci >/dev/null 2>&1'

echo "── 9. the post-merge sentinel calls it for the tip ──"
rm -f "$TMP"/state/*.ci
cat > "$FIX/runs-$E.json" <<'EOF'
[{"databaseId":51,"conclusion":"failure","name":"Tests","status":"completed"}]
EOF
OUT=$(bash "$SENTINEL" --repo "$REPO" --integration main --test-cmd true 2>&1); RC=$?
check "sentinel tick exits 0 and files the CI issue for the tip" '[ "$RC" -eq 0 ] && grep -q "CI red at ${E:0:7}" <<< "$OUT" && [ -n "$(open_ci)" ] && grep -q "$E" "$(open_ci)"'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
