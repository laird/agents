#!/bin/bash
# tests/test_merge_worktree_cross_device.sh — pins #1967: the throwaway
# isolation worktree merge-to-integration.sh creates (#1821) must end up with
# a COMPLETE node_modules and software-factory/*/dist even when `cp -al`
# (hardlink) fails, as it always does across a filesystem boundary (repo on
# ext4, $TMPDIR on tmpfs is a real, reproducible dev-box configuration).
#
# THREE COMPOUNDING BUGS, all pinned here:
#   1. `cp -al SRC DST 2>/dev/null || true` on a cross-device failure fails
#      per-file with "Invalid cross-device link" but still exits the loop
#      "successfully" (the `|| true` swallows it) — leaving DST a tree of
#      empty directory shells and dangling symlinks instead of real content.
#   2. A naive `cp -al || cp -a` fallback still breaks once DST already
#      exists (left behind by bug 1's partial run): `cp -a SRC DST` with an
#      existing DST directory nests one level deeper (DST/$(basename SRC)/...)
#      instead of merging into DST.
#   3. Even with node_modules fixed, software-factory/packages/*/dist must be
#      a REAL copy, never a hardlink — a hardlink shares the inode with the
#      caller's own dist/, and carries the original build's mtime forward
#      into a freshly-checked-out worktree, which check-software-factory-sync
#      then reads as stale relative to the newly-checked-out src/.
#
# This test fakes a cross-device `cp -al` failure with a PATH-shadowing `cp`
# wrapper (no real second filesystem needed) and runs the actual
# merge-to-integration.sh end-to-end through merge-launch.sh, exactly as the
# swarm invokes it.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f /tmp/autocoder-merge-19102.*; rm -rf /tmp/autocoder-merge-worktree-19102; git -C "$TMP/worker" worktree prune 2>/dev/null' EXIT

# ── Fake `cp` that fails exactly the way a cross-device `cp -al` fails: any
#    `-al`/`-la` invocation on a REGULAR FILE errors out; directories and
#    symlinks (which `cp -al` can still "handle" cross-device, since no
#    actual hardlink is needed for those) and every other invocation (`-a`)
#    fall through to the real `cp`. This reproduces bug 1 without needing an
#    actual second filesystem.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/cp" <<'FAKECP'
#!/bin/bash
real_cp=$(command -v -p cp)
args=("$@")
is_al=false
for a in "${args[@]}"; do
  case "$a" in
    -al|-la|-al*) is_al=true ;;
  esac
done
if $is_al; then
  src="${args[-2]}"
  dst="${args[-1]}"
  if [ -f "$src" ] && [ ! -L "$src" ]; then
    echo "cp: cannot create hard link '$dst' to '$src': Invalid cross-device link" >&2
    exit 1
  fi
fi
exec "$real_cp" "$@"
FAKECP
chmod +x "$TMP/fakebin/cp"

# ── Fixture: bare origin + worker checkout with a node_modules tree
#    containing a real file (not just directories) and a software-factory
#    vendored dist/ ────────────────────────────────────────────────────────
git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email "test@example.com"
git config user.name "Test"
git remote add origin "$TMP/origin.git"
export ISSUE_SOURCE=file
echo "base" > README.md
git add README.md
git commit -q -m "initial commit"
git branch -M master
git push -q origin master

git checkout -q -b feature/issue-C
echo "fix-C" > fix-c.txt
git add fix-c.txt
git commit -q -m "Fix issue C"
git push -q -u origin feature/issue-C

# node_modules with a real file at the top level AND nested one level down —
# both must survive the cross-device fallback intact.
mkdir -p node_modules/.bin
echo '#!/bin/sh' > node_modules/.bin/tsx
echo 'echo "tsx-stub-ran"' >> node_modules/.bin/tsx
chmod +x node_modules/.bin/tsx
mkdir -p node_modules/some-pkg
echo '{"name":"some-pkg"}' > node_modules/some-pkg/package.json

# software-factory/packages/*/dist — must be a real copy, never a hardlink.
mkdir -p software-factory/packages/widget/dist
echo 'module.exports = {};' > software-factory/packages/widget/dist/index.js

FEATURE_C_SHA=$(git rev-parse HEAD)

# ── Run the real merge-to-integration.sh (via merge-launch.sh, exactly as
#    the swarm does) with the fake cross-device-failing `cp` shadowing the
#    real one on PATH. --test-cmd asserts the isolated worktree actually has
#    working, complete copies — not just "the merge didn't crash".
LAUNCH_OUT=$(PATH="$TMP/fakebin:$PATH" bash "$SCRIPT_DIR/merge-launch.sh" \
  --feature feature/issue-C --issue 19102 --integration master \
  --test-cmd '
    set -e
    [ "$(./node_modules/.bin/tsx 2>&1)" = "tsx-stub-ran" ]
    [ "$(cat node_modules/some-pkg/package.json)" = "{\"name\":\"some-pkg\"}" ]
    [ "$(cat software-factory/packages/widget/dist/index.js)" = "module.exports = {};" ]
  ' 2>&1)
LAUNCH_RC=$?
[ "$LAUNCH_RC" -eq 0 ] && ok "merge-launch.sh launched C's merge" || bad "merge-launch.sh failed to launch (rc=$LAUNCH_RC): $LAUNCH_OUT"

DEADLINE=$((SECONDS + 30))
while [ -f /tmp/autocoder-merge-19102.pid ] && [ $SECONDS -lt $DEADLINE ]; do
  OLD_PID=$(cat /tmp/autocoder-merge-19102.pid 2>/dev/null || echo "")
  [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null || break
  sleep 1
done

MERGE_LOG=$(cat /tmp/autocoder-merge-19102.log 2>/dev/null || echo "<no log>")
MERGE_EXIT=$(cat /tmp/autocoder-merge-19102.exit 2>/dev/null || echo "<no exit code — still running?>")

[ "$MERGE_EXIT" = "0" ] && \
  ok "merge succeeded with a working node_modules/.bin/tsx, a nested node_modules package, and dist/ under a simulated cross-device cp -al failure" || \
  bad "merge failed under simulated cross-device cp -al (exit=$MERGE_EXIT) — log:
$MERGE_LOG"

git fetch -q origin master
git cat-file -e "origin/master:fix-c.txt" 2>/dev/null && ok "origin/master contains fix-C's file" \
  || bad "origin/master is missing fix-c.txt — merge did not land"

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
