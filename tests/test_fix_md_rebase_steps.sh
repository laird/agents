#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_fix_md_rebase_steps.sh — /fix rebases early and often, and trial-rebases
# at every landing site before its review check (#222, part of #183).
#
# Workers used to branch once and integrate only in the merge job, 10-40 minutes
# later, by which time master had moved 5-10 commits: 8 merge conflicts and 22 push
# retries in a day on agents-ui. Structure: both fix.md copies carry the guidance and
# a trial rebase before each of the 3 review-record checks. Behaviour: the real block,
# extracted from fix.md, rebases a branch that is behind and exits 2 on a conflict.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

for f in plugins/autocoder/commands/fix.md .agent/workflows/fix.md; do
  P="$ROOT/$f"
  grep -q 'Rebase early and often (#222)' "$P" && ok "$f: rebase-early guidance" || bad "$f: no rebase-early guidance"
  grep -q 'Order: trial-rebase first, then review (#222)' "$P" && ok "$f: the review gate says rebase first" || bad "$f: review gate does not say rebase first"
  # Each review-record check must be preceded (within its block) by a trial rebase.
  python3 - "$P" <<'PY' && ok "$f: every landing site trial-rebases before its review check" || bad "$f: a landing site lacks a trial rebase before its review check"
import re, sys
s = open(sys.argv[1]).read()
checks = [m.start() for m in re.finditer(r'REVIEW_FILE="\$\(git rev-parse --git-common-dir\)/autocoder-review-\$\{(ISSUE|ENHANCE)_NUM\}\.md"\n\s*if ! grep -qx "Reviewed-HEAD', s)]
ok = len(checks) == 3
for c in checks:
    window = s[max(0, c - 1500):c]
    ok = ok and "# Trial rebase (#222)" in window and re.search(r'^\s*if ! git rebase "', window, re.M) is not None
sys.exit(0 if ok else 1)
PY
done

# ── Behaviour: run the real (Claude) block against a scratch repo ─────────────
BLOCK=$(python3 - "$ROOT/plugins/autocoder/commands/fix.md" <<'PY'
import sys
s = open(sys.argv[1]).read()
i = s.index("# Trial rebase (#222)")
j = s.index("# Pre-landing review gate (#147, #166)", i)
print(s[i:j])
PY
)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
g() { git -c user.email=t@example.com -c user.name=T "$@"; }
setup() {
  rm -rf "$TMP/o.git" "$TMP/w" "$TMP/s"
  git init -q --bare -b master "$TMP/o.git"
  g clone -q "$TMP/o.git" "$TMP/w" 2>/dev/null; cd "$TMP/w" || exit 1
  echo base > a; echo base > b; g add .; g commit -qm base; g push -q origin HEAD:master
  g checkout -q -b feature/issue-9
  g clone -q "$TMP/o.git" "$TMP/s" 2>/dev/null
}
run_block() { (cd "$TMP/w" && INTEGRATION_BRANCH=master ISSUE_NUM=9 bash -c "$BLOCK" 2>&1); }

setup; echo mine > a; g commit -qam mine
(cd "$TMP/s" && echo theirs > b && g commit -qam theirs && g push -q origin HEAD:master)
OUT=$(run_block); RC=$?
[ "$RC" -eq 0 ] && ok "clean case: block exits 0" || bad "clean case rc=$RC: $OUT"
git -C "$TMP/w" merge-base --is-ancestor origin/master HEAD && ok "clean case: branch now sits on the new master tip" || bad "clean case: not rebased"
[ "$(git -C "$TMP/w" rev-list --merges origin/master..HEAD | wc -l)" -eq 0 ] && ok "clean case: linear, no merge commit" || bad "clean case: merge commit"

setup; echo mine > a; g commit -qam mine
(cd "$TMP/s" && echo theirs > a && g commit -qam theirs && g push -q origin HEAD:master)
OUT=$(run_block); RC=$?
[ "$RC" -eq 2 ] && ok "conflict: block exits 2" || bad "conflict rc=$RC"
git -C "$TMP/w" rebase --abort 2>/dev/null
OUT2=$(cd "$TMP/w" && ISSUE_NUM=9 bash -c "unset INTEGRATION_BRANCH; $BLOCK" 2>&1)
printf '%s\n' "$OUT2" | grep -q 'INTEGRATION_BRANCH unset' && ok "unset INTEGRATION_BRANCH fails clearly, not as a conflict" || bad "unset branch: $OUT2"
printf '%s\n' "$OUT" | grep -qx 'a' && ok "conflict: lists the conflicting file" || bad "conflict output: $OUT"
git -C "$TMP/w" rebase --abort 2>/dev/null

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
