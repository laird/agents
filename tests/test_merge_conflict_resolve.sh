#!/bin/bash
# tests/test_merge_conflict_resolve.sh — the merge job resolves a conflicted rebase in its
# own worktree before bouncing or escalating (#164, merge-conflict-fns.sh):
#   - files declared in .autocoder.json "unionMerge" are union-merged and land;
#   - a resolver command (here a fake, never a real Claude session) gets one bounded try,
#     runs in the throwaway worktree, and its result is gated before anything is pushed;
#   - a declined, timed-out, marker-leaving or HEAD-moving attempt falls back to the
#     usual bounce, with the attempted resolution attached;
#   - a resolved tree that fails the gate is not pushed;
#   - the resolver runs at most once per job;
#   - with nothing configured the conflict bounces exactly as before.
# File backend and a local bare origin, as in tests/test_merge_bounce.sh.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ISSUE=16401

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AUTOCODER_SPOT_CHECK_RATE=0
export ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE
unset AUTOCODER_UNION_MERGE AUTOCODER_CONFLICT_RESOLVER AUTOCODER_CONFLICT_RESOLVER_TIMEOUT

# setup [extra feature commit]: master has LIST.txt and src/a.sh; feature/code appends to
# LIST.txt and rewrites src/a.sh; with an argument it adds a second commit that edits
# src/b.sh, so a rebase can stop twice.
setup() {
  rm -rf "$TMP/origin.git" "$TMP/worker" "$TMP/sibling" "$TMP/gate-cache" "$TMP/issues" "$TMP/calls"
  mkdir -p "$TMP/issues/open" "$TMP/issues/working" "$TMP/issues/blocked" "$TMP/issues/closed"
  printf -- '---\nnumber: %s\ntitle: Conflict\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$ISSUE" > "$TMP/issues/open/${ISSUE}.md"
  python3 "$ISSUES_PY" claim "$ISSUE"
  git init --bare -q "$TMP/origin.git"
  git init -q "$TMP/worker"
  cd "$TMP/worker" || exit 1
  git config user.email t@example.com; git config user.name T
  git remote add origin "$TMP/origin.git"
  printf 'one\ntwo\n' > LIST.txt; mkdir -p src; echo base > src/a.sh; echo base > src/b.sh
  git add -A; git commit -q -m init; git branch -M master; git push -q origin master master:master-green
  git fetch -q origin
  git checkout -q -b feature/code master
  echo feature-item >> LIST.txt; echo feature > src/a.sh
  git add -A; git commit -q -m "feature: add item, rewrite a"
  if [ -n "${1:-}" ]; then
    echo feature > src/b.sh; git add -A; git commit -q -m "feature: rewrite b"
  fi
  git clone -q "$TMP/origin.git" "$TMP/sibling"
  git -C "$TMP/sibling" config user.email s@example.com; git -C "$TMP/sibling" config user.name S
}
config() { printf '%s\n' "$1" > "$TMP/worker/.autocoder.json"; }   # main worktree, untracked
sibling_edit() { # sibling lands "<path>=<content>" edits on master
  (cd "$TMP/sibling" && git pull -q origin master && for kv in "$@"; do printf '%s\n' "${kv#*=}" > "${kv%%=*}"; done && git add -A && git commit -q -m "sibling: $*" && git push -q origin master)
}
sibling_append() { (cd "$TMP/sibling" && git pull -q origin master && echo sibling-item >> LIST.txt && git add -A && git commit -q -m "sibling: add item" && git push -q origin master); }

issue_file()   { ls "$TMP"/issues/*/"${ISSUE}.md" 2>/dev/null | head -1; }
issue_bucket() { basename "$(dirname "$(issue_file)")"; }
issue_body()   { cat "$(issue_file)"; }
origin_show()  { git --git-dir="$TMP/origin.git" show "master:$1"; }
origin_tip()   { git --git-dir="$TMP/origin.git" rev-parse master; }
run_own()      { bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "${1:-true}" --own-issue 2>&1; }

# ── 1. nothing configured: the conflict bounces as before ──────────────────
setup
sibling_append
OUT=$(run_own); RC=$?
[ "$RC" -eq 1 ] && [ "$(issue_bucket)" = working ] && ok "unconfigured: conflict still bounces" || bad "unconfigured: rc=$RC $(issue_bucket): $OUT"
issue_body | grep -q "Automatic conflict resolution" && bad "unconfigured: claims an attempt" || ok "unconfigured: no attempt mentioned"

# ── 2. unionMerge: an append-only file is union-merged, gated and landed ───
setup
sibling_append
config '{"unionMerge": ["*.txt"]}'
OUT=$(run_own); RC=$?
[ "$RC" -eq 0 ] && ok "union: lands (exit 0)" || bad "union: rc=$RC: $OUT"
[ "$(issue_bucket)" = closed ] && ok "union: issue closed" || bad "union: bucket $(issue_bucket)"
LIST=$(origin_show LIST.txt)
echo "$LIST" | grep -qx feature-item && echo "$LIST" | grep -qx sibling-item && ! echo "$LIST" | grep -q '^[<=>]\{7\}' \
  && ok "union: both sides' items on master, no markers" || bad "union: LIST.txt = $LIST"
issue_body | grep -q 'Conflict auto-resolved.*union' && issue_body | grep -q '^- `LIST.txt`$' \
  && ok "union: close comment names the resolved file and method" || bad "union comment: $(issue_body)"
echo "$OUT" | grep -q "Union-merged LIST.txt" && ok "union: logged" || bad "union log: $OUT"

# ── 3. union applies only to declared files ─────────────────────────────────
setup
sibling_append
config '{"unionMerge": ["docs/*.md"]}'
OUT=$(run_own); RC=$?
[ "$RC" -eq 1 ] && [ "$(issue_bucket)" = working ] && ok "undeclared file: bounces" || bad "undeclared: rc=$RC $(issue_bucket)"

# ── 4. resolver (from .autocoder.json) resolves; runs in the throwaway worktree ─
setup
sibling_edit src/a.sh=sibling
cat > "$TMP/resolver.sh" <<'R'
pwd > "$TMP_CALLS/pwd"; echo x >> "$TMP_CALLS/count"
printf '%s\n' "$AUTOCODER_CONFLICT_FILES" > "$TMP_CALLS/files"
cp "$AUTOCODER_CONFLICT_CONTEXT" "$TMP_CALLS/context"
for f in $AUTOCODER_CONFLICT_FILES; do printf 'merged\n' > "$f"; done
R
mkdir -p "$TMP/calls"; export TMP_CALLS="$TMP/calls"
config "{\"conflictResolver\": \"bash $TMP/resolver.sh\"}"
WORKER_SHA=$(git -C "$TMP/worker" rev-parse feature/code)
OUT=$(run_own); RC=$?
[ "$RC" -eq 0 ] && [ "$(issue_bucket)" = closed ] && ok "resolver: lands and closes" || bad "resolver: rc=$RC $(issue_bucket): $OUT"
[ "$(origin_show src/a.sh)" = merged ] && ok "resolver: its resolution is what landed" || bad "resolver: a.sh = $(origin_show src/a.sh)"
[ "$(cat "$TMP/calls/files")" = src/a.sh ] && ok "resolver: given the conflicted files" || bad "resolver files: $(cat "$TMP/calls/files")"
grep -q "feature: add item, rewrite a" "$TMP/calls/context" && grep -q "sibling: src/a.sh=sibling" "$TMP/calls/context" \
  && ok "resolver: context has both sides' commit messages" || bad "context: $(cat "$TMP/calls/context")"
case "$(cat "$TMP/calls/pwd")" in
  "$TMP/worker"|"$TMP/worker/"*) bad "resolver ran in the worker's checkout" ;;
  *) ok "resolver: ran outside the worker's checkout" ;;
esac
[ "$(git -C "$TMP/worker" rev-parse feature/code)" = "$WORKER_SHA" ] && [ "$(cat "$TMP/worker/src/a.sh")" = feature ] \
  && ok "resolver: worker's branch and files untouched" || bad "worker checkout changed"
issue_body | grep -q 'Conflict auto-resolved.*resolver' && issue_body | grep -q 'not part of the reviewed HEAD' \
  && ok "resolver: close comment says the resolution was unreviewed but gated" || bad "resolver comment: $(issue_body)"

# ── 5. resolved tree fails the gate: nothing pushed, bounce carries the note ─
setup
sibling_edit src/a.sh=sibling
export AUTOCODER_CONFLICT_RESOLVER='for f in $AUTOCODER_CONFLICT_FILES; do echo broken > "$f"; done'
BEFORE=$(origin_tip)
OUT=$(run_own '! grep -q broken src/a.sh'); RC=$?
[ "$RC" -eq 2 ] && [ "$(origin_tip)" = "$BEFORE" ] && ok "red resolution: gate fails, nothing pushed" || bad "red resolution: rc=$RC: $OUT"
[ "$(issue_bucket)" = working ] && issue_body | grep -q 'Resolved automatically in this run, but nothing landed' \
  && ok "red resolution: bounced with the resolution noted" || bad "red resolution state: $(issue_bucket): $(issue_body)"

# ── 6. resolver declines: bounce with the attempted diff attached ──────────
setup
sibling_edit src/a.sh=sibling
export AUTOCODER_CONFLICT_RESOLVER='echo half-done > src/a.sh; exit 3'
OUT=$(run_own); RC=$?
[ "$RC" -eq 1 ] && [ "$(issue_bucket)" = working ] && ok "declined: bounces as a conflict" || bad "declined: rc=$RC $(issue_bucket): $OUT"
issue_body | grep -q 'tried and refused.*declined (exit 3)' && issue_body | grep -q '^+half-done$' \
  && ok "declined: comment has the reason and the attempted diff" || bad "declined comment: $(issue_body)"
issue_body | grep -q '<!-- autocoder-bounce kind=conflict ' && ok "declined: still a conflict bounce marker" || bad "declined marker"

# ── 7. resolver exits 0 but leaves markers: refused ─────────────────────────
setup
sibling_edit src/a.sh=sibling
export AUTOCODER_CONFLICT_RESOLVER='true'
OUT=$(run_own); RC=$?
[ "$RC" -eq 1 ] && issue_body | grep -q 'left conflict markers in: src/a.sh' && ok "markers left: refused" || bad "markers: rc=$RC: $(issue_body)"

# ── 8. resolver commits (moves HEAD): refused ───────────────────────────────
setup
sibling_edit src/a.sh=sibling
export AUTOCODER_CONFLICT_RESOLVER='echo x > src/a.sh; git add -A; git -c user.email=r@x -c user.name=R commit -q -m sneaky'
OUT=$(run_own); RC=$?
[ "$RC" -eq 1 ] && issue_body | grep -q 'moved HEAD or ended the rebase' && ok "HEAD moved: refused" || bad "HEAD moved: rc=$RC: $(issue_body)"

# ── 8b. resolver edits a file it was not given (tracked or new): refused ───
setup
sibling_edit src/a.sh=sibling
export AUTOCODER_CONFLICT_RESOLVER='echo merged > src/a.sh; echo extra > src/b.sh'
OUT=$(run_own); RC=$?
[ "$RC" -eq 1 ] && issue_body | grep -q 'changed files it was not given: src/b.sh' && [ "$(origin_show src/a.sh)" = sibling ] \
  && ok "stray tracked edit: refused, nothing landed" || bad "stray tracked: rc=$RC: $(issue_body)"
setup
sibling_edit src/a.sh=sibling
export AUTOCODER_CONFLICT_RESOLVER='echo merged > src/a.sh; echo helper > src/helper.sh'
OUT=$(run_own); RC=$?
[ "$RC" -eq 1 ] && issue_body | grep -q 'changed files it was not given: src/helper.sh' \
  && ok "stray new file: refused (it would be gated but not pushed)" || bad "stray new: rc=$RC: $(issue_body)"
issue_body | grep -q 'Resolved automatically\|Conflict auto-resolved' && bad "refused attempt claims a resolution" || ok "refused attempt claims no resolution"

# ── 9. resolver times out ───────────────────────────────────────────────────
setup
sibling_edit src/a.sh=sibling
export AUTOCODER_CONFLICT_RESOLVER='sleep 30' AUTOCODER_CONFLICT_RESOLVER_TIMEOUT=1
T0=$SECONDS
OUT=$(run_own); RC=$?
unset AUTOCODER_CONFLICT_RESOLVER_TIMEOUT
[ "$RC" -eq 1 ] && [ $((SECONDS - T0)) -lt 25 ] && issue_body | grep -q 'timed out after 1s' \
  && ok "timeout: bounded, refused" || bad "timeout: rc=$RC $((SECONDS - T0))s: $(issue_body)"

# ── 10. one resolver attempt per job, even when the rebase stops twice ─────
setup two-commits
sibling_edit src/a.sh=sibling src/b.sh=sibling
rm -rf "$TMP/calls"; mkdir -p "$TMP/calls"
export AUTOCODER_CONFLICT_RESOLVER='echo x >> "$TMP_CALLS/count"; for f in $AUTOCODER_CONFLICT_FILES; do echo merged > "$f"; done'
OUT=$(run_own); RC=$?
[ "$(wc -l < "$TMP/calls/count")" -eq 1 ] && ok "second stop: resolver not run again" || bad "resolver ran $(wc -l < "$TMP/calls/count") times"
[ "$RC" -eq 1 ] && [ "$(issue_bucket)" = working ] && issue_body | grep -q '^- `src/b.sh`$' \
  && ok "second stop: bounces with the remaining conflict" || bad "second stop: rc=$RC $(issue_bucket): $(issue_body)"

# ── 11. off disables a configured resolver ──────────────────────────────────
setup
sibling_edit src/a.sh=sibling
config "{\"conflictResolver\": \"bash $TMP/resolver.sh\"}"
export AUTOCODER_CONFLICT_RESOLVER=off
rm -rf "$TMP/calls"; mkdir -p "$TMP/calls"
OUT=$(run_own); RC=$?
[ "$RC" -eq 1 ] && [ ! -e "$TMP/calls/count" ] && ok "env off overrides .autocoder.json" || bad "off: rc=$RC calls=$(cat "$TMP/calls/count" 2>/dev/null)"
unset AUTOCODER_CONFLICT_RESOLVER

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
