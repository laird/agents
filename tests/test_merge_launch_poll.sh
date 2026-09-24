#!/bin/bash
# tests/test_merge_launch_poll.sh — pin #1693's fix: merge-to-integration.sh
# must never run inside a single foreground call. It legitimately takes
# 25-30 minutes, and agent harnesses kill a foreground Bash-tool call at a
# ~2-minute default — a guaranteed failure, not a flake, plus (depending on
# how the kill propagates) either a torn-down merge or an orphaned gate
# subtree (reparented to init) that nothing ever reaps.
#
# merge-launch.sh must:
#   - return almost immediately (well under the 2-minute ceiling) regardless
#     of how long the underlying merge takes
#   - detach the merge into its own session (setsid) so killing the poller
#     that checks on it can never take the merge down too
#   - refuse to start a second job for the same issue while one is running
# merge-poll.sh must:
#   - never block longer than its own --wait slice
#   - report "still running" (75) without reaping state while the job is live
#   - pass through the underlying merge-to-integration.sh exit code (0/1/2)
#     once it finishes, and reap state so a later poll reports "no job" (64)
#
# And the command docs (fix.md) must call merge-launch.sh / merge-poll.sh at
# every merge site, never merge-to-integration.sh directly — that direct call
# is exactly the regression this test exists to catch.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f /tmp/autocoder-merge-19001.* /tmp/autocoder-merge-19002.* /tmp/autocoder-merge-19003.* /tmp/autocoder-merge-19004.* /tmp/autocoder-merge-19005.* /tmp/autocoder-merge-19006.* /tmp/autocoder-merge-19007.* /tmp/autocoder-merge-19008.*' EXIT

mkdir -p "$TMP/fakebin"
cp "$SCRIPT_DIR/merge-launch.sh" "$TMP/fakebin/"
cp "$SCRIPT_DIR/merge-poll.sh" "$TMP/fakebin/"

# ── Fixture 1: a slow, successful fake merge (issue #19001) ─────────────────
cat > "$TMP/fakebin/merge-to-integration.sh" <<'FAKE'
#!/bin/bash
echo "fake merge running: $*"
sleep 4
echo "fake merge succeeded"
exit 0
FAKE
chmod +x "$TMP/fakebin/merge-to-integration.sh"

START=$(date +%s 2>/dev/null || echo 0)
LAUNCH_OUT=$(bash "$TMP/fakebin/merge-launch.sh" --feature feature/issue-19001 --issue 19001 --integration master --test-cmd "true" 2>&1)
LAUNCH_RC=$?
END=$(date +%s 2>/dev/null || echo 0)
ELAPSED=$((END - START))

[ "$LAUNCH_RC" -eq 0 ] && ok "merge-launch.sh exits 0 on launch" || bad "merge-launch.sh exit code on launch (got $LAUNCH_RC)"
[ "$ELAPSED" -le 3 ] && ok "merge-launch.sh returns fast, not waiting for the 4s merge (${ELAPSED}s)" \
  || bad "merge-launch.sh blocked for ${ELAPSED}s — defeats the whole point of #1693"

[ -f /tmp/autocoder-merge-19001.pid ] && ok "pidfile written" || bad "pidfile missing"

DUP_OUT=$(bash "$TMP/fakebin/merge-launch.sh" --feature feature/issue-19001 --issue 19001 --integration master --test-cmd "true" 2>&1)
echo "$DUP_OUT" | grep -qi "already running" && ok "duplicate launch refused while job is in flight" \
  || bad "duplicate launch not detected — would double the gate cost (secondary ask in #1693)"

POLL1_OUT=$(bash "$TMP/fakebin/merge-poll.sh" --issue 19001 --wait 1 2>&1); POLL1_RC=$?
[ "$POLL1_RC" -eq 75 ] && ok "merge-poll.sh reports 75 (still running) mid-flight" \
  || bad "merge-poll.sh exit code while running (got $POLL1_RC)"
[ -f /tmp/autocoder-merge-19001.pid ] && ok "poll while running does not reap state" || bad "poll while running reaped state early"

POLL2_OUT=$(bash "$TMP/fakebin/merge-poll.sh" --issue 19001 --wait 5 2>&1); POLL2_RC=$?
[ "$POLL2_RC" -eq 0 ] && ok "merge-poll.sh passes through exit 0 on success" \
  || bad "merge-poll.sh exit code on success (got $POLL2_RC)"
echo "$POLL2_OUT" | grep -q "fake merge succeeded" && ok "merge-poll.sh surfaces the merge's own log output" \
  || bad "merge-poll.sh did not surface log tail"
[ -f /tmp/autocoder-merge-19001.pid ] && bad "poll after completion left state behind (should reap)" \
  || ok "poll after completion reaps pid/exit/log state"

POLL3_RC=0
bash "$TMP/fakebin/merge-poll.sh" --issue 19001 --wait 1 >/dev/null 2>&1 || POLL3_RC=$?
[ "$POLL3_RC" -eq 64 ] && ok "polling a reaped/never-launched issue reports 64" \
  || bad "poll after reap exit code (got $POLL3_RC)"

# ── Fixture 2: a fake merge that fails the combined-tree test re-run ────────
cat > "$TMP/fakebin/merge-to-integration.sh" <<'FAKE'
#!/bin/bash
echo "fake merge: combined-tree tests fail"
sleep 1
exit 2
FAKE
chmod +x "$TMP/fakebin/merge-to-integration.sh"
bash "$TMP/fakebin/merge-launch.sh" --feature feature/issue-19002 --issue 19002 --integration master --test-cmd "true" >/dev/null 2>&1
RC=0
bash "$TMP/fakebin/merge-poll.sh" --issue 19002 --wait 3 >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 2 ] && ok "merge-poll.sh passes through exit 2 (test failure on combined tree)" \
  || bad "merge-poll.sh exit code on test failure (got $RC)"

# ── Fixture 3: killing the POLLER must not kill the detached merge ──────────
cat > "$TMP/fakebin/merge-to-integration.sh" <<'FAKE'
#!/bin/bash
sleep 6
echo done > /dev/null
exit 0
FAKE
chmod +x "$TMP/fakebin/merge-to-integration.sh"
bash "$TMP/fakebin/merge-launch.sh" --feature feature/issue-19003 --issue 19003 --integration master --test-cmd "true" >/dev/null 2>&1
MPID=$(cat /tmp/autocoder-merge-19003.pid 2>/dev/null)

( bash "$TMP/fakebin/merge-poll.sh" --issue 19003 --wait 20 >/dev/null 2>&1 & POLLER=$!; sleep 1; kill -9 -- -"$POLLER" 2>/dev/null; kill -9 "$POLLER" 2>/dev/null )
sleep 0.5
if [ -n "$MPID" ] && kill -0 "$MPID" 2>/dev/null; then
  ok "detached merge survives a killed poller (pid $MPID still alive)"
else
  bad "detached merge died when its poller was killed — the exact orphan/kill bug #1693 reports"
fi
# Let it finish naturally so it doesn't leak past the test.
for _ in 1 2 3 4 5 6 7 8; do kill -0 "$MPID" 2>/dev/null || break; sleep 1; done
kill -0 "$MPID" 2>/dev/null && kill -9 "$MPID" 2>/dev/null || ok "detached merge for #19003 ran to completion on its own"
rm -f /tmp/autocoder-merge-19003.*

# ── Fixture 4/5 shared setup: a real git repo with a real "origin" remote.
# Both the gate-command check and the (#2998) --integration resolution call
# real git plumbing (`git rev-parse`, `git ls-remote`) that needs an actual
# repository to resolve against, not a bare directory with no .git at all.
cat > "$TMP/fakebin/merge-to-integration.sh" <<'FAKE'
#!/bin/bash
echo "fake merge running: $*"
exit 0
FAKE
chmod +x "$TMP/fakebin/merge-to-integration.sh"

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/gaterepo"
(
  cd "$TMP/gaterepo" || exit 1
  git config user.email "test@example.com"
  git config user.name "Test"
  git remote add origin "$TMP/origin.git"
  echo base > README.md
  git add README.md
  git commit -q -m "initial commit"
  git branch -M master
  git push -q origin master
  git push -q origin master:main
  git checkout -q -b otherbranch
  git push -q -u origin otherbranch
  git checkout -q master
) || { bad "gate-command/integration-branch fixture repo setup"; }

# A second repo sharing the same origin but with neither
# scripts/check-gate-command.sh nor a CLAUDE.md — the "this plugin's
# conventions don't apply here" case for both fixtures.
git init -q "$TMP/norepo"
(
  cd "$TMP/norepo" || exit 1
  git config user.email "test@example.com"
  git config user.name "Test"
  git remote add origin "$TMP/origin.git"
  git fetch -q origin
  git checkout -q master
)

GATEREPO="$TMP/gaterepo"
mkdir -p "$GATEREPO/scripts"
cat > "$GATEREPO/scripts/check-gate-command.sh" <<'FAKE'
#!/bin/bash
if [ "$1" = "--extract" ]; then
  echo "echo canonical-cmd"
  exit 0
fi
if [ "$1" = "echo canonical-cmd" ] || [ "$1" = "echo good-cmd" ]; then
  echo "check-gate-command: OK" >&2
  exit 0
fi
echo "check-gate-command: MISMATCH" >&2
exit 1
FAKE
chmod +x "$GATEREPO/scripts/check-gate-command.sh"

# No --test-cmd, extractor succeeds -> defaults to the extracted command.
( cd "$GATEREPO" && bash "$TMP/fakebin/merge-launch.sh" --feature HEAD --issue 19004 --integration master ) >/tmp/out19004.txt 2>&1
RC4=$?
sleep 0.3
[ "$RC4" -eq 0 ] && ok "gate-command: launches when --test-cmd omitted and --extract succeeds" \
  || bad "gate-command: refused a launch --extract could have satisfied (rc $RC4)"
grep -q "echo canonical-cmd" /tmp/autocoder-merge-19004.log 2>/dev/null && ok "gate-command: defaulted --test-cmd is the extracted command" \
  || bad "gate-command: extracted command did not reach merge-to-integration.sh"

# --test-cmd supplied and it matches -> launches with it unchanged.
( cd "$GATEREPO" && bash "$TMP/fakebin/merge-launch.sh" --feature HEAD --issue 19005 --integration master --test-cmd "echo good-cmd" ) >/tmp/out19005.txt 2>&1
RC5=$?
sleep 0.3
[ "$RC5" -eq 0 ] && ok "gate-command: launches when supplied --test-cmd validates" \
  || bad "gate-command: refused a --test-cmd the validator accepted (rc $RC5)"
grep -q "echo good-cmd" /tmp/autocoder-merge-19005.log 2>/dev/null && ok "gate-command: validated --test-cmd passed through unchanged" \
  || bad "gate-command: validated --test-cmd did not reach merge-to-integration.sh"

# --test-cmd supplied and it does NOT match -> refused, nothing launched.
( cd "$GATEREPO" && bash "$TMP/fakebin/merge-launch.sh" --feature HEAD --issue 19006 --integration master --test-cmd "echo bad-cmd" ) >/tmp/out19006.txt 2>&1
RC6=$?
[ "$RC6" -ne 0 ] && ok "gate-command: refuses a --test-cmd the validator rejects (rc $RC6)" \
  || bad "gate-command: launched anyway with a mismatched --test-cmd — the #2814 hole this closes"
[ -f /tmp/autocoder-merge-19006.pid ] && bad "gate-command: pidfile written despite refusal" \
  || ok "gate-command: no pidfile/job started on refusal"

# No --test-cmd and --extract itself fails -> refused (#2992's warn-and-push residue).
cat > "$GATEREPO/scripts/check-gate-command.sh" <<'FAKE'
#!/bin/bash
exit 2
FAKE
chmod +x "$GATEREPO/scripts/check-gate-command.sh"
( cd "$GATEREPO" && bash "$TMP/fakebin/merge-launch.sh" --feature HEAD --issue 19007 --integration master ) >/tmp/out19007.txt 2>&1
RC7=$?
[ "$RC7" -ne 0 ] && ok "gate-command: refuses when --test-cmd omitted and --extract fails" \
  || bad "gate-command: launched with no regression suite when --extract failed (#2992 residue)"
[ -f /tmp/autocoder-merge-19007.pid ] && bad "gate-command: pidfile written despite --extract failure" \
  || ok "gate-command: no pidfile/job started when --extract failed"

# A repo with no scripts/check-gate-command.sh at all is a pure no-op.
( cd "$TMP/norepo" && bash "$TMP/fakebin/merge-launch.sh" --feature HEAD --issue 19008 --integration master ) >/tmp/out19008.txt 2>&1
RC8=$?
sleep 0.3
[ "$RC8" -eq 0 ] && ok "gate-command: no-op (launches normally) when the repo has no check-gate-command.sh" \
  || bad "gate-command: a repo with no extractor should be unaffected (rc $RC8)"
rm -f /tmp/autocoder-merge-19004.* /tmp/autocoder-merge-19005.* /tmp/autocoder-merge-19006.* /tmp/autocoder-merge-19007.* /tmp/autocoder-merge-19008.*
rm -f /tmp/out19004.txt /tmp/out19005.txt /tmp/out19006.txt /tmp/out19007.txt /tmp/out19008.txt

# ── Fixture 5: --integration resolution from CLAUDE.md (#2998, second case) ─
# merge-launch.sh must derive --integration from a calling repo's CLAUDE.md
# "### Integration Branch" block when none was supplied, fall back to "main"
# only (loudly) when that block cannot be read, let an explicit --integration
# win regardless, and refuse before launching anything if the resolved branch
# does not exist on the remote — catching what would otherwise fail only
# after a full worktree checkout inside merge-to-integration.sh.
# Fixture 4's last case left $GATEREPO/scripts/check-gate-command.sh
# unconditionally failing (its own "--extract fails" test) — restore a
# working one so the --test-cmd values below validate as intended here.
cat > "$GATEREPO/scripts/check-gate-command.sh" <<'FAKE'
#!/bin/bash
if [ "$1" = "--extract" ]; then
  echo "echo canonical-cmd"
  exit 0
fi
if [ "$1" = "echo canonical-cmd" ] || [ "$1" = "echo good-cmd" ]; then
  echo "check-gate-command: OK" >&2
  exit 0
fi
echo "check-gate-command: MISMATCH" >&2
exit 1
FAKE
chmod +x "$GATEREPO/scripts/check-gate-command.sh"

cat > "$GATEREPO/CLAUDE.md" <<'FAKE'
### Integration Branch
```
master
```
FAKE

# No --integration supplied, CLAUDE.md declares master (which exists on
# origin) -> resolves to master and launches.
OUT19009=$( ( cd "$GATEREPO" && bash "$TMP/fakebin/merge-launch.sh" --feature HEAD --issue 19009 --test-cmd "echo good-cmd" ) 2>&1 )
RC9=$?
sleep 0.3
echo "$OUT19009" | grep -q "resolved to 'master'" && ok "integration-branch: prints the resolved value when derived from CLAUDE.md" \
  || bad "integration-branch: missing resolved-value message"
[ "$RC9" -eq 0 ] && ok "integration-branch: launches when derived from CLAUDE.md and the branch exists" \
  || bad "integration-branch: refused a derivation it should have accepted (rc $RC9)"
grep -q -- "--integration master" /tmp/autocoder-merge-19009.log 2>/dev/null && ok "integration-branch: derived value ('master') reached merge-to-integration.sh" \
  || bad "integration-branch: derived value did not reach merge-to-integration.sh"

# No --integration supplied, no CLAUDE.md at all -> falls back to "main"
# (which also exists on origin) with a loud stderr warning, but still launches.
OUT19010=$( ( cd "$TMP/norepo" && bash "$TMP/fakebin/merge-launch.sh" --feature HEAD --issue 19010 ) 2>&1 )
RC10=$?
sleep 0.3
echo "$OUT19010" | grep -q "falling back to 'main'" && ok "integration-branch: warns loudly when CLAUDE.md cannot be read" \
  || bad "integration-branch: silent fallback to main — the exact trap CLAUDE.md warns about"
[ "$RC10" -eq 0 ] && ok "integration-branch: still launches on the main fallback when main exists on the remote" \
  || bad "integration-branch: fallback path refused unexpectedly (rc $RC10)"
grep -q -- "--integration main" /tmp/autocoder-merge-19010.log 2>/dev/null && ok "integration-branch: fallback value ('main') reached merge-to-integration.sh" \
  || bad "integration-branch: fallback value did not reach merge-to-integration.sh"

# An explicit --integration always wins over CLAUDE.md's declared value.
OUT19011=$( ( cd "$GATEREPO" && bash "$TMP/fakebin/merge-launch.sh" --feature HEAD --issue 19011 --integration otherbranch --test-cmd "echo good-cmd" ) 2>&1 )
RC11=$?
sleep 0.3
echo "$OUT19011" | grep -q "resolved to" && bad "integration-branch: printed a derivation message despite an explicit --integration" \
  || ok "integration-branch: explicit --integration bypasses CLAUDE.md derivation entirely"
[ "$RC11" -eq 0 ] && ok "integration-branch: launches with an explicit --integration" \
  || bad "integration-branch: explicit --integration unexpectedly refused (rc $RC11)"
grep -q -- "--integration otherbranch" /tmp/autocoder-merge-19011.log 2>/dev/null && ok "integration-branch: explicit value ('otherbranch') wins over CLAUDE.md's 'master'" \
  || bad "integration-branch: explicit --integration did not win over CLAUDE.md"

# The resolved branch must exist on the remote BEFORE anything is launched —
# a nonexistent branch would otherwise fail only after a full worktree
# checkout inside merge-to-integration.sh (the wasted-checkout bug #2998
# reports).
OUT19012=$( ( cd "$GATEREPO" && bash "$TMP/fakebin/merge-launch.sh" --feature HEAD --issue 19012 --integration does-not-exist-anywhere --test-cmd "echo good-cmd" ) 2>&1 )
RC12=$?
[ "$RC12" -ne 0 ] && ok "integration-branch: refuses a branch absent from the remote (rc $RC12)" \
  || bad "integration-branch: launched with a nonexistent integration branch"
[ -f /tmp/autocoder-merge-19012.pid ] && bad "integration-branch: pidfile written despite a nonexistent remote branch" \
  || ok "integration-branch: no pidfile/job started — refused before any worktree checkout could be wasted"
[ -f /tmp/autocoder-merge-19012.log ] && [ -s /tmp/autocoder-merge-19012.log ] && bad "integration-branch: merge-to-integration.sh ran despite the missing branch" \
  || ok "integration-branch: merge-to-integration.sh never ran"

rm -f /tmp/autocoder-merge-19009.* /tmp/autocoder-merge-19010.* /tmp/autocoder-merge-19011.* /tmp/autocoder-merge-19012.*

# ── Docs: fix.md must launch+poll at every merge site, never call
#          merge-to-integration.sh directly ──────────────────────────────────
FIXMD="$ROOT/plugins/autocoder/commands/fix.md"
if [ -f "$FIXMD" ]; then
  ok "plugins/autocoder/commands/fix.md exists"
  DIRECT_CALLS=$(grep -c '"\${SCRIPT_DIR}/merge-to-integration\.sh"' "$FIXMD")
  [ "$DIRECT_CALLS" -eq 0 ] && ok "fix.md never invokes merge-to-integration.sh directly" \
    || bad "fix.md still calls merge-to-integration.sh directly at $DIRECT_CALLS site(s) — the #1693 regression"

  LAUNCH_CALLS=$(grep -c '"\${SCRIPT_DIR}/merge-launch\.sh"' "$FIXMD")
  POLL_CALLS=$(grep -c '"\${SCRIPT_DIR}/merge-poll\.sh"' "$FIXMD")
  [ "$LAUNCH_CALLS" -ge 3 ] && ok "fix.md launches the merge at all 3 sites (found $LAUNCH_CALLS)" \
    || bad "fix.md missing merge-launch.sh at one or more sites (found $LAUNCH_CALLS, want >= 3)"
  [ "$POLL_CALLS" -ge 3 ] && ok "fix.md polls the merge at all 3 sites (found $POLL_CALLS)" \
    || bad "fix.md missing merge-poll.sh at one or more sites (found $POLL_CALLS, want >= 3)"
else
  bad "plugins/autocoder/commands/fix.md exists"
fi

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
