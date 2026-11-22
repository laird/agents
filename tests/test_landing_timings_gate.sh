#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255
# tests/test_landing_timings_gate.sh — merge-to-integration.sh appends landing-timings rows:
# a landing gives a green batch of one plus batched and landed; a gate that fails only on the
# change gives a red batch (cause defect) and a returned change; a red integration branch gives a
# red batch (cause red-integration), the change landing or coming back by the red-base setting; under a\n# train (AUTOCODER_LANDING_BATCH) the batch row is the train's and the gate issue gets no change row.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"
ISSUES_PY="$SCRIPT_DIR/issues-file.py"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AUTOCODER_SPOT_CHECK_RATE=0 ISSUE_SOURCE=file
export AUTOCODER_TMP="$TMP/tmp"; mkdir -p "$AUTOCODER_TMP"
export ISSUE_DIR_PATH="$TMP/issues"
export AUTOCODER_GATE_CACHE_DIR="$TMP/gate-cache"
export AUTOCODER_LANDING_TIMINGS="$TMP/landing.jsonl"
export CLAUDE_CODE_SHIP_BRANCH=master
unset AUTOCODER_MERGE_ON_RED_BASE AUTOCODER_SCOPED_REGATE
mkdir -p "$TMP/issues"/{open,working,blocked,closed}

git init --bare -q "$TMP/origin.git"
git init -q "$TMP/worker"
cd "$TMP/worker" || exit 1
git config user.email t@example.com; git config user.name T
git remote add origin "$TMP/origin.git"
echo base > README.md; git add -A; git commit -q -m init; git branch -M master; git push -q origin master master:master-green

source "$SCRIPT_DIR/repo-id-fns.sh"
run_one() {  # <issue> <file to add> <test-cmd>: one detached attempt, waited to completion
  local issue="$1" file="$2" cmd="$3" state
  printf -- '---\nnumber: %s\ntitle: T\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' "$issue" > "$TMP/issues/open/${issue}.md"
  python3 "$ISSUES_PY" claim "$issue" >/dev/null
  git checkout -q -b "feature/i$issue" master
  echo x > "$file"; git add -A; git commit -q -m "fix #$issue"; git push -q origin "feature/i$issue"
  state="$AUTOCODER_TMP/autocoder-merge-$(autocoder_repo_id "$TMP/worker")-${issue}"
  bash "$SCRIPT_DIR/merge-launch.sh" --feature "feature/i$issue" --issue "$issue" --integration master \
    --test-cmd "$cmd" --own-issue >/dev/null 2>&1 || { bad "launch $issue failed"; return 1; }
  for _ in $(seq 1 120); do [ -s "${state}.exit" ] && break; sleep 0.5; done
  git checkout -q master; git pull -q origin master
}
rows() {  # <issue>: "kind event|verdict cause" lines for that issue
  python3 - "$AUTOCODER_LANDING_TIMINGS" "$1" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l); n = int(sys.argv[2])
    if r["kind"] == "change" and r["issue"] == n:
        print("change", r["event"], r["cause"] or "-")
    if r["kind"] == "batch" and n in r["members"]:
        print("batch", r["verdict"], r["cause"] or "-", "gate" if r["gate_s"] is not None else "nogate")
PY
}

run_one 7101 src_ok.txt true
eq "landing: green batch, batched, landed" "batch green - gate
change batched -
change landed -" "$(rows 7101)"
# The landed row names the commit now on the integration branch (the CI verdict is looked up by it).
eq "landing: the landed row carries the landed commit" "$(git rev-parse HEAD)" "$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["kind"] == "change" and r["issue"] == 7101 and r["event"] == "landed": print(r.get("sha"))' "$AUTOCODER_LANDING_TIMINGS")"

run_one 7102 bad.txt 'test ! -f bad.txt'
eq "change-only failure: red batch, defect, returned" "batch red defect gate
change batched -
change returned defect" "$(rows 7102)"

run_one 7103 other.txt 'echo "FAIL shared"; false'
eq "red base, landed anyway: red batch (red-integration), landed" "batch red red-integration gate
change batched -
change landed -" "$(rows 7103)"

AUTOCODER_MERGE_ON_RED_BASE=0 run_one 7104 more.txt 'echo "FAIL shared"; false'
eq "red base, refused: red batch (red-integration), returned" "batch red red-integration gate
change batched -
change returned red-integration" "$(rows 7104)"

# Inside a train (train_run.py exports both), the gate's batch row is the TRAIN's: its id, its members, the
# gate's seconds; no change rows for the gate issue (the train writes the members' rows). Nothing else changes.
AUTOCODER_LANDING_BATCH=train-20260101T000000Z-1 AUTOCODER_LANDING_MEMBERS=7201,7202 run_one 7105 in_train.txt true
eq "under a train: the batch row is the train's, with its members, and no change row for the gate issue" "batch green - gate train-20260101T000000Z-1 7201,7202" \
  "$(python3 - "$AUTOCODER_LANDING_TIMINGS" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["kind"] == "change" and r["issue"] == 7105: print("change", r["event"])
    if r["kind"] == "batch" and r["batch"].startswith("train-"):
        print("batch", r["verdict"], r["cause"] or "-", "gate" if r["gate_s"] is not None else "nogate", r["batch"], ",".join(map(str, r["members"])))
PY
)"

# Under a train with NO gate run (the branch conflicts with master, so the gate stops before any test): no row
# at all for the gate issue, neither a batch nor a `returned` change (the train owns its members' rows).
# origin/master takes conflict.txt while the local master (the branch's base) stays behind, so the gate's merge conflicts.
git checkout -q --detach master; echo master-side > conflict.txt; git add -A; git commit -q -m "master takes conflict.txt"
git push -q origin HEAD:master; git checkout -q master
AUTOCODER_LANDING_BATCH=train-20260101T000000Z-2 AUTOCODER_LANDING_MEMBERS=7301 run_one 7106 conflict.txt true
eq "under a train, no gate run: no batch row, no change row for the gate issue" "" "$(rows 7106; python3 - "$AUTOCODER_LANDING_TIMINGS" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["kind"] == "batch" and r["batch"] == "train-20260101T000000Z-2": print("batch", r["verdict"])
PY
)"


# Every row the gate writes names this repository (landing-timings.py --repo from AUTOCODER_LANDING_REPO,
# which the gate exports from repo-id-fns.sh when the caller set none).
eq "every row names the repository" "$(autocoder_repo_id "$TMP/worker")" \
  "$(python3 -c 'import json,sys; print(" ".join(sorted({str(json.loads(l)["repo"]) for l in open(sys.argv[1])})))' "$AUTOCODER_LANDING_TIMINGS")"

# The stage runner's per-stage seconds reach the batch row: the gate hands each run its own timings file
# (AUTOCODER_STAGE_TIMINGS_FILE); a command that writes the runner's JSON there gets `stages` on the row,
# gate_s stays the wall clock the gate measured.
run_one 7107 staged.txt 'printf "%s" "{\"v\":1,\"verdict\":\"PASS\",\"wall_s\":3,\"stages\":{\"build\":{\"seconds\":1.4,\"status\":\"passed\"},\"tests\":{\"seconds\":2.0,\"status\":\"passed\"},\"skipped\":{\"seconds\":null,\"status\":\"skipped\"}}}" > "$AUTOCODER_STAGE_TIMINGS_FILE"'
eq "stage seconds on the batch row" "green build=1 tests=2" "$(python3 - "$AUTOCODER_LANDING_TIMINGS" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["kind"] == "batch" and 7107 in r["members"]:
        print(r["verdict"], " ".join(f"{k}={v:.0f}" for k, v in r["stages"].items()))
PY
)"
eq "the per-run timings file is removed after the run" "" "$(ls "$AUTOCODER_TMP"/autocoder-gate-stages-7107-* 2>/dev/null)"

# A gate killed mid-run (a memory-cap watcher's SIGTERM to its process group, a host shutdown) reaches the
# EXIT trap with no outcome and `$?` of the interrupted command, which used to read as `landed` with exit 0
# and no sha. A landing is the publish proof and nothing else: the job is `aborted`, the run in flight is
# counted as gate time, the batch row says aborted:infra, the change comes back as infra, and nothing says
# landed in either ledger. The test command kills the job's own process group (the launch's pidfile).
state7108="$AUTOCODER_TMP/autocoder-merge-$(autocoder_repo_id "$TMP/worker")-7108"
printf -- '---\nnumber: 7108\ntitle: T\npriority: P2\nlabels: [bug]\nstatus: open\n---\nBody.\n' > "$TMP/issues/open/7108.md"
python3 "$ISSUES_PY" claim 7108 >/dev/null
git checkout -q -b feature/i7108 master; echo x > killed.txt; git add -A; git commit -q -m "fix #7108"; git push -q origin feature/i7108
bash "$SCRIPT_DIR/merge-launch.sh" --feature feature/i7108 --issue 7108 --integration master \
  --test-cmd "sleep 2; kill -TERM -- -\$(cat '${state7108}.pid'); sleep 30" --own-issue >/dev/null 2>&1 || bad "launch 7108 failed"
for _ in $(seq 1 120); do grep -q '"batch":"solo-7108-' "$AUTOCODER_LANDING_TIMINGS" 2>/dev/null && break; sleep 0.5; done
sleep 1
git checkout -q master
eq "killed mid-run: an aborted:infra batch with its seconds, batched, returned infra; never landed" "batch aborted infra gate
change batched -
change returned infra" "$(rows 7108)"
eq "killed mid-run: the lifecycle ledger says gate-end aborted, no landed event" "gate-end aborted" "$(python3 - "$AUTOCODER_ISSUE_EVENTS" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r.get("issue") == 7108 and r["event"] in ("gate-end", "landed"):
        print(r["event"], (r.get("detail") or {}).get("outcome", ""))
PY
)"
eq "killed mid-run: the merge-events attempt is aborted with no landed sha" "aborted None" "$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r.get("issue") == 7108 and r["event"] == "attempt": print(r["outcome"], r["landed"])' "$AUTOCODER_MERGE_EVENTS")"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
