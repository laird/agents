#!/bin/bash
# tests/test_claim_overlap.sh — overlap-aware claim selection (#227, sub-task of #186).
#
# An issue declares the areas it will edit (`Touches:` line, or the backticked
# paths under `## Files Affected`). With `.autocoder.json` `claims.avoid_overlap`
# the fix-loop gate tries candidates that overlap an in-flight `working` issue
# last (`prefer`) or not at all (`strict`); `off`, the default, is unchanged.
#
# Runs in a private temp repo with its own .autocoder.json (file backend), so it
# never touches the real tracker.

PASS=0; FAIL=0
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

ov() { if areas_overlap "$1" "$2"; then echo yes; else echo no; fi; }
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

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
