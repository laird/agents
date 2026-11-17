#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_suite_git_env.sh — run-shell-suite.sh drops an inherited GIT_DIR /
# GIT_WORK_TREE, so a test's throwaway repo, not the repo those point at, decides
# which issue backend issue-config.sh picks (#257).
#
# Runs a copy of the suite runner over one probe test, in private temp repos.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The repo an inherited GIT_DIR points at: its config selects github.
git init -q "$TMP/real"
echo '{"issueSource": "github"}' > "$TMP/real/.autocoder.json"

# A suite tree holding the runner and one probe test. The probe builds its own
# file-backend repo, sources issue-config.sh there and reports what it picked.
mkdir -p "$TMP/suite/tests"
cp "$ROOT/tests/run-shell-suite.sh" "$TMP/suite/tests/"
cat > "$TMP/suite/tests/test_probe.sh" <<PROBE
#!/bin/bash
echo "GIT_DIR=\${GIT_DIR-unset} GIT_WORK_TREE=\${GIT_WORK_TREE-unset}"
cd "\$(mktemp -d "$TMP/probe.XXXXXX")" || exit 1
git init -q .
echo '{"issueSource": "file"}' > .autocoder.json
unset ISSUE_SOURCE ISSUE_BACKEND ISSUE_DIR
source "$ROOT/plugins/autocoder/scripts/issue-config.sh"
echo "ISSUE_SOURCE=\$ISSUE_SOURCE"
[ "\$ISSUE_SOURCE" = file ]
PROBE

OUT=$(GIT_DIR="$TMP/real/.git" GIT_WORK_TREE="$TMP/real" bash "$TMP/suite/tests/run-shell-suite.sh" 2>&1)
grep -q '^PASS  test_probe.sh' <<<"$OUT" \
  && ok "with GIT_DIR/GIT_WORK_TREE inherited, the probe's own repo picks the backend" \
  || bad "probe failed under an inherited GIT_DIR: $OUT"

# The probe really does fail when the variables reach it: proves the check above
# is not passing for some other reason.
OUT=$(cd "$TMP/suite" && GIT_DIR="$TMP/real/.git" GIT_WORK_TREE="$TMP/real" bash tests/test_probe.sh 2>&1)
grep -q 'ISSUE_SOURCE=github' <<<"$OUT" \
  && ok "run outside the suite, the inherited GIT_DIR sends the probe to the other repo's config" \
  || bad "control run did not reproduce the leak: $OUT"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
