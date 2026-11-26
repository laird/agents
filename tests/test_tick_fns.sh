#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_tick_fns.sh — tick_start/tick_end append one line per loop run to ticks.jsonl (#422).
#
# A start/end pair writes one well-formed line (numeric duration, the checkout's repo id, typed
# observed and actions); tick_end with no start writes duration_s null; a line that cannot be
# written, or a bad argument, never fails the caller.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export AUTOCODER_TICKS="$TMP/ticks.jsonl"

# field <line number> <python expression over the row `r`>
field() { python3 -c 'import json,sys; r = json.loads(open(sys.argv[1]).read().splitlines()[int(sys.argv[2]) - 1]); print(eval(sys.argv[3]))' "$AUTOCODER_TICKS" "$1" "$2"; }

git init -q "$TMP/checkout"
cd "$TMP/checkout" || exit 1
# shellcheck source=../plugins/autocoder/scripts/tick-fns.sh
source "$SCRIPT_DIR/tick-fns.sh"
want_repo=$(autocoder_repo_id "$TMP/checkout")

# ── a start/end pair ─────────────────────────────────────────────────────────
tick_start queue-pass run-1
sleep 0.2
tick_end ok observed.queued=4 observed.label=ready actions.claimed=1 actions.share=0.5
eq "one line per run" 1 "$(wc -l < "$AUTOCODER_TICKS" | tr -d ' ')"
eq "version, loop and run id" "1 queue-pass run-1" "$(field 1 '" ".join(map(str, (r["v"], r["loop"], r["run_id"])))')"
eq "outcome ok, no error" "ok None" "$(field 1 'r["outcome"] + " " + str(r["error"])')"
eq "duration is a number of seconds since tick_start" "True" \
  "$(field 1 'isinstance(r["duration_s"], float) and 0.1 < r["duration_s"] < 30')"
eq "repo is the checkout's repo id" "$want_repo" "$(field 1 'r["repo"]')"
eq "ts is the start, ISO-8601 UTC" "True" \
  "$(field 1 '__import__("re").fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", r["ts"]) is not None')"
eq "observed keeps numbers as numbers" "{'queued': 4, 'label': 'ready'}" "$(field 1 'r["observed"]')"
eq "actions keeps numbers as numbers" "{'claimed': 1, 'share': 0.5}" "$(field 1 'r["actions"]')"

# ── tick_end with no tick_start ──────────────────────────────────────────────
tick_end error error="lock held"
eq "a second line" 2 "$(wc -l < "$AUTOCODER_TICKS" | tr -d ' ')"
eq "no start: duration_s null" "None" "$(field 2 'r["duration_s"]')"
eq "no start: the loop is the calling script's name" "test_tick_fns" "$(field 2 'r["loop"]')"
eq "error= is the error text" "error lock held" "$(field 2 'r["outcome"] + " " + str(r["error"])')"
eq "no start: a run id is still written" "True" "$(field 2 'bool(r["run_id"]) and r["run_id"] != "run-1"')"

# ── outside a checkout, repo is the directory's id ───────────────────────────
mkdir -p "$TMP/plain-dir"
(cd "$TMP/plain-dir" && GIT_CEILING_DIRECTORIES="$TMP" tick_start sweep && tick_end noop)
eq "repo outside git is autocoder_repo_id of the directory" "$(autocoder_repo_id "$TMP/plain-dir")" "$(field 3 'r["repo"]')"

# ── recording never fails the caller ─────────────────────────────────────────
echo "not a directory" > "$TMP/blocker"
out=$(set -e; AUTOCODER_TICKS="$TMP/blocker/ticks.jsonl"; tick_start probe; tick_end ok; echo "caller went on")
eq "an unwritable ledger does not fail a set -e caller" "caller went on" "$out"
out=$(set -e; tick_start probe; tick_end not-an-outcome junk-pair; echo "caller went on: $?")
eq "a bad argument does not fail the caller" "caller went on: 0" "$out"
eq "nothing written for a bad argument" 3 "$(wc -l < "$AUTOCODER_TICKS" | tr -d ' ')"
out=$(set -eu; tick_end; echo "caller went on")
eq "tick_end with no arguments under set -u" "caller went on" "$out"

echo ""
echo "test_tick_fns: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
