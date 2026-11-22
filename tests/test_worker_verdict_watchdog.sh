#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_worker_verdict_watchdog.sh — pins worker-verdict-watchdog.sh (#7134): a worker whose
# background pre-check finished (or died) and who never saw it is nudged with the verdict; every
# other state is a row that says why, never a send.
#
# The fleet is a scratch repository with one worktree per issue (the branch names the issue), a
# swarm manifest naming each worktree's tmux pane, a fake `tmux` on PATH that records every send,
# a fake worker-idle that reads a list of busy panes, and the file issue backend. Log ages are set
# with touch; a RUNNING log is held open by a background sleep.

set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SCRIPT="$ROOT/plugins/autocoder/scripts/worker-verdict-watchdog.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_contains() { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1 — '$2' not in: $3"; fi; }
assert_not_contains() { if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1 — unexpected '$2' in: $3"; else pass "$1"; fi; }
assert_match() { if printf '%s' "$3" | grep -qE -- "$2"; then pass "$1"; else fail "$1 — /$2/ not in: $3"; fi; }

T=$(mktemp -d)
HOLDER_PID=""
cleanup() { [ -n "$HOLDER_PID" ] && kill "$HOLDER_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/logs" "$T/state"

# ── The repository, its worktrees and the swarm manifest ────────────────────────────────
REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
# The base commit is two hours old (committer date too), so a worktree at it has NOT committed after a verdict.
OLD="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)"
GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD" git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
ISSUES="$T/.issues"
mkdir -p "$ISSUES/open" "$ISSUES/working" "$ISSUES/blocked" "$ISSUES/closed"
cat > "$REPO/.autocoder.json" <<EOF
{
  "issueSource": "file",
  "issueDir": "$ISSUES",
  "workers": {"verdictLogs": ["$T/logs/*.log"], "verdictStaleMin": 10, "verdictDeadMin": 15}
}
EOF
for n in 101 202 303 404 505 606 707 808 909; do
  printf -- '---\ntitle: issue %s\nlabels: [P2, working]\n---\nbody of %s\n' "$n" "$n" > "$ISSUES/working/$n.md"
done
wt() { # wt <issue> <branch>
  git -C "$REPO" worktree add -q "$T/wt-$1" -b "$2" HEAD 2>/dev/null
}
wt 101 feature/issue-101
wt 202 feature/issue-202
wt 303 303-a-slug
wt 404 feature/issue-404
wt 606 feature/issue-606
wt 707 feature/issue-707
wt 808 feature/issue-808
wt 909 feature/issue-909
mkdir -p "$REPO/.autocoder/swarm"
python3 - "$REPO/.autocoder/swarm/s.json" "$T" <<'PY'
import json, sys
path, t = sys.argv[1:]
workers = []
for i, n in enumerate([101, 202, 303, 606, 707, 808, 909], start=1):
    workers.append({"number": i, "worktree": f"{t}/wt-{n}", "tmuxTarget": f"%{n}", "cmuxWorkspace": None, "herdrPane": f"w{n}:p1", "state": "running"})
workers.append({"number": 9, "worktree": f"{t}/wt-404", "tmuxTarget": None, "cmuxWorkspace": None, "herdrPane": None, "state": "running"})
json.dump({"session": "s", "workers": workers}, open(path, "w"), indent=1)
PY

# ── The fake multiplexer and idle probe ──────────────────────────────────────────────────
cat > "$T/bin/tmux" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TMUX_ARGV_CAPTURE"
case "$1" in
  capture-pane) printf '\n\n❯\n' ;;
  *) exit 0 ;;
esac
STUB
cat > "$T/bin/worker-idle" <<'STUB'
#!/bin/bash
pane=""; while [ $# -gt 0 ]; do case "$1" in --pane) pane="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s\n' "$pane" >> "$IDLE_PROBE_CAPTURE"
case " ${IDLE_BUSY_PANES:-} " in *" $pane "*) exit 1 ;; esac
case " ${IDLE_UNKNOWN_PANES:-} " in *" $pane "*) exit 2 ;; esac
exit 0
STUB
chmod +x "$T/bin/tmux" "$T/bin/worker-idle"

# ── The logs ────────────────────────────────────────────────────────────────────────────
verdict_log() { # verdict_log <name> <PASS|FAIL|none> <minutes-ago>
  local f="$T/logs/$1"
  { echo "--- prebank: merge-tree"; echo "PASS merge-tree 1s clean"; } > "$f"
  case "$2" in
    PASS) { echo "=== prebank (scripts/prebank.sh, #5832): PASS === tree abc on origin/master def === 900s"; echo "=== prebank: PASS -- paste this block into the READY comment ==="; } >> "$f" ;;
    # The closing FAIL line names the other word ("paste the PASS block"), as the real prebank's does.
    FAIL) { echo "=== prebank (scripts/prebank.sh, #5832): FAIL === tree abc on origin/master def === 300s"; echo "=== prebank: FAIL at contracts-check -- fix it on this tree, run again, and paste the PASS block into the READY comment; never baseline it ==="; } >> "$f" ;;
  esac
  touch -d "-$3 minutes" "$f"
}
verdict_log prebank-101.log PASS 20          # unread PASS, idle pane: NUDGED
verdict_log prebank-101-old.log FAIL 60      # an older run of the same issue: superseded, no row
verdict_log prebank-202.log none 30          # no verdict, nobody holds it, past dead-min: DEAD, NUDGED
verdict_log 303-prebank2.log FAIL 20         # unread FAIL, but the pane is busy: BUSY
verdict_log prebank-404.log PASS 20          # worktree without a pane in the manifest: REPORT
verdict_log prebank-505.log PASS 20          # no worktree checks out a branch naming it: REPORT
verdict_log prebank-606.log none 30          # no verdict, held open by a live process: RUNNING
verdict_log prebank-707.log PASS 1           # fresh verdict: WAIT
verdict_log prebank-808.log PASS 20          # a READY was posted after it: SEEN
verdict_log prebank-909.log PASS 20          # the worktree committed after it: SEEN
echo "notes" > "$T/logs/readme.log"          # no issue number in the name: ignored
sleep 600 9>>"$T/logs/prebank-606.log" &
HOLDER_PID=$!
# 808: the file backend folds a comment into the body as a dated blockquote; one posted now is after the verdict.
printf '\n> **%s** [swarm] READY `feature/issue-808` @ abc (prebank PASS)\n' "$(date -u '+%Y-%m-%d %H:%M')" >> "$ISSUES/working/808.md"
git -C "$T/wt-909" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "after the verdict"

run() { # run <extra args...>
  : > "$T/argv"; : > "$T/probes"
  PATH="$T/bin:$PATH" TMUX_ARGV_CAPTURE="$T/argv" IDLE_PROBE_CAPTURE="$T/probes" IDLE_BUSY_PANES="%303" \
    AUTOCODER_WORKER_IDLE="$T/bin/worker-idle" VERDICT_WATCHDOG_STATE_DIR="$T/state" AUTOCODER_MUX_SUBMIT_DELAY=0 \
    AUTOCODER_ISSUE_EVENTS="$T/events.jsonl" HOME="$T/home" \
    bash "$SCRIPT" --repo "$REPO" --mux tmux "$@" 2>&1
}
sends() { grep -E '^send-keys' "$T/argv" || true; }

# ── Dry run first: every decision is visible and nothing is sent, written or recorded ────
OUT=$(run --dry-run)
assert_contains "dry-run: the unread PASS would be nudged" "#101 PASS 20m wt=$T/wt-101 pane=%101 seen=no idle=yes -> DRY-RUN (would send: Your background pre-check for #101 finished at" "$OUT"
assert_contains "dry-run: the dead run would be nudged to re-run in the foreground" "#202 DEAD 30m wt=$T/wt-202 pane=%202 seen=no idle=yes -> DRY-RUN (would send: Your background pre-check for #202 ($T/logs/prebank-202.log) stopped at" "$OUT"
[ -z "$(sends)" ] && pass "dry-run: zero sends" || fail "dry-run: zero sends — $(sends)"
[ -z "$(ls -A "$T/state" 2>/dev/null)" ] && pass "dry-run: no state written" || fail "dry-run: state written: $(ls "$T/state")"
[ ! -s "$T/events.jsonl" ] && pass "dry-run: no lifecycle event recorded" || fail "dry-run: events recorded: $(cat "$T/events.jsonl")"

# ── A real tick ──────────────────────────────────────────────────────────────────────────
OUT=$(run --once)
assert_contains "unread PASS on an idle pane is NUDGED" "#101 PASS 20m wt=$T/wt-101 pane=%101 seen=no idle=yes -> NUDGED (sent to %101)" "$OUT"
assert_match "the nudge names the issue, the verdict, the time and the log" "send-keys -t %101 Your background pre-check for #101 finished at [0-9T:-]+Z with PASS \($T/logs/prebank-101.log\): read its block and continue\. PASS: push the branch and post the READY with the block\." "$(sends)"
assert_contains "the nudge states the rule" "Do not wait on a background-job notification for a verdict" "$(sends)"
assert_contains "a dead run (no verdict, no holder, past dead-min) is NUDGED to re-run" "#202 DEAD 30m wt=$T/wt-202 pane=%202 seen=no idle=yes -> NUDGED (sent to %202)" "$OUT"
assert_match "the dead nudge says there is no verdict and no live process" "send-keys -t %202 Your background pre-check for #202 \($T/logs/prebank-202.log\) stopped at [0-9T:-]+Z with no verdict and no live process: re-run it in the foreground" "$(sends)"
assert_contains "a FAIL whose closing line says 'paste the PASS block' is read as FAIL (the first token after the prefix)" "#303 FAIL 20m" "$OUT"
assert_contains "a busy pane is left alone (BUSY)" "#303 FAIL 20m wt=$T/wt-303 pane=%303 seen=no idle=no -> BUSY (the pane is working; it will read the log)" "$OUT"
assert_contains "a worktree with no pane in the manifest is reported, not nudged" "#404 PASS 20m wt=$T/wt-404 pane=none seen=no idle=- -> REPORT (no tmux pane for $T/wt-404 in $REPO/.autocoder/swarm/*.json)" "$OUT"
assert_contains "an issue no worktree checks out is reported, not nudged" "#505 PASS 20m wt=none pane=none seen=no idle=- -> REPORT (no worktree checks out a branch naming #505)" "$OUT"
assert_contains "a log a live process holds open is RUNNING" "#606 RUNNING 30m wt=$T/wt-606 pane=%606 seen=- idle=- -> WAIT (a process holds the log open)" "$OUT"
assert_contains "a fresh verdict waits for stale-min" "#707 PASS 1m wt=$T/wt-707 pane=%707 seen=- idle=- -> WAIT (fresh; unread after 10m)" "$OUT"
assert_contains "a READY posted after the verdict means it was seen" "#808 PASS 20m wt=$T/wt-808 pane=%808 seen=yes idle=- -> SEEN (READY posted after the verdict)" "$OUT"
assert_contains "a commit on the worktree after the verdict means it was seen" "#909 PASS 20m wt=$T/wt-909 pane=%909 seen=yes idle=- -> SEEN (commit after the verdict)" "$OUT"
assert_not_contains "the superseded older log of #101 is not a row" "prebank-101-old.log" "$OUT"
[ "$(sends | wc -l | tr -d ' ')" = "4" ] && pass "exactly two nudges (text + Enter each)" || fail "expected 4 send-keys lines, got: $(sends)"
assert_not_contains "no send went to the busy pane" "send-keys -t %303" "$(sends)"
assert_not_contains "no send went to a seen issue's pane" "send-keys -t %808" "$(sends)"
assert_not_contains "no probe of a seen issue's pane (the tracker is read first)" "%808" "$(cat "$T/probes")"

# ── The lifecycle events the report reads ────────────────────────────────────────────────
EVENTS=$(cat "$T/events.jsonl")
assert_match "a verdict event per seen verdict: #101 PASS with its log and time" '"issue":101,"worker":"wt-101","branch":"feature/issue-101","event":"verdict","detail":\{[^}]*"verdict":"PASS"[^}]*"log":"'"$T"'/logs/prebank-101.log"' "$EVENTS"
assert_match "a verdict event for the FAIL nobody was nudged about" '"issue":303,.*"event":"verdict","detail":\{[^}]*"verdict":"FAIL"' "$EVENTS"
assert_match "a verdict-nudged event for #101 with the idle seconds" '"issue":101,"worker":"wt-101",.*"event":"verdict-nudged","detail":\{[^}]*"verdict":"PASS"[^}]*"idle_s":"?1[12][0-9][0-9]"?' "$EVENTS"
assert_match "a verdict-nudged event for the dead run" '"issue":202,.*"event":"verdict-nudged","detail":\{[^}]*"verdict":"DEAD"' "$EVENTS"
assert_not_contains "no verdict event for a log with no verdict" '"issue":606,' "$EVENTS"
assert_not_contains "no verdict event for an issue no worktree of this repository checks out (another swarm's log on a shared host)" '"issue":505,' "$EVENTS"
VERDICT_COUNT=$(grep -c '"event":"verdict"' "$T/events.jsonl")
[ "$VERDICT_COUNT" = "6" ] && pass "one verdict event per log with a verdict and a worktree (6: 101 303 404 707 808 909)" || fail "expected 6 verdict events, got $VERDICT_COUNT"

# ── A second tick: cooldown holds, nothing is re-sent, no duplicate verdict events ───────
OUT=$(run --once)
assert_contains "second tick: #101 is in cooldown" "#101 PASS 20m wt=$T/wt-101 pane=%101 seen=no idle=yes -> COOLDOWN (nudged within the last 1800s)" "$OUT"
assert_contains "second tick: #202 is in cooldown" "#202 DEAD 30m wt=$T/wt-202 pane=%202 seen=no idle=yes -> COOLDOWN" "$OUT"
[ -z "$(sends)" ] && pass "second tick: zero sends" || fail "second tick: zero sends — $(sends)"
[ "$(grep -c '"event":"verdict"' "$T/events.jsonl")" = "6" ] && pass "second tick: no duplicate verdict events" || fail "second tick: verdict events grew to $(grep -c '"event":"verdict"' "$T/events.jsonl")"

# ── --json: one object per judged log, the same decisions ────────────────────────────────
JSON=$(run --json)
python3 - "$JSON" "$T" <<'PY' && pass "--json: an array with the actions by issue" || fail "--json: $JSON"
import json, sys
rows = json.loads(sys.argv[1]); t = sys.argv[2]
by = {r["issue"]: r for r in rows}
assert by["101"]["action"] == "COOLDOWN" and by["101"]["verdict"] == "PASS" and by["101"]["log"] == f"{t}/logs/prebank-101.log", by["101"]
assert by["202"]["verdict"] == "DEAD" and by["303"]["action"] == "BUSY" and by["404"]["action"] == "REPORT" and by["505"]["worktree"] == ""
assert by["606"]["verdict"] == "RUNNING" and by["707"]["action"] == "WAIT" and by["808"]["action"] == "SEEN" and by["909"]["seen"] == "yes"
assert set(by) == {"101", "202", "303", "404", "505", "606", "707", "808", "909"}, sorted(by)
PY

# ── Refusals ─────────────────────────────────────────────────────────────────────────────
OUT=$(PATH="$T/bin:$PATH" HOME="$T/home" bash "$SCRIPT" --repo "$T/nowhere" 2>&1); RC=$?
[ "$RC" = "2" ] && pass "a missing repository is a usage refusal (exit 2)" || fail "missing repo: exit $RC: $OUT"
EMPTY="$T/empty"; mkdir -p "$EMPTY"; git -C "$EMPTY" init -q
OUT=$(PATH="$T/bin:$PATH" HOME="$T/home" bash "$SCRIPT" --repo "$EMPTY" 2>&1); RC=$?
[ "$RC" = "2" ] && assert_contains "no configured logs is a refusal naming the three ways to name them" "no pre-check logs named: set workers.verdictLogs in $EMPTY/.autocoder.json, AUTOCODER_VERDICT_LOGS, or --logs GLOB" "$OUT" || fail "no logs: exit $RC: $OUT"
OUT=$(run --stale-min soon 2>&1); RC=$?
[ "$RC" = "2" ] && pass "a non-numeric --stale-min is a usage refusal" || fail "--stale-min soon: exit $RC: $OUT"

echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
