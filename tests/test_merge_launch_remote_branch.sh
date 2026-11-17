#!/bin/bash
# tests/test_merge_launch_remote_branch.sh — merge-launch.sh and feature branches
# that are not (only) local (#206, building on #143).
#
# - A branch that exists only on origin (pushed from another worktree or host)
#   resolves to origin's SHA, which is what the detached job is given (#143's
#   resolve_feature_sha).
# - A branch that resolves nowhere is refused AT LAUNCH, before the detached job
#   hands the issue off to `merging` and then escalates it to needs-clarification.
#
# The detached merge-to-integration.sh is replaced with a stub that records its
# arguments, so nothing is merged or pushed.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"

mkdir -p "$TMP/bin"
cp "$SCRIPT_DIR/merge-launch.sh" "$SCRIPT_DIR/test-cmd-fns.sh" "$SCRIPT_DIR/repo-id-fns.sh" \
   "$SCRIPT_DIR/feature-ref-fns.sh" "$SCRIPT_DIR/merge-archive-fns.sh" "$TMP/bin/"
cat > "$TMP/bin/merge-to-integration.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$TMP/mti-args"
EOF
chmod +x "$TMP/bin/merge-to-integration.sh"

g() { git -c user.email=t@example.com -c user.name=T "$@"; }

# origin has master plus feature/issue-206-v2; the worker clone fetched before the
# feature branch was pushed, so it knows neither the branch nor its remote ref.
git init -q --bare -b master "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/seed" 2>/dev/null
cd "$TMP/seed" || exit 1
echo base > f; g add f; g commit -qm base; g push -q origin HEAD:master
g clone -q "$TMP/origin.git" "$TMP/worker" 2>/dev/null
g checkout -q -b feature/issue-206-v2
echo change >> f; g commit -qam change; g push -q origin feature/issue-206-v2
REMOTE_SHA=$(git rev-parse HEAD)

cd "$TMP/worker" || exit 1
git rev-parse --verify -q feature/issue-206-v2 >/dev/null \
  && bad "fixture: worker should not know the branch yet" || ok "fixture: branch exists only on origin"

# The SHA the job was given: the line after --feature-sha.
pinned_sha() { sed -n '/^--feature-sha$/{n;p;}' "$TMP/mti-args"; }
wait_args() { for _ in $(seq 1 50); do [ -s "$TMP/mti-args" ] && return 0; sleep 0.1; done; return 1; }

# ── remote-only branch: origin's SHA pinned ──────────────────────────────────
rm -f "$TMP/mti-args"
OUT=$(bash "$TMP/bin/merge-launch.sh" --feature feature/issue-206-v2 --issue 206 \
  --integration master --test-cmd "true" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "remote-only branch launches" || { bad "remote-only branch: exit $RC"; echo "$OUT"; }
if wait_args; then
  [ "$(pinned_sha)" = "$REMOTE_SHA" ] \
    && ok "pinned SHA passed to the merge job" || bad "merge job got SHA '$(pinned_sha)'"
else
  bad "merge job never started"
fi

# ── branch in neither place: refused at launch, no job started ────────────────
rm -f "$TMP/mti-args"
OUT=$(bash "$TMP/bin/merge-launch.sh" --feature feature/issue-999 --issue 999 \
  --integration master --test-cmd "true" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "missing branch refused with exit 1" || bad "missing branch: exit $RC"
echo "$OUT" | grep -q "could not resolve 'feature/issue-999' on origin or locally" \
  && ok "refusal names the branch and both places" || bad "refusal message missing"
sleep 1
[ -e "$TMP/mti-args" ] && bad "merge job started for a missing branch" || ok "no merge job started"

# ── a branch that exists only locally (never pushed) still launches ───────────
g checkout -q -b feature/issue-207 master 2>/dev/null || g checkout -q -b feature/issue-207 origin/master
LOCAL_SHA=$(git rev-parse HEAD)
rm -f "$TMP/mti-args"
OUT=$(bash "$TMP/bin/merge-launch.sh" --feature feature/issue-207 --issue 207 \
  --integration master --test-cmd "true" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "local branch launches" || { bad "local branch: exit $RC"; echo "$OUT"; }
wait_args && [ "$(pinned_sha)" = "$LOCAL_SHA" ] \
  && ok "local SHA passed to the merge job" || bad "local SHA not passed"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
