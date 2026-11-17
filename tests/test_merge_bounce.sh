#!/bin/bash
# tests/test_merge_bounce.sh — under --own-issue, a merge conflict or a red gate before
# the push is bounced back to the owning worker instead of escalated (#207):
#   - the issue ends `working` (merging retired), never `needs-clarification`;
#   - the comment names the conflicting files or the failing suites and ends in one
#     `<!-- autocoder-bounce kind=… worktree=… sha=… sig=… -->` marker line;
#   - a second bounce with the same kind and sig escalates to needs-clarification,
#     a different sig bounces again;
#   - other pre-push failures (unresolvable ref, publish failure) still escalate.
# File backend and a local bare origin, as in tests/test_merge_own_issue.sh.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ISSUE=20701

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE

setup() {
  rm -rf "$TMP/origin.git" "$TMP/worker" "$TMP/sibling" "$TMP/gate-cache" "$TMP/issues"
  mkdir -p "$TMP/issues/open" "$TMP/issues/working" "$TMP/issues/blocked" "$TMP/issues/closed"
  printf -- '---\nnumber: %s\ntitle: Bounce\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$ISSUE" > "$TMP/issues/open/${ISSUE}.md"
  python3 "$ISSUES_PY" claim "$ISSUE"
  git init --bare -q "$TMP/origin.git"
  git init -q "$TMP/worker"
  cd "$TMP/worker" || exit 1
  git config user.email t@example.com; git config user.name T
  git remote add origin "$TMP/origin.git"
  echo base > README.md; mkdir -p src; echo base > src/a.sh; echo base > src/b.sh
  git add -A; git commit -q -m init; git branch -M master; git push -q origin master master:master-green
  git fetch -q origin
  git checkout -q -b feature/code master
  echo change > src/a.sh; echo change > src/b.sh
  git add -A; git commit -q -m "fix"
  git clone -q "$TMP/origin.git" "$TMP/sibling"
  git -C "$TMP/sibling" config user.email s@example.com; git -C "$TMP/sibling" config user.name S
}

issue_file()   { ls "$TMP"/issues/*/"${ISSUE}.md" 2>/dev/null | head -1; }
issue_bucket() { basename "$(dirname "$(issue_file)")"; }
issue_labels() { python3 "$ISSUES_PY" get "$ISSUE" | python3 -c 'import json,sys; print(" ".join(sorted(l["name"] for l in json.load(sys.stdin)["labels"])))'; }
issue_body()   { cat "$(issue_file)"; }
markers()      { issue_body | grep -o '<!-- autocoder-bounce [^>]*-->'; }
run_own()      { bash "$MTI" --feature "${FEATURE:-feature/code}" --issue $ISSUE --integration master --test-cmd "$1" --own-issue 2>&1; }
sibling_clash() { # sibling lands conflicting edits to the given files on master
  (cd "$TMP/sibling" && git pull -q origin master && for f in "$@"; do echo "sibling $RANDOM" > "$f"; done && git add -A && git commit -q -m clash && git push -q origin master)
}
# A gate that, only on a tree carrying this change (so master alone is green and the
# failure is this change's), prints a run-shell-suite.sh-style summary failing $1.
suite_gate() { printf 'if grep -q change src/a.sh; then echo "FAIL  %s"; echo; echo "Failing suites: %s"; echo "Tests: 1 failed, 0 passed, 1 total"; false; fi' "$1" "$1"; }
sha1() { if command -v sha1sum >/dev/null; then sha1sum; else shasum -a 1; fi | cut -c1-40; }

# ── 1. conflict: bounced to working, files and marker in the comment ────────
setup
sibling_clash src/a.sh src/b.sh
OUT=$(run_own true); RC=$?
[ "$RC" -eq 1 ] && ok "conflict exits 1" || bad "conflict rc=$RC: $OUT"
[ "$(issue_bucket)" = working ] && [ "$(issue_labels)" = "bug working" ] && ok "conflict: working, not merging or needs-clarification" || bad "conflict state: $(issue_bucket) $(issue_labels)"
issue_body | grep -q '^- `src/a.sh`$' && issue_body | grep -q '^- `src/b.sh`$' && ok "conflict comment lists the conflicting files" || bad "files missing: $(issue_body)"
SHA=$(git -C "$TMP/worker" rev-parse feature/code)
WANT_SIG=$(printf 'src/a.sh\nsrc/b.sh' | sha1)
[ "$(markers | tail -1)" = "<!-- autocoder-bounce kind=conflict worktree=$TMP/worker sha=$SHA sig=$WANT_SIG -->" ] && ok "marker line: kind, caller worktree, feature sha, sha1 of the sorted file list" || bad "marker: $(markers)"
echo "$OUT" | grep -q "bounced back to its worker (conflict" && ok "log says bounced" || bad "log: $OUT"

# ── 2. the identical conflict again escalates ───────────────────────────────
OUT=$(run_own true); RC=$?
[ "$RC" -eq 1 ] && ok "repeat conflict exits 1" || bad "repeat rc=$RC"
[ "$(issue_bucket)" = blocked ] && [ "$(issue_labels)" = "bug needs-clarification" ] && ok "second identical conflict escalates to needs-clarification" || bad "repeat state: $(issue_bucket) $(issue_labels)"
issue_body | grep -q "hit the same conflict twice" && ok "escalation says it is the second identical conflict" || bad "escalation comment: $(issue_body)"
[ "$(markers | wc -l)" -eq 1 ] && ok "escalation adds no second marker" || bad "markers: $(markers)"

# ── 3. a different conflict signature bounces again ─────────────────────────
setup
sibling_clash src/a.sh
run_own true >/dev/null
[ "$(issue_labels)" = "bug working" ] || bad "first bounce state: $(issue_labels)"
# The worker "rebases" but a new sibling change now clashes on b.sh as well.
sibling_clash src/b.sh
OUT=$(run_own true); RC=$?
[ "$RC" -eq 1 ] && [ "$(issue_bucket)" = working ] && [ "$(issue_labels)" = "bug working" ] && ok "a different conflict sig bounces again" || bad "second sig state: rc=$RC $(issue_bucket) $(issue_labels): $OUT"
[ "$(markers | wc -l)" -eq 2 ] && ok "each bounce leaves its own marker" || bad "markers: $(markers)"

# ── 4. gate failure: bounced, failing suites listed, marker keyed on them ──
setup
BEFORE=$(git --git-dir="$TMP/origin.git" rev-parse master)
OUT=$(run_own "$(suite_gate test_alpha.sh)"); RC=$?
[ "$RC" -eq 2 ] && ok "gate failure exits 2" || bad "gate rc=$RC: $OUT"
[ "$(git --git-dir="$TMP/origin.git" rev-parse master)" = "$BEFORE" ] && ok "gate failure pushed nothing" || bad "master moved"
[ "$(issue_bucket)" = working ] && [ "$(issue_labels)" = "bug working" ] && ok "gate failure: working, not needs-clarification" || bad "gate state: $(issue_bucket) $(issue_labels)"
issue_body | grep -q '^- `test_alpha.sh`$' && ok "gate comment lists the failing suite" || bad "suite missing: $(issue_body)"
issue_body | grep -q "this change broke it" && ok "gate comment carries the verdict" || bad "verdict missing"
WANT_SIG=$(printf 'test_alpha.sh' | sha1)
markers | tail -1 | grep -q "kind=gate .* sig=${WANT_SIG} -->" && ok "gate marker keyed on the sorted failing-suite names" || bad "gate marker: $(markers)"

# a different failing suite bounces again; the same one again escalates
OUT=$(run_own "$(suite_gate test_beta.sh)"); RC=$?
[ "$RC" -eq 2 ] && [ "$(issue_labels)" = "bug working" ] && ok "a different gate sig bounces again" || bad "beta state: rc=$RC $(issue_labels)"
OUT=$(run_own "$(suite_gate test_beta.sh)"); RC=$?
[ "$RC" -eq 2 ] && [ "$(issue_bucket)" = blocked ] && [ "$(issue_labels)" = "bug needs-clarification" ] && ok "second identical gate bounce escalates" || bad "repeat gate state: rc=$RC $(issue_bucket) $(issue_labels)"
issue_body | grep -q "second identical gate bounce" && ok "gate escalation says why" || bad "gate escalation comment: $(issue_body)"

# a conflict after a gate bounce with the same items is a different kind: bounces
setup
run_own "$(suite_gate test_alpha.sh)" >/dev/null
sibling_clash src/a.sh
run_own true >/dev/null
[ "$(issue_labels)" = "bug working" ] && ok "kind is part of the identity: gate then conflict bounces" || bad "kind identity: $(issue_labels)"

# ── 5. other pre-push failures still escalate ───────────────────────────────
setup
OUT=$(FEATURE=feature/does-not-exist run_own true); RC=$?
[ "$RC" -eq 1 ] && [ "$(issue_bucket)" = blocked ] && [ "$(issue_labels)" = "bug needs-clarification" ] && ok "unresolvable ref still escalates" || bad "unresolvable ref: rc=$RC $(issue_bucket) $(issue_labels): $OUT"
[ -z "$(markers)" ] && ok "unresolvable ref leaves no bounce marker" || bad "marker on escalation: $(markers)"

setup
chmod -R a-w "$TMP/origin.git/refs" 2>/dev/null
# git push fails; the API fallback has no GitHub remote, so publication fails.
OUT=$(run_own true); RC=$?
chmod -R u+w "$TMP/origin.git/refs" 2>/dev/null
if [ "$(id -u)" = 0 ]; then
  ok "publish failure (skipped: root ignores read-only refs)"
else
  [ "$RC" -eq 1 ] && [ "$(issue_bucket)" = blocked ] && [ "$(issue_labels)" = "bug needs-clarification" ] && ok "publish failure still escalates" || bad "publish failure: rc=$RC $(issue_bucket) $(issue_labels): $OUT"
  [ -z "$(markers)" ] && ok "publish failure leaves no bounce marker" || bad "marker on publish failure: $(markers)"
fi

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
