#!/bin/bash
# tests/test_claim_overlap.sh — overlap-aware claim selection (#227, sub-task of #186).
#
# An issue declares the areas it will edit (`Touches:` line, or the backticked
# paths under `## Files Affected`). With `.autocoder.json` `claims.avoid_overlap`
# the fix-loop gate tries candidates that overlap an in-flight `working` issue
# last (`prefer`) or not at all (`strict`); `off`, the default, is unchanged.
#
# Hot files (#228): files that conflicted in the last `claims.hot_window` merge
# attempts (merge-events.jsonl, #184) may be held by one in-flight claim at a
# time, under prefer and strict alike.
#
# Runs in a private temp repo with its own .autocoder.json (file backend), so it
# never touches the real tracker, and with a fixture merge-events file, so it
# never reads the real one.

PASS=0; FAIL=0
# Never the real merge history: hot files would depend on this host's merges.
export AUTOCODER_MERGE_EVENTS=/nonexistent/autocoder-test/merge-events.jsonl
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts"

assert_eq() {
  if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS + 1))
  else echo "FAIL: $1 — want '$2', got '$3'"; FAIL=$((FAIL + 1)); fi
}

# ── Unit: touches_of / areas_overlap ────────────────────────────────────────
# shellcheck source=../plugins/autocoder/scripts/touches-fns.sh
source "$SCRIPT_DIR/touches-fns.sh"

body_json() { python3 -c 'import json,sys; print(json.dumps({"body": sys.argv[1]}))' "$1"; }

assert_eq "Touches: line, comma-separated, backticks and ./ stripped" \
  "$(printf 'src/web/village/\nsrc/web/server.rs\ntools/**/screensaver/*')" \
  "$(touches_of "$(body_json $'Intro.\nTouches: `src/web/village/`, ./src/web/server.rs , tools/**/screensaver/*\nMore.')")"
assert_eq "Touches: wins over Files Affected" "a/" \
  "$(touches_of "$(body_json $'Touches: a/\n## Files Affected\n- `b/c.sh`')")"
assert_eq "Files Affected fallback: backticked paths only, section ends at next heading" \
  "$(printf 'plugins/x.sh\ntests/test_x.sh')" \
  "$(touches_of "$(body_json $'## Files Affected\n- new `plugins/x.sh` (+ `mirrors`)\n- `tests/test_x.sh`\n## Testing\n- `other/y.sh`')")"
assert_eq "a Touches: mid-line (an example in prose) is not a declaration" "" \
  "$(touches_of "$(body_json $'Format: one line `Touches: a/b`.\n## Files Affected\n[List specific files]')")"
assert_eq "stdin form" "d/" "$(body_json 'Touches: d/' | touches_of -)"

assert_eq "a Touches: inside a code fence is an example, not a declaration" "real/" \
  "$(touches_of "$(body_json $'```\nTouches: example/\n```\nTouches: real/')")"
assert_eq "an empty Touches: falls back to Files Affected" "b/c.sh" \
  "$(touches_of "$(body_json $'Touches:\n## Files Affected\n- `b/c.sh`')")"
assert_eq "Touches: none declares no areas" "" "$(touches_of "$(body_json 'Touches: none')")"
assert_eq "**Touches**: and 'Files Affected:' spellings" "x/" \
  "$(touches_of "$(body_json '**Touches**: x/')")"
assert_eq "a # comment in a fence does not end Files Affected" "$(printf 'a/x.sh\nb/y.sh')" \
  "$(touches_of "$(body_json $'## Files Affected:\n- `a/x.sh`\n```\n# note\n```\n- `b/y.sh`')")"
assert_eq "catch-all areas are dropped" "src/" \
  "$(touches_of "$(body_json 'Touches: **, /, *, src/')")"
BIG=$(python3 -c 'import json; print(json.dumps({"body": "x" * 300000 + "\nTouches: big/"}))')
assert_eq "a body over 128 KB is read (stdin, not env)" "big/" "$(touches_of "$BIG")"

# Untrusted bodies must not hang the gate: `**` matching was exponential.
DEEP="$(python3 -c 'print("**/" * 400 + "zzz.rs")')"
START=$SECONDS
areas_overlap "$DEEP" "plugins/autocoder/scripts/fix-loop-gate.sh"
assert_eq "a pathological ** area is decided quickly" yes "$([ $((SECONDS - START)) -lt 5 ] && echo yes)"
WIDE="$(python3 -c 'print("/".join(["**", "a"] * 40) + "/x.rs")')"
START=$SECONDS
areas_overlap "$WIDE" "$WIDE"
assert_eq "** on both sides is decided quickly" yes "$([ $((SECONDS - START)) -lt 5 ] && echo yes)"

ov() { if areas_overlap "$1" "$2"; then echo yes; else echo no; fi; }
assert_eq "a catch-all overlaps nothing"             no  "$(ov '**' src/a.rs)"
assert_eq "*.md is a real glob, not a catch-all"     yes "$(ov '*.md' README.md)"
assert_eq "**/*.rs is a real glob, not a catch-all"  yes "$(ov '**/*.rs' src/a.rs)"
assert_eq "real globs are kept by the parser" "$(printf '**/*.rs\n*.md')" \
  "$(touches_of "$(body_json 'Touches: **/*.rs, *.md, */**')")"
assert_eq "a fence closes only on its own marker" "real/" \
  "$(touches_of "$(body_json $'```\n~~~\nTouches: ex/\n```\nTouches: real/')")"
assert_eq "a longer fence is not closed by a shorter one" "real/" \
  "$(touches_of "$(body_json $'````\n```\nTouches: ex/\n````\nTouches: real/')")"
assert_eq "directory covers a file under it"        yes "$(ov src/web/ src/web/server.rs)"
assert_eq "directory without its slash still covers" yes "$(ov src/web src/web/x.rs)"
assert_eq "sibling prefix is not a parent"           no  "$(ov src/web src/webby/x.rs)"
assert_eq "exact paths: same"                        yes "$(ov a/b.rs a/b.rs)"
assert_eq "exact paths: different"                   no  "$(ov src/a.rs src/b.rs)"
assert_eq "glob matches a path"                      yes "$(ov 'tools/**/screensaver/*' tools/x/y/screensaver/a.c)"
assert_eq "glob misses a path"                       no  "$(ov 'tools/**/screensaver/*' tools/x/other.c)"
assert_eq "glob under a directory"                   yes "$(ov 'src/*/server.rs' src/web/)"
assert_eq "* stays in one segment"                   no  "$(ov 'src/*.rs' src/sub/a.rs)"
assert_eq "any entry of a list can overlap"          yes "$(ov "$(printf 'x/\nsrc/a.rs')" "$(printf 'y/\nsrc/a.rs')")"
assert_eq "an empty list never overlaps"             no  "$(ov '' src/)"

# ── Gate: claims.avoid_overlap ──────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
g() { git -c user.email=t@example.com -c user.name=T "$@"; }

git init -q --bare -b master "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
cd "$TMP/repo" || exit 1
echo base > f; g add f; g commit -qm base; g push -q origin HEAD:master

export ISSUE_SOURCE=file
export ISSUE_DIR_PATH="$TMP/issues"
WORK_JSON="$TMP/work.json"
# The worker-state record (#182) lives per worktree; keep it out of the way.
export AUTOCODER_RESUME_OWN_CLAIM=0

set_mode() {  # set_mode <off|prefer|strict|none|<anything>>
  if [ "$1" = none ]; then
    printf '{"issueSource":"file","issueDir":"%s"}\n' "$ISSUE_DIR_PATH" > .autocoder.json
  else
    printf '{"issueSource":"file","issueDir":"%s","claims":{"avoid_overlap":"%s"}}\n' \
      "$ISSUE_DIR_PATH" "$1" > .autocoder.json
  fi
}
reset_issues() {
  rm -rf "$ISSUE_DIR_PATH" "$WORK_JSON"
  mkdir -p "$ISSUE_DIR_PATH"/{open,working,blocked,closed}
}
add_issue() {  # add_issue <bucket> <num> <labels> <body>
  cat > "$ISSUE_DIR_PATH/$1/$(printf '%03d' "$2").md" <<EOF
---
number: $2
title: Issue $2
labels: [$3]
status: $1
---
$4
EOF
}
run_gate() { AUTOCODER_WORK_JSON="$WORK_JSON" bash "$SCRIPT_DIR/fix-loop-gate.sh" 2>"$TMP/gate.err"; echo $?; }
plan() { cat "$WORK_JSON" 2>/dev/null; }
fix_plan() { printf '{"phase":"fix","issue":%s,"priority":"%s"}' "$1" "$2"; }

# In flight: #9 holds src/web/server.rs. #1 (P0) touches src/web/, #2 (P1) docs/.
standard_issues() {
  reset_issues
  add_issue working 9 "bug, P1, working" "Touches: src/web/server.rs"
  add_issue open 1 "bug, P0" "Touches: src/web/"
  add_issue open 2 "bug, P1" "Touches: docs/"
}

# 1. off (no `claims` key): unchanged, the overlapping P0 is claimed.
set_mode none; standard_issues
assert_eq "no setting: gate finds work" 0 "$(run_gate)"
assert_eq "no setting: priority order unchanged" "$(fix_plan 1 P0)" "$(plan)"

set_mode off; standard_issues
run_gate >/dev/null
assert_eq "off: priority order unchanged" "$(fix_plan 1 P0)" "$(plan)"

# 2. prefer: the non-overlapping P1 goes first.
set_mode prefer; standard_issues
assert_eq "prefer: gate finds work" 0 "$(run_gate)"
assert_eq "prefer: the clear P1 beats the overlapping P0" "$(fix_plan 2 P1)" "$(plan)"
assert_eq "prefer: the overlapping P0 is left open" yes \
  "$([ -f "$ISSUE_DIR_PATH/open/001.md" ] && echo yes)"
assert_eq "prefer: says why" yes \
  "$(grep -q 'overlaps in-flight #9' "$TMP/gate.err" && echo yes)"

# 3. prefer: an overlapping candidate is still claimed when nothing else is.
set_mode prefer; reset_issues
add_issue working 9 "bug, P1, working" "Touches: src/web/server.rs"
add_issue open 1 "bug, P0" "Touches: src/web/"
run_gate >/dev/null
assert_eq "prefer: overlap claimed when it is all there is" "$(fix_plan 1 P0)" "$(plan)"

# 4. strict: overlapping candidates are skipped.
set_mode strict; standard_issues
run_gate >/dev/null
assert_eq "strict: the overlapping P0 is skipped" "$(fix_plan 2 P1)" "$(plan)"

set_mode strict; reset_issues
add_issue working 9 "bug, P1, working" "Touches: src/web/server.rs"
add_issue open 1 "bug, P0" "Touches: src/web/"
assert_eq "strict: only overlapping work → idle" 1 "$(run_gate)"
assert_eq "strict: nothing claimed" yes "$([ -f "$ISSUE_DIR_PATH/open/001.md" ] && echo yes)"
assert_eq "strict: no work plan written" "" "$(plan)"

# 5. Issues without declared areas are never blocked, on either side.
set_mode strict; reset_issues
add_issue working 9 "bug, P1, working" "Touches: src/web/server.rs"
add_issue open 1 "bug, P0" "No areas declared."
run_gate >/dev/null
assert_eq "strict: a candidate with no areas is claimed" "$(fix_plan 1 P0)" "$(plan)"

set_mode strict; reset_issues
add_issue working 9 "bug, P1, working" "No areas declared."
add_issue open 1 "bug, P0" "Touches: src/web/"
run_gate >/dev/null
assert_eq "strict: an in-flight issue with no areas blocks nothing" "$(fix_plan 1 P0)" "$(plan)"

# 6. Files Affected fallback is honoured by the gate.
set_mode strict; reset_issues
add_issue working 9 "bug, P1, working" $'## Files Affected\n- `src/web/server.rs`'
add_issue open 1 "bug, P0" $'## Files Affected\n- `src/web/server.rs` (+ mirrors)'
add_issue open 2 "bug, P1" $'## Files Affected\n- `docs/x.md`'
run_gate >/dev/null
assert_eq "strict: Files Affected areas overlap too" "$(fix_plan 2 P1)" "$(plan)"

# 7. Enhancements are reordered the same way.
set_mode prefer; reset_issues
add_issue working 9 "bug, P1, working" "Touches: src/"
add_issue open 3 "enhancement, P1" "Touches: src/a.rs"
add_issue open 4 "enhancement, P2" "Touches: docs/"
run_gate >/dev/null
assert_eq "prefer: enhancements reordered too" '{"phase":"enhance","issue":4}' "$(plan)"

# 8. An unknown mode warns and behaves as off.
set_mode sometimes; standard_issues
run_gate >/dev/null
assert_eq "unknown mode: behaves as off" "$(fix_plan 1 P0)" "$(plan)"
assert_eq "unknown mode: warns" yes \
  "$(grep -q "unknown claims.avoid_overlap 'sometimes'" "$TMP/gate.err" && echo yes)"

# 9. Triage still comes first, whatever the mode.
set_mode strict; reset_issues
add_issue working 9 "bug, P1, working" "Touches: src/"
add_issue open 1 "bug" "Touches: src/"
run_gate >/dev/null
assert_eq "triage is unaffected" '{"phase":"triage","issues":[1]}' "$(plan)"

# ── Hot files (#228) ────────────────────────────────────────────────────────
# shellcheck source=../plugins/autocoder/scripts/repo-id-fns.sh
source "$SCRIPT_DIR/repo-id-fns.sh"
REPO_ID="$(autocoder_repo_id "$PWD")"
EVENTS="$TMP/merge-events.jsonl"
ev() {  # ev <outcome> <files,comma-separated> [repo] [ts] [event]
  python3 -c 'import json,sys
o,f,r,t,e=sys.argv[1:6]
print(json.dumps({"ts":t,"repo":r,"issue":1,"event":e,"outcome":o,"files":[x for x in f.split(",") if x]}))' \
    "$1" "$2" "${3:-$REPO_ID}" "${4:-2026-11-17T00:00:00Z}" "${5:-attempt}" >> "$EVENTS"
}
hot_cfg() {  # hot_cfg <mode> [hot_window JSON value]
  printf '{"issueSource":"file","issueDir":"%s","claims":{"avoid_overlap":"%s"%s}}\n' \
    "$ISSUE_DIR_PATH" "$1" "${2:+,\"hot_window\":$2}" > .autocoder.json
}

# 10. No events file: no hot files, silently.
export AUTOCODER_MERGE_EVENTS="$EVENTS"
rm -f "$EVENTS"; hot_cfg prefer
assert_eq "no events file: no hot files" "" "$(touches_hot_files .autocoder.json "$REPO_ID" 2>"$TMP/hot.err")"
assert_eq "no events file: no warning" "" "$(cat "$TMP/hot.err")"

# 11. Window of attempts: a conflict older than the last 50 attempts is not hot.
ev conflict src/old.rs
for _ in $(seq 1 49); do ev landed src/x.rs; done
ev conflict "src/hot.rs,src/also.rs"
ev push-retry src/retry.rs "$REPO_ID" 2026-11-17T00:00:00Z push-retry   # not an attempt
ev conflict src/other.rs other-repo-0000000                               # another repo
echo 'not json' >> "$EVENTS"
assert_eq "window: recent conflicts are hot, older ones and other repos are not" \
  "$(printf 'src/also.rs\nsrc/hot.rs')" "$(touches_hot_files .autocoder.json "$REPO_ID")"
hot_cfg prefer 51
assert_eq "window: a larger window reaches the older conflict" \
  "$(printf 'src/also.rs\nsrc/hot.rs\nsrc/old.rs')" "$(touches_hot_files .autocoder.json "$REPO_ID")"

# 12. Window in days.
rm -f "$EVENTS"
ev conflict src/ancient.rs "$REPO_ID" 2020-01-01T00:00:00Z
ev conflict src/fresh.rs "$REPO_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
hot_cfg prefer '"7d"'
assert_eq "days window: only conflicts within the days" "src/fresh.rs" \
  "$(touches_hot_files .autocoder.json "$REPO_ID")"
hot_cfg prefer '"soon"'
assert_eq "bad window: falls back to 50 attempts" "$(printf 'src/ancient.rs\nsrc/fresh.rs')" \
  "$(touches_hot_files .autocoder.json "$REPO_ID" 2>"$TMP/hot.err")"
assert_eq "bad window: warns" yes "$(grep -q "unknown claims.hot_window 'soon'" "$TMP/hot.err" && echo yes)"

# 13. Manager listing: `touches-fns.sh hot` run directly in the repo.
assert_eq "touches-fns.sh hot lists the hot files" "$(printf 'src/ancient.rs\nsrc/fresh.rs')" \
  "$(bash "$SCRIPT_DIR/touches-fns.sh" hot 2>/dev/null)"

# 13b. Hot names are literal (escaped globs), and at most 200 are read.
rm -f "$EVENTS"; hot_cfg prefer
ev conflict 'app/[id]/page.tsx'
assert_eq "hot names: glob characters escaped" 'app/[[]id]/page.tsx' \
  "$(touches_hot_files .autocoder.json "$REPO_ID")"
assert_eq "hot names: an escaped name does not match a sibling" no \
  "$(areas_overlap 'app/[[]id]/page.tsx' 'app/x/page.tsx' && echo yes || echo no)"
assert_eq "hot names: an escaped name matches its directory" yes \
  "$(areas_overlap 'app/[[]id]/page.tsx' 'app/' && echo yes || echo no)"
rm -f "$EVENTS"
ev conflict "$(seq -s, -f 'old/f%g.rs' 1 300)"
ev conflict src/newest.rs
assert_eq "hot cap: at most 200 files" 200 "$(touches_hot_files .autocoder.json "$REPO_ID" | wc -l | tr -d ' ')"
assert_eq "hot cap: the most recent conflict is kept" yes \
  "$(touches_hot_files .autocoder.json "$REPO_ID" | grep -qx src/newest.rs && echo yes)"

# 14. Gate, prefer: two candidates on one hot file are never in flight at once.
rm -f "$EVENTS"; ev conflict src/web/server.rs
hot_cfg prefer; reset_issues
add_issue open 1 "bug, P0" "Touches: src/web/"
add_issue open 2 "bug, P1" "Touches: src/web/server.rs"
run_gate >/dev/null
assert_eq "hot, prefer: the first claim on a hot file goes ahead" "$(fix_plan 1 P0)" "$(plan)"
rm -f "$WORK_JSON"
run_gate >/dev/null; rc=$?
assert_eq "hot, prefer: a second claim on the same hot file is skipped" "" "$(plan)"
assert_eq "hot, prefer: says why" yes \
  "$(grep -q 'hot file src/web/server.rs is held by in-flight #1' "$TMP/gate.err" && echo yes)"
assert_eq "hot, prefer: #2 is left open" yes "$([ -f "$ISSUE_DIR_PATH/open/002.md" ] && echo yes)"

# 15. prefer: a held hot file skips the candidate; one nobody holds does not.
reset_issues
add_issue working 9 "bug, P1, working" "Touches: src/web/server.rs"
add_issue open 1 "bug, P0" "Touches: src/web/"
add_issue open 3 "bug, P2" "Touches: docs/"
run_gate >/dev/null
assert_eq "hot, prefer: clear work is claimed instead" "$(fix_plan 3 P2)" "$(plan)"
rm -f "$EVENTS"; ev conflict src/web/other.rs; reset_issues
add_issue working 9 "bug, P1, working" "Touches: src/web/server.rs"
add_issue open 1 "bug, P0" "Touches: src/web/"
run_gate >/dev/null
assert_eq "prefer: a hot file nobody holds does not skip the overlap" "$(fix_plan 1 P0)" "$(plan)"

# 16. strict skips hot conflicts the same way; off ignores hot files.
rm -f "$EVENTS"; ev conflict src/web/server.rs
hot_cfg strict; reset_issues
add_issue working 9 "bug, P1, working" "Touches: src/web/server.rs"
add_issue open 1 "bug, P0" "Touches: src/web/server.rs"
assert_eq "hot, strict: idle" 1 "$(run_gate)"
hot_cfg off; reset_issues
add_issue working 9 "bug, P1, working" "Touches: src/web/server.rs"
add_issue open 1 "bug, P0" "Touches: src/web/server.rs"
run_gate >/dev/null
assert_eq "hot, off: unchanged" "$(fix_plan 1 P0)" "$(plan)"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
