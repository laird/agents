#!/bin/bash
# tests/test_flaky_sightings.sh — the merge gate records a flaky sighting when a test
# fails on a tree and then passes on the same tree (#191).
#
# Part 1 drives gate_cache_run directly: a second run of a red tree, the optional re-run
# (whole command and {tests}-targeted), and a re-run that fails again.
# Part 2 is the issue's "done when": a real detached merge of a fake repo whose test
# fails once and then passes, with AUTOCODER_GATE_FLAKE_RERUN=1, lands the branch and
# writes exactly one flaky event; flaky-report.sh lists it.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset AUTOCODER_GATE_FLAKE_RERUN AUTOCODER_GATE_RERUN_CMD GATE_CACHE_REUSE_FAIL

# A suite-shaped test command: test_flaky.sh fails the first <n> runs (counted in a state
# file), test_solid.sh always passes, and test_broken.sh fails when BROKEN=1. It honours
# test-name arguments like tests/run-shell-suite.sh.
cat > "$TMP/suite.sh" <<'SH'
#!/bin/bash
state="$1"; shift
[ "$#" -gt 0 ] || set -- test_solid.sh test_flaky.sh test_broken.sh
failed=""
for t in "$@"; do
  echo "$t" >> "$state.ran"
  case "$t" in
    test_flaky.sh)
      n=$(cat "$state" 2>/dev/null || echo 0); echo $((n + 1)) > "$state"
      if [ "$n" -lt "${FLAKY_FAILS:-1}" ]; then echo "FAIL  $t"; echo "      | timing race on HOME"; failed="$failed $t"; else echo "PASS  $t"; fi ;;
    test_broken.sh)
      if [ "${BROKEN:-0}" = 1 ]; then echo "FAIL  $t"; echo "      | assertion failed"; failed="$failed $t"; else echo "PASS  $t"; fi ;;
    *) echo "PASS  $t" ;;
  esac
done
[ -z "$failed" ] || { echo "Failing suites:$failed"; exit 1; }
SH
chmod +x "$TMP/suite.sh"

# ── Part 1: gate_cache_run ──────────────────────────────────────────────────
(
  source "$SCRIPT_DIR/gate-cache-fns.sh"
  export AUTOCODER_GATE_CACHE_DIR="$TMP/cache1"
  SIGHTINGS="$TMP/sightings"
  gate_cache_on_flaky() { printf '%s|%s|%s\n' "${1:0:8}" "$2" "$(printf '%s' "$3" | head -1)" >> "$SIGHTINGS"; }
  git init -q "$TMP/r1"; cd "$TMP/r1" || exit 1
  git config user.email t@example.com; git config user.name T
  echo a > a; git add a; git commit -q -m a
  TREE=$(git rev-parse 'HEAD^{tree}')
  CMD="$TMP/suite.sh $TMP/st1"

  # 1a. Fails, then passes on a retry of the same tree: one sighting, named, with excerpt.
  gate_cache_run . "$CMD" > "$TMP/o1" && echo "BAD first run passed"
  grep -q '^test test_flaky.sh	FAIL  test_flaky.sh\\n      | timing race on HOME$' \
    "$(gate_cache_dir)/$(_gate_cache_key "$TREE" "$CMD")" || echo "BAD fail record lacks the test and excerpt"
  [ -s "$SIGHTINGS" ] && echo "BAD sighting on the first failure"
  gate_cache_run . "$CMD" > "$TMP/o2" || echo "BAD retry failed"
  [ "$(cat "$SIGHTINGS")" = "${TREE:0:8}|test_flaky.sh|FAIL  test_flaky.sh" ] || echo "BAD sighting: $(cat "$SIGHTINGS")"
  grep -q 'gate-cache: flaky: test_flaky.sh failed earlier' "$TMP/o2" || echo "BAD no flaky log line"
  [ "$(gate_cache_get "$TREE" "$CMD")" = pass ] || echo "BAD retry not recorded pass"

  # 1b. Real failure on a retry: still red, no sighting for the test that keeps failing.
  : > "$SIGHTINGS"; rm -f "$TMP/st1"
  CMD2="BROKEN=1 FLAKY_FAILS=0 $TMP/suite.sh $TMP/st1"
  gate_cache_run . "$CMD2" >/dev/null && echo "BAD broken passed"
  gate_cache_run . "$CMD2" >/dev/null && echo "BAD broken passed on retry"
  [ -s "$SIGHTINGS" ] && echo "BAD sighting for a real failure: $(cat "$SIGHTINGS")"

  # 1c. Re-run option, whole command: fails once, re-run passes in the same call.
  : > "$SIGHTINGS"; rm -f "$TMP/st2"
  CMD3="$TMP/suite.sh $TMP/st2"
  AUTOCODER_GATE_FLAKE_RERUN=1 gate_cache_run . "$CMD3" > "$TMP/o3" || echo "BAD re-run did not rescue a flake"
  [ "$(cut -d'|' -f2 "$SIGHTINGS")" = test_flaky.sh ] || echo "BAD re-run sighting: $(cat "$SIGHTINGS")"
  [ "$(gate_cache_get "$TREE" "$CMD3")" = pass ] || echo "BAD rescued run not recorded pass"

  # 1d. Re-run with {tests}: only the failed test re-runs.
  : > "$SIGHTINGS"; rm -f "$TMP/st3" "$TMP/st3.ran"
  CMD4="$TMP/suite.sh $TMP/st3"
  AUTOCODER_GATE_FLAKE_RERUN=1 AUTOCODER_GATE_RERUN_CMD="$TMP/suite.sh $TMP/st3 {tests}" \
    gate_cache_run . "$CMD4" >/dev/null || echo "BAD targeted re-run did not rescue a flake"
  [ "$(grep -c . "$TMP/st3.ran")" = 4 ] || echo "BAD targeted re-run ran $(paste -sd, "$TMP/st3.ran")"
  [ "$(tail -1 "$TMP/st3.ran")" = test_flaky.sh ] || echo "BAD targeted re-run ran the wrong test"
  [ "$(wc -l < "$SIGHTINGS")" -eq 1 ] || echo "BAD targeted sightings: $(cat "$SIGHTINGS")"

  # 1e. Re-run that fails again: red, no sighting, and the record keeps the failure.
  : > "$SIGHTINGS"; rm -f "$TMP/st4"
  CMD5="FLAKY_FAILS=2 $TMP/suite.sh $TMP/st4"
  AUTOCODER_GATE_FLAKE_RERUN=1 gate_cache_run . "$CMD5" >/dev/null && echo "BAD double failure passed"
  [ -s "$SIGHTINGS" ] && echo "BAD sighting for a double failure"
  [ "$(gate_cache_get "$TREE" "$CMD5")" = fail ] || echo "BAD double failure not recorded fail"
  # ...and when it then passes on a later attempt, that is a sighting.
  gate_cache_run . "$CMD5" >/dev/null || echo "BAD third run failed"
  [ "$(cut -d'|' -f2 "$SIGHTINGS")" = test_flaky.sh ] || echo "BAD late sighting: $(cat "$SIGHTINGS")"

  # 1f. A failing test name that is not safe to put in a command re-runs the whole
  # command; {tests} is never filled with it.
  : > "$SIGHTINGS"
  cat > "$TMP/odd.sh" <<SH
#!/bin/bash
echo "\$*" >> "$TMP/odd.args"
if [ ! -f "$TMP/odd.once" ]; then : > "$TMP/odd.once"; echo 'FAIL  a;touch_x'; echo 'Failing suites: a;touch_x'; exit 1; fi
SH
  AUTOCODER_GATE_FLAKE_RERUN=1 AUTOCODER_GATE_RERUN_CMD="bash $TMP/odd.sh only {tests}" \
    gate_cache_run . "bash $TMP/odd.sh all" >/dev/null || echo "BAD unsafe-name re-run did not pass"
  [ "$(paste -sd, "$TMP/odd.args")" = "all,all" ] || echo "BAD unsafe name reached the re-run command: $(paste -sd, "$TMP/odd.args")"
  [ ! -e touch_x ] || echo "BAD a test name was executed"
) > "$TMP/part1" 2>&1
if grep -q '^BAD' "$TMP/part1"; then
  bad "gate_cache_run flaky handling: $(grep '^BAD' "$TMP/part1" | paste -sd';' -)"
else
  ok "gate_cache_run records sightings, re-runs on request, and keeps real failures red"
fi

# ── Part 2: a detached merge of a fake repo (the issue's done-when) ─────────
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ISSUE=19101
export AUTOCODER_SPOT_CHECK_RATE=0
export ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export AUTOCODER_MERGE_EVENTS="$TMP/events.jsonl"
export CLAUDE_CODE_SHIP_BRANCH=master
export AUTOCODER_GATE_FLAKE_RERUN=1
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE

mkdir -p "$TMP/issues"/{open,working,blocked,closed}
printf -- '---\nnumber: %s\ntitle: Flaky\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$ISSUE" > "$TMP/issues/open/${ISSUE}.md"
python3 "$ISSUES_PY" claim "$ISSUE" >/dev/null

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email t@example.com; git config user.name T
git remote add origin "$TMP/origin.git"
echo base > README.md; mkdir -p src; echo base > src/a.sh
git add -A; git commit -q -m init; git branch -M master; git push -q origin master master:master-green
git checkout -q -b feature/flaky master
echo change > src/a.sh; git add -A; git commit -q -m fix; git push -q origin feature/flaky

source "$SCRIPT_DIR/repo-id-fns.sh"
STATE="$AUTOCODER_TMP/autocoder-merge-$(autocoder_repo_id "$TMP/worker")-${ISSUE}"
bash "$SCRIPT_DIR/merge-launch.sh" --feature feature/flaky --issue "$ISSUE" --integration master \
  --test-cmd "$TMP/suite.sh $TMP/st-merge" --own-issue >/dev/null 2>&1 || bad "launch failed"
for _ in $(seq 1 120); do [ -s "${STATE}.exit" ] && break; sleep 0.5; done

eq "the merge job exits 0" "0" "$(cat "${STATE}.exit" 2>/dev/null)"
eq "the branch landed on master" "$(git rev-parse feature/flaky^{tree})" \
  "$(git --git-dir="$TMP/origin.git" rev-parse 'master^{tree}' 2>/dev/null)"
eq "the flaky test ran twice (failed, then re-ran and passed)" "2" "$(cat "$TMP/st-merge" 2>/dev/null)"
eq "one flaky event recorded" "1" "$(grep -c '"event":"flaky"' "$AUTOCODER_MERGE_EVENTS" 2>/dev/null)"
eq "the event names the test, issue and tree" \
  "test_flaky.sh $ISSUE $(git rev-parse feature/flaky^{tree}) feature/flaky True" \
  "$(python3 -c '
import json, sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["event"] == "flaky":
        print(e["test"], e["issue"], e["tree"], e["branch"], "timing race on HOME" in e["first_failure_excerpt"])' "$AUTOCODER_MERGE_EVENTS" 2>/dev/null)"
eq "the attempt event says landed" "landed" "$(python3 -c '
import json, sys
print([json.loads(l) for l in open(sys.argv[1]) if "\"attempt\"" in l][-1]["outcome"])' "$AUTOCODER_MERGE_EVENTS" 2>/dev/null)"

REPORT=$(bash "$SCRIPT_DIR/flaky-report.sh" --days 1)
echo "$REPORT" | grep -Eq "^ +1 .*test_flaky.sh +\(#${ISSUE}\)$" && ok "flaky-report lists the test" || bad "flaky-report: $REPORT"
eq "flaky-report --json" "test_flaky.sh 1 [$ISSUE]" "$(bash "$SCRIPT_DIR/flaky-report.sh" --json | python3 -c '
import json, sys
for l in sys.stdin:
    t = json.loads(l); print(t["test"], t["sightings"], json.dumps(t["issues"]))')"
bash "$SCRIPT_DIR/flaky-report.sh" --repo nosuchrepo | grep -q '^No flaky tests' && ok "--repo filters" || bad "--repo did not filter"
bash "$SCRIPT_DIR/flaky-report.sh" --days x >/dev/null 2>&1; eq "--days must be a number" "2" "$?"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
