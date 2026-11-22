#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # never write the real event logs
# tests/test_merge_infrastructure_refusal.sh — the "merged onto a red base" path of
# merge-to-integration.sh needs a real test verdict on both trees:
#   - a gate stage the HOST stopped (a disk-space check over its threshold, ENOSPC, a
#     missing tool, a stage reporting INFRASTRUCTURE) aborts the merge with exit 3 before
#     the base is gated, names the line that decided it, pushes nothing and leaves no fail
#     in the gate cache for that tree;
#   - the same refusal on the base run (the integrated tree failed as a test, then the host
#     could not run the base) aborts the same way after both runs;
#   - a red base lands only when both runs name the SAME failures; a failure the integrated
#     tree names alone is this change's (exit 2); runs that name nothing cannot be compared
#     (exit 2); nothing is pushed in either case;
#   - under --own-issue the refusal escalates with a reason that opens with INFRASTRUCTURE;
#   - AUTOCODER_GATE_INFRA_PATTERNS lets a repo add its own stage names;
#   - the REBASE step reads the same patterns: a rebase the host stopped (ENOSPC) is retried
#     once and then refused as INFRASTRUCTURE (exit 3), never escalated as a conflict.
#
# WHY: on 2026-11-16 a disk-space stage at exactly its threshold failed the integrated run
# and the base run the same way; the script read "fails on both" as "the base is red
# independent of this change" and pushed a branch no test stage had run on.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/plugins/autocoder/scripts"
MTI="$SCRIPT_DIR/merge-to-integration.sh"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ISSUE=19301

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE AUTOCODER_GREEN_REF AUTOCODER_GATE_INFRA_PATTERNS AUTOCODER_GATE_FAILURE_PATTERNS
# shellcheck source=../plugins/autocoder/scripts/gate-cache-fns.sh
source "$SCRIPT_DIR/gate-cache-fns.sh"

# Bare origin with a green ref (so the merge-on-red-base relaxation applies), worker on
# feature/code (src/app.sh added), one open issue; "claimed" also claims it for --own-issue.
setup() {
  rm -rf "$TMP/origin.git" "$TMP/worker" "$TMP/gate-cache" "$TMP/issues" "$TMP/gate-runs" "$TMP/disk-runs"
  mkdir -p "$TMP/issues/open" "$TMP/issues/working" "$TMP/issues/blocked" "$TMP/issues/closed"
  printf -- '---\nnumber: %s\ntitle: Infrastructure refusal\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$ISSUE" > "$TMP/issues/open/${ISSUE}.md"
  [ "${1:-}" = claimed ] && python3 "$ISSUES_PY" claim "$ISSUE" >/dev/null
  git init --bare -q "$TMP/origin.git"
  git init -q "$TMP/worker"
  cd "$TMP/worker" || exit 1
  git config user.email t@example.com; git config user.name T
  git remote add origin "$TMP/origin.git"
  echo base > README.md
  git add -A; git commit -q -m init; git branch -M master; git push -q origin master master:master-green
  git fetch -q origin
  git checkout -q -b feature/code master
  mkdir -p src; echo change > src/app.sh
  git add -A; git commit -q -m "fix"
  printf 'Replaced the broken thing.\n' > "$TMP/summary.md"
}

origin_master() { git --git-dir="$TMP/origin.git" rev-parse master; }
gate_runs()     { if [ -f "$TMP/gate-runs" ]; then wc -l < "$TMP/gate-runs"; else echo 0; fi; }
issue_file()    { ls "$TMP"/issues/*/"${ISSUE}.md" 2>/dev/null | head -1; }
issue_bucket()  { basename "$(dirname "$(issue_file)")"; }
issue_body()    { cat "$(issue_file)"; }
issue_labels()  { python3 "$ISSUES_PY" get "$ISSUE" | python3 -c 'import json,sys; print(" ".join(sorted(l["name"] for l in json.load(sys.stdin)["labels"])))'; }
run()           { bash "$MTI" --feature feature/code --issue $ISSUE --integration master --test-cmd "$1" "${@:2}" 2>&1; }

# A stand-in for a repo's first gate stage, scripts/check-disk-space.sh, printing what the
# real one prints at its threshold. Mode `always` fails every run; mode `second` passes the
# first run and fails from the second on (the base run is the one the host refuses).
cat > "$TMP/check-disk-space.sh" <<'STUB'
#!/bin/bash
mode="$1"; counter="$2"
n=$(cat "$counter" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$counter"
if [ "$mode" = always ] || { [ "$mode" = second ] && [ "$n" -ge 2 ]; }; then
  echo "::error::check-disk-space: / is 85% full (>= 85% threshold), only 78G available. A full disk produces failures indistinguishable from real defects -- do not trust any result from this run." >&2
  exit 1
fi
echo "OK: check-disk-space -- / at 61% (threshold 85%)."
STUB
chmod +x "$TMP/check-disk-space.sh"
RECORD='echo "$(git rev-parse HEAD^{tree})" >> '"$TMP"'/gate-runs'
DISK_ALWAYS="bash $TMP/check-disk-space.sh always $TMP/disk-runs"
DISK_SECOND="bash $TMP/check-disk-space.sh second $TMP/disk-runs"
RED='echo "FAIL  tests/app.test.sh > the app"; false'

# ── (a) the disk stage refuses on the integrated tree: abort, no base run, nothing pushed ──
setup
BEFORE=$(origin_master)
OUT=$(run "$RECORD; $DISK_ALWAYS && $RED"); RC=$?
[ "$RC" -eq 3 ] && ok "(a) exit 3 on an infrastructure refusal" || bad "(a) rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "(a) nothing pushed" || bad "(a) master moved: $OUT"
[ "$(gate_runs)" -eq 1 ] && ok "(a) the base was not gated (one gate run)" || bad "(a) gate ran $(gate_runs) time(s); want 1: $OUT"
echo "$OUT" | grep -q "^::error::merge-to-integration: INFRASTRUCTURE -- the gate did not reach a verdict on the integrated tree .*::error::check-disk-space: / is 85% full" && ok "(a) the abort names the stage's own line as the cause" || bad "(a) cause not named: $OUT"
echo "$OUT" | grep -q "relaunch the merge once the host is fixed" && ok "(a) the abort says what to do" || bad "(a) no relaunch advice: $OUT"
echo "$OUT" | grep -q "fails alone too\|merged into" && bad "(a) the run was read as a red base: $OUT" || ok "(a) never read as a red base"
TREE=$(head -1 "$TMP/gate-runs")
gate_cache_get "$TREE" "$RECORD; $DISK_ALWAYS && $RED" >/dev/null 2>&1 && bad "(a) a fail stayed in the gate cache for the refused tree" || ok "(a) no gate-cache record for the refused tree"
echo "$OUT" | grep -q "gate-cache: forgot the record for tree ${TREE:0:8}" && ok "(a) log says the fail record was forgotten" || bad "(a) forget line missing: $OUT"
git -C "$TMP/worker" rev-parse --verify -q feature/code >/dev/null && ok "(a) the feature branch is intact" || bad "(a) feature branch gone"

# ── (b) the integrated tree fails as a test, then the host refuses the base run ─────────
setup
BEFORE=$(origin_master)
OUT=$(run "$RECORD; $DISK_SECOND && $RED"); RC=$?
[ "$RC" -eq 3 ] && ok "(b) exit 3 when the base run is the refused one" || bad "(b) rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "(b) nothing pushed" || bad "(b) master moved: $OUT"
[ "$(gate_runs)" -eq 2 ] && ok "(b) both runs happened" || bad "(b) gate ran $(gate_runs) time(s); want 2: $OUT"
echo "$OUT" | grep -q "^::error::merge-to-integration: INFRASTRUCTURE -- the gate did not reach a verdict on origin/master alone" && ok "(b) the abort names the base run" || bad "(b) base run not named: $OUT"
BASE_TREE=$(tail -1 "$TMP/gate-runs")
gate_cache_get "$BASE_TREE" "$RECORD; $DISK_SECOND && $RED" >/dev/null 2>&1 && bad "(b) a fail stayed in the gate cache for the refused base tree" || ok "(b) no gate-cache record for the refused base tree"
[ "$(gate_cache_get "$(head -1 "$TMP/gate-runs")" "$RECORD; $DISK_SECOND && $RED")" = fail ] && ok "(b) the integrated tree's real fail stays recorded" || bad "(b) integrated fail record missing"

# ── (c) both trees fail naming the same test: a red base, which lands and says what matched ──
setup
OUT=$(run "$RECORD; $RED"); RC=$?
[ "$RC" -eq 0 ] && ok "(c) exit 0 on a red base with the same named failure" || bad "(c) rc=$RC: $OUT"
git --git-dir="$TMP/origin.git" cat-file -e master:src/app.sh 2>/dev/null && ok "(c) fix landed on master" || bad "(c) fix did not land"
echo "$OUT" | grep -q "with the same 1 named failure(s)" && ok "(c) log counts the matched failures" || bad "(c) count line missing: $OUT"
issue_body | grep -q 'both naming the same failure(s): `FAIL  tests/app.test.sh > the app`' && ok "(c) issue comment lists the shared failure" || bad "(c) issue comment lacks the failure: $(issue_body)"

# ── (d) the integrated tree names a failure the base does not: this change's, exit 2 ────
setup
BEFORE=$(origin_master)
OUT=$(run "$RECORD; [ ! -f src/app.sh ] || echo \"FAIL  tests/extra.test.sh > only with the change\"; $RED"); RC=$?
[ "$RC" -eq 2 ] && ok "(d) exit 2 when the failure sets differ" || bad "(d) rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "(d) nothing pushed" || bad "(d) master moved: $OUT"
[ "$(gate_runs)" -eq 2 ] && ok "(d) the base was gated for the comparison" || bad "(d) gate ran $(gate_runs) time(s); want 2"
echo "$OUT" | grep -q "this change only: FAIL  tests/extra.test.sh > only with the change" && ok "(d) the extra failure is attributed to this change" || bad "(d) attribution missing: $OUT"
echo "$OUT" | grep -q "fails alone too\|merged into" && bad "(d) read as a red base: $OUT" || ok "(d) not a red base"

# ── (d') the base names MORE failures than the integrated tree (#326): every failure on
#    the integrated tree fails on the base too, so the change broke nothing; a red base ──
setup
OUT=$(run "$RECORD; [ -f src/app.sh ] || echo \"FAIL  tests/flaky.test.sh > only on the base\"; $RED"); RC=$?
[ "$RC" -eq 0 ] && ok "(d') exit 0 when the base fails a superset" || bad "(d') rc=$RC: $OUT"
git --git-dir="$TMP/origin.git" cat-file -e master:src/app.sh 2>/dev/null && ok "(d') fix landed on master" || bad "(d') fix did not land"
echo "$OUT" | grep -q "base only: FAIL  tests/flaky.test.sh > only on the base" && ok "(d') the base-only failure is listed" || bad "(d') base-only line missing: $OUT"
echo "$OUT" | grep -q "RED-BASE -- .* with all 1 of the integrated tree's named failure(s), and 1 more" && ok "(d') the RED-BASE line counts the extra base failure" || bad "(d') RED-BASE wording: $OUT"
echo "$OUT" | grep -q "so this change broke it\|not the same red base" && bad "(d') refused or blamed: $OUT" || ok "(d') not refused, not blamed"
issue_body | grep -q 'the base alone also named `FAIL  tests/flaky.test.sh > only on the base`' && ok "(d') issue comment names the base-only failure" || bad "(d') issue comment: $(issue_body)"

# ── (e) both trees fail without naming anything: no verdict to compare, exit 2 ──────────
setup
BEFORE=$(origin_master)
OUT=$(run "$RECORD; false"); RC=$?
[ "$RC" -eq 2 ] && ok "(e) exit 2 when no failure is named" || bad "(e) rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "(e) nothing pushed" || bad "(e) master moved: $OUT"
echo "$OUT" | grep -q "named no failing test or check on the integrated tree" && ok "(e) refusal says nothing was named" || bad "(e) refusal wrong: $OUT"

# ── (f) --own-issue: the refusal escalates with an INFRASTRUCTURE reason, never parks ──
setup claimed
OUT=$(run "$RECORD; $DISK_ALWAYS && $RED" --own-issue --summary-file "$TMP/summary.md"); RC=$?
[ "$RC" -eq 3 ] && ok "(f) exit 3 under --own-issue" || bad "(f) rc=$RC: $OUT"
[ "$(issue_bucket)" = blocked ] && ok "(f) issue escalated (blocked bucket)" || bad "(f) issue in $(issue_bucket): $OUT"
echo "$(issue_labels)" | grep -q needs-clarification && ok "(f) needs-clarification set" || bad "(f) labels: $(issue_labels)"
issue_body | grep -q "INFRASTRUCTURE: the gate did not reach a verdict" && issue_body | grep -q "Relaunch the merge once the host is fixed" && ok "(f) comment opens with INFRASTRUCTURE and says to relaunch" || bad "(f) comment: $(issue_body)"
issue_body | grep -q "awaiting-integration\|Merged onto" && bad "(f) issue was parked or told it merged: $(issue_body)" || ok "(f) never parked"

# ── (g) a repo's own infrastructure marker through AUTOCODER_GATE_INFRA_PATTERNS ────────
setup
BEFORE=$(origin_master)
OUT=$(AUTOCODER_GATE_INFRA_PATTERNS='^HOST-BROKEN:' run "$RECORD; echo 'HOST-BROKEN: docker is not running'; false"); RC=$?
[ "$RC" -eq 3 ] && ok "(g) a configured marker is an infrastructure refusal" || bad "(g) rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "(g) nothing pushed" || bad "(g) master moved"
echo "$OUT" | grep -q "INFRASTRUCTURE -- .*HOST-BROKEN: docker is not running" && ok "(g) the configured line is the named cause" || bad "(g) cause wrong: $OUT"
# and without the override the same output is an unnamed test failure, not a refusal
setup
OUT=$(run "$RECORD; echo 'HOST-BROKEN: docker is not running'; false"); RC=$?
[ "$RC" -eq 2 ] && ok "(g') without the override the line is not infrastructure" || bad "(g') rc=$RC: $OUT"

# ── (h) a host line QUOTED by a failing test is that test's verdict, never a refusal ──────
# The default patterns are grepped over the whole run output. A failing test whose assertion
# quotes "command not found" (or ENOSPC, a heap death, a strerror) must read as a plain red
# of this change (exit 2 against a green base), not as "the gate did not reach a verdict".
setup
BEFORE=$(origin_master)
QUOTED='echo "FAIL  tests/driver.test.sh > the driver names the missing tool"; echo "AssertionError: expected '"'"'fault'"'"' to match /the generator command is not installed \(bash: tsx: command not found\)/"; echo "AssertionError: expected '"'"'npm ERR! code ENOSPC'"'"' to be '"'"'ok'"'"'"; echo "+   \"FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory\","; echo "- \"fatal: write error: No space left on device\""; false'
OUT=$(run "$RECORD; if [ -f src/app.sh ]; then $QUOTED; fi"); RC=$?
[ "$RC" -eq 2 ] && ok "(h) a quoted host line is this change's own red (exit 2)" || bad "(h) rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "(h) nothing pushed" || bad "(h) master moved"
echo "$OUT" | grep -q "INFRASTRUCTURE" && bad "(h) read as an infrastructure refusal: $OUT" || ok "(h) never read as infrastructure"
echo "$OUT" | grep -q "tests/driver.test.sh" && ok "(h) the failing test is named" || bad "(h) failing test not named: $OUT"
# and the shell's own line, unquoted, is still the host's refusal
for real in 'bash: tsx: command not found' 'scripts/gen.sh: line 3: tsx: command not found' 'Error: ENOSPC: no space left on device, write' 'FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory' 'fatal: write error: No space left on device' 'bash: fork: retry: Cannot allocate memory'; do
  setup
  OUT=$(run "$RECORD; echo '$real'; false"); RC=$?
  [ "$RC" -eq 3 ] && ok "(h) the real line is a refusal: $real" || bad "(h) rc=$RC for '$real': $OUT"
done

# ── (i) a PASSING test's report line quoting a host line is never a refusal (#318) ───────
# test_merge_infrastructure_refusal.sh's own (h) prints `PASS: ... FATAL ERROR: ... heap out
# of memory`; run-shell-suite.sh reprints a failing suite's output behind `      | `. The
# heap and strerror alternatives are not anchored to the line start, so that PASS line once
# turned every red-base retest into "the gate did not reach a verdict" (exit 3).
setup
BEFORE=$(origin_master)
EXCERPT='echo "FAIL  test_other.sh"; echo "      | PASS: (h) the real line is a refusal: FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory"; echo "      | PASS: (h) the real line is a refusal: fatal: write error: No space left on device"; echo "PASS: quotes bash: fork: retry: Cannot allocate memory"; echo "  ✓ survives fatal: write error: No space left on device"; echo "      | 45 passed / 1 failed / 46 total"; false'
OUT=$(run "$RECORD; if [ -f src/app.sh ]; then $EXCERPT; fi"); RC=$?
[ "$RC" -eq 2 ] && ok "(i) PASS lines quoting host lines leave a plain red (exit 2)" || bad "(i) rc=$RC: $OUT"
echo "$OUT" | grep -q "INFRASTRUCTURE" && bad "(i) a PASS line read as an infrastructure refusal: $OUT" || ok "(i) never read as infrastructure"
[ "$(origin_master)" = "$BEFORE" ] && ok "(i) nothing pushed" || bad "(i) master moved"
# a host line that is not a pass report still refuses, even beside PASS lines
setup
OUT=$(run "$RECORD; echo 'PASS: an earlier test'; echo 'fatal: write error: No space left on device'; false"); RC=$?
[ "$RC" -eq 3 ] && ok "(i) a real host line beside PASS lines is still a refusal" || bad "(i) rc=$RC: $OUT"

# ── (j) a FAILING test's report line quoting a strerror is that test's red (#319) ──────────
# run-shell-suite.sh reprints a failing suite's `FAIL: ...` lines behind `      | `; one that
# ends in a strerror matched the unanchored strerror alternative, and the run became exit 3,
# so the failure was never attributed and the merge was relaunched unchanged.
setup
BEFORE=$(origin_master)
FAILQ='echo "FAIL  test_cache.sh"; echo "      | FAIL: writes the cache: No space left on device"; echo "FAIL: forks a worker: Cannot allocate memory"; echo "not ok 3 - heap: FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory"; echo "  ✗ writes the log: No space left on device"; echo "FAILED  test_disk.sh: No space left on device"; echo "  × spawns a child: Cannot allocate memory"; false'
OUT=$(run "$RECORD; if [ -f src/app.sh ]; then $FAILQ; fi"); RC=$?
[ "$RC" -eq 2 ] && ok "(j) FAIL lines quoting a strerror leave a plain red (exit 2)" || bad "(j) rc=$RC: $OUT"
echo "$OUT" | grep -q "INFRASTRUCTURE" && bad "(j) a FAIL line read as an infrastructure refusal: $OUT" || ok "(j) never read as infrastructure"
[ "$(origin_master)" = "$BEFORE" ] && ok "(j) nothing pushed" || bad "(j) master moved"
# a real host line inside the excerpt (not a report line) still refuses
setup
OUT=$(run "$RECORD; echo 'FAIL: an earlier test'; echo '      | fatal: write error: No space left on device'; false"); RC=$?
[ "$RC" -eq 3 ] && ok "(j) a host line behind the excerpt prefix is still a refusal" || bad "(j) rc=$RC: $OUT"


# ── (k) the REBASE step: a rebase the host stopped is not a conflict ──────────────────────
# Git replaying the feature commits can die on the same conditions as a gate stage (ENOSPC on
# a shared tmpfs under several concurrent gates); it leaves no conflicted file, so the stop
# used to read as "failed without a conflict": exit 1 and a needs-clarification label for a
# condition no human decision resolves. A git shim on PATH fails the next N `rebase` calls
# with git's own ENOSPC line (the real git handles everything else, `--abort` included).
REAL_GIT=$(command -v git)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/git" <<SHIM
#!/bin/bash
# fail the next N non-abort rebases (N in \$REBASE_FAIL_COUNT_FILE) with \$REBASE_FAIL_MSG_FILE's text
is_rebase=0; is_abort=0
for a in "\$@"; do [ "\$a" = rebase ] && is_rebase=1; [ "\$a" = --abort ] && is_abort=1; done
if [ "\$is_rebase" -eq 1 ] && [ "\$is_abort" -eq 0 ] && [ -s "\${REBASE_FAIL_COUNT_FILE:-/nonexistent}" ]; then
  n=\$(cat "\$REBASE_FAIL_COUNT_FILE")
  if [ "\$n" -gt 0 ]; then
    echo \$((n - 1)) > "\$REBASE_FAIL_COUNT_FILE"
    if [ -s "\$REBASE_FAIL_MSG_FILE.\$n" ]; then cat "\$REBASE_FAIL_MSG_FILE.\$n" >&2; else cat "\$REBASE_FAIL_MSG_FILE" >&2; fi
    exit 1
  fi
fi
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$TMP/bin/git"
export REBASE_FAIL_COUNT_FILE="$TMP/rebase-fails" REBASE_FAIL_MSG_FILE="$TMP/rebase-msg"
printf 'error: unable to create file src/generated/big.txt: No space left on device\nerror: could not apply 1a2b3c4... fix\n' > "$REBASE_FAIL_MSG_FILE"
run_shim() { PATH="$TMP/bin:$PATH" AUTOCODER_REBASE_INFRA_RETRY_DELAY=0 run "$@"; }
rebase_fails() { echo "$1" > "$REBASE_FAIL_COUNT_FILE"; }

# one host stop: retried once, then the merge proceeds and lands
setup
BEFORE=$(origin_master)
rebase_fails 1
OUT=$(run_shim "$RECORD"); RC=$?
[ "$RC" -eq 0 ] && ok "(k) one host stop of the rebase is retried and the merge lands (exit 0)" || bad "(k) rc=$RC: $OUT"
[ "$(origin_master)" != "$BEFORE" ] && ok "(k) master moved after the retry" || bad "(k) master did not move: $OUT"
echo "$OUT" | grep -q "stopped on a host condition, not a conflict (error: unable to create file src/generated/big.txt: No space left on device); retrying once" && ok "(k) the retry names the host line" || bad "(k) no retry line: $OUT"
echo "$OUT" | grep -q "failed without a conflict\|Conflict rebasing\|INFRASTRUCTURE" && bad "(k) a retried stop was reported as a failure: $OUT" || ok "(k) a retried stop is neither a conflict nor a refusal"
[ "$(cat "$REBASE_FAIL_COUNT_FILE")" -eq 0 ] && ok "(k) the shim's one failure was consumed" || bad "(k) shim count $(cat "$REBASE_FAIL_COUNT_FILE")"

# two host stops: an INFRASTRUCTURE refusal (exit 3), nothing gated, nothing pushed
setup
BEFORE=$(origin_master)
rebase_fails 2
OUT=$(run_shim "$RECORD"); RC=$?
[ "$RC" -eq 3 ] && ok "(l) a second host stop of the rebase refuses as INFRASTRUCTURE (exit 3)" || bad "(l) rc=$RC: $OUT"
[ "$(origin_master)" = "$BEFORE" ] && ok "(l) nothing pushed" || bad "(l) master moved: $OUT"
[ "$(gate_runs)" -eq 0 ] && ok "(l) the gate never ran" || bad "(l) gate ran $(gate_runs) time(s): $OUT"
echo "$OUT" | grep -q "^::error::merge-to-integration: INFRASTRUCTURE -- the rebase onto origin/master did not complete, twice: error: unable to create file src/generated/big.txt: No space left on device" && ok "(l) the marker names the rebase and git's own line" || bad "(l) marker missing or wrong: $OUT"
echo "$OUT" | grep -q "relaunch the merge once the host is fixed" && ok "(l) the refusal says what to do" || bad "(l) no relaunch advice: $OUT"
echo "$OUT" | grep -q "failed without a conflict\|Conflict rebasing" && bad "(l) the host stop was reported as a conflict: $OUT" || ok "(l) never reported as a conflict"
git -C "$TMP/worker" rev-parse --verify -q feature/code >/dev/null && ok "(l) the feature branch is intact" || bad "(l) feature branch gone"

# --own-issue: the comment opens with INFRASTRUCTURE, never a conflict bounce
setup claimed
rebase_fails 2
OUT=$(run_shim "$RECORD" --own-issue --summary-file "$TMP/summary.md"); RC=$?
[ "$RC" -eq 3 ] && ok "(l) exit 3 under --own-issue" || bad "(l) own-issue rc=$RC: $OUT"
issue_body | grep -q "INFRASTRUCTURE: rebasing .* onto origin/master stopped on a host condition twice" && issue_body | grep -q "Relaunch the merge once the host is fixed" && ok "(l) the issue's comment opens with INFRASTRUCTURE and says to relaunch" || bad "(l) comment: $(issue_body)"
issue_body | grep -q "autocoder-bounce\|hit a conflict\|Conflicting files\|failed without a conflict" && bad "(l) the issue was told about a conflict: $(issue_body)" || ok "(l) the issue was never told about a conflict"

# a stop that is neither a conflict nor a host condition keeps its own verdict (exit 1)
setup
BEFORE=$(origin_master)
printf 'error: cannot rebase: You have unstaged changes.\nerror: Please commit or stash them.\n' > "$REBASE_FAIL_MSG_FILE"
rebase_fails 2
OUT=$(run_shim "$RECORD"); RC=$?
[ "$RC" -eq 1 ] && ok "(m) a non-host, non-conflict stop still exits 1" || bad "(m) rc=$RC: $OUT"
echo "$OUT" | grep -q "failed without a conflict" && ok "(m) ... and says so" || bad "(m) verdict missing: $OUT"
echo "$OUT" | grep -q "INFRASTRUCTURE\|retrying once" && bad "(m) a non-host stop was retried or refused as infrastructure: $OUT" || ok "(m) never read as a host condition"
[ "$(cat "$REBASE_FAIL_COUNT_FILE")" -eq 1 ] && ok "(m) not retried (one shim failure consumed)" || bad "(m) shim count $(cat "$REBASE_FAIL_COUNT_FILE")"
[ "$(origin_master)" = "$BEFORE" ] && ok "(m) nothing pushed" || bad "(m) master moved"

# a host stop whose abort could not clear the rebase: the retry's plain stop is the host's too
setup
BEFORE=$(origin_master)
printf 'error: unable to create file src/generated/big.txt: No space left on device\n' > "$REBASE_FAIL_MSG_FILE.2"
printf 'fatal: It seems that there is already a rebase-merge directory, and\nI wonder if you are in the middle of another rebase.\n' > "$REBASE_FAIL_MSG_FILE.1"
rebase_fails 2
OUT=$(run_shim "$RECORD"); RC=$?
[ "$RC" -eq 3 ] && ok "(n) a plain stop right after a host stop refuses as INFRASTRUCTURE (exit 3)" || bad "(n) rc=$RC: $OUT"
echo "$OUT" | grep -q "^::error::merge-to-integration: INFRASTRUCTURE -- the rebase onto origin/master did not complete, twice: error: unable to create file src/generated/big.txt: No space left on device" && ok "(n) the marker names the first stop's host line" || bad "(n) marker: $OUT"
echo "$OUT" | grep -q "failed without a conflict" && bad "(n) read as a plain non-conflict stop: $OUT" || ok "(n) never read as a plain stop"
[ "$(origin_master)" = "$BEFORE" ] && ok "(n) nothing pushed" || bad "(n) master moved"
rm -f "$REBASE_FAIL_MSG_FILE.1" "$REBASE_FAIL_MSG_FILE.2"
unset REBASE_FAIL_COUNT_FILE REBASE_FAIL_MSG_FILE

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
