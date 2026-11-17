#!/bin/bash
# tests/test_issue_deps.sh — issue dependencies (issue-deps.sh).
#
# Workers must work issues in an order their dependencies allow: the claimable
# queue (`issue_list --state open`) leaves out issues whose "Depends on" /
# "Blocked by" issues are still open, `issue_any_claimable` agrees, and
# `issue_unmet_dependencies` names what an explicitly dispatched issue waits on.
#
# Like test_issue_fns.sh, this runs the file backend inside a throwaway git
# repo with a poisoned `gh`, so nothing here can reach a real tracker.

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../plugins/autocoder/scripts" && pwd)"

ok()   { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }

# The tracker comes from the throwaway repo's .autocoder.json alone. An inherited
# ISSUE_SOURCE (a worker or merge job exports github) would make issue-config.sh
# warn on stderr, and the stderr checks below compare it exactly.
unset ISSUE_SOURCE ISSUE_BACKEND ISSUE_DIR
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ISSUES_DIR="$TMP/.issues"
mkdir -p "$ISSUES_DIR/open" "$ISSUES_DIR/working" "$ISSUES_DIR/blocked" "$ISSUES_DIR/closed"
git -C "$TMP" init -q
cat > "$TMP/.autocoder.json" <<EOF
{ "issueSource": "file", "issueDir": "$ISSUES_DIR" }
EOF
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/bin/bash
echo "REAL gh INVOKED FROM TEST: \$*" >> "$TMP/gh-was-called"
exit 97
EOF
chmod +x "$TMP/bin/gh"

run() { (cd "$TMP" && PATH="$TMP/bin:$PATH" bash -c "source '$SCRIPT_DIR/issue-fns.sh'; $1") 2>/dev/null; }
run_err() { (cd "$TMP" && PATH="$TMP/bin:$PATH" bash -c "source '$SCRIPT_DIR/issue-fns.sh'; $1" 2>&1 >/dev/null); }

issue() {  # issue <bucket> <number> <title> <body>
  printf -- '---\nnumber: %s\ntitle: %s\nlabels: [P1, subtask]\nstatus: %s\n---\n%b\n' \
    "$2" "$3" "$1" "$4" > "$ISSUES_DIR/$1/$(printf '%03d' "$2").md"
}

# A feature split like autocoder's decomposition template writes it:
#   10 (closed)  ← 11 depends on 10 → free
#   12 (open)    ← 13 depends on 11 and 12 → waits on both
#   14 "Blocked by #12" → waits; 15 names only its parent and a parallel sibling → free
#   16 depends on a number that doesn't exist → fails open, free
#   17 depends on 18, which is being worked → waits
issue closed  10 "Schema"        "Done already."
issue open    11 "Model"         "## Dependencies\n- Sub-task of #9\n- Depends on: #10 — needs the schema"
issue open    12 "Fetch"         "## Dependencies\n- Sub-task of #9\n- Can run in parallel with: #11"
issue open    13 "Wire up"       "## Dependencies\n- Sub-task of #9\n- **Depends on: #11 and #12** (consumes both)"
issue open    14 "Docs"          "Blocked by #12."
issue open    15 "Renderer"      "## Dependencies\n- Sub-task of #9\n- Can run in parallel with: #12, #13\n- [Depends on: #<sibling-subtask-number> — template placeholder]"
issue open    16 "Typo dep"      "Depends on #999"
issue working 18 "In flight"     "Being worked."
issue open    17 "After flight"  "Depends on: #18"

OPEN=$(run "issue_list --state open | jq -c '[.[].number] | sort'")
check "open queue leaves out issues with open dependencies" "$OPEN" "[11,12,15,16]"

DEFAULT=$(run "issue_list | jq -c '[.[].number] | sort'")
check "list with no --state is the claimable queue too" "$DEFAULT" "[11,12,15,16]"

ALL=$(run "issue_list --state all | jq 'length'")
check "--state all is not filtered" "$ALL" "9"

WAITS=$(run_err "issue_list --state open")
case "$WAITS" in *"#13 waits on #11, #12"*) ok "waiting issues are reported on stderr" ;; *) bad "stderr names #13's dependencies — got: $WAITS" ;; esac

OUT=$(run "issue_unmet_dependencies 13; echo rc=\$?")
check "unmet dependencies of #13" "$OUT" "#11 #12
rc=1"
OUT=$(run "issue_unmet_dependencies 11; echo rc=\$?")
check "#11's only dependency is closed" "$OUT" "rc=0"
OUT=$(run "issue_unmet_dependencies 17; echo rc=\$?")
check "a dependency being worked is still unmet" "$OUT" "#18
rc=1"

IGN=$(run "AUTOCODER_IGNORE_DEPENDENCIES=1 issue_list --state open | jq 'length'")
check "AUTOCODER_IGNORE_DEPENDENCIES=1 turns the filter off" "$IGN" "7"

# Closing the dependencies frees the dependent.
mv "$ISSUES_DIR/open/011.md" "$ISSUES_DIR/closed/011.md"; sed -i 's/^status: open/status: closed/' "$ISSUES_DIR/closed/011.md"
mv "$ISSUES_DIR/open/012.md" "$ISSUES_DIR/closed/012.md"; sed -i 's/^status: open/status: closed/' "$ISSUES_DIR/closed/012.md"
OPEN=$(run "issue_list --state open | jq -c '[.[].number] | sort'")
check "closing #11 and #12 frees #13 and #14" "$OPEN" "[13,14,15,16]"

# any-claimable is false when every open issue is waiting.
rm -f "$ISSUES_DIR"/open/*.md
issue open 20 "Blocked one" "Depends on: #18"
run "issue_any_claimable"; RC=$?
check "any-claimable is false when every open issue waits" "$RC" "1"
issue open 21 "Free one" "No dependencies."
run "issue_any_claimable"; RC=$?
check "any-claimable is true once one is free" "$RC" "0"

# #181: only a line that STARTS with the declaration counts. Prose that uses the
# words mid-sentence declares nothing; an issue never waits on itself, its
# parent or its own sub-tasks; issues that wait on each other are reported.
rm -f "$ISSUES_DIR"/open/*.md
issue open    30 "Prose"         "Whether this depends on #31 is unclear.\nIt was blocked by #32 last week, per the thread."
issue open    31 "Forms"         "Depends on: #40\n- **Blocked by #41**\n  1. depends on #42\n> - [Depends on: #43 — needs it]\n- [ ] Blocked by #44"
issue open    32 "Self"          "Depends on: #32"
issue open    33 "Parent"        "## Sub-task of #34\n- Sub-task of #34\n- Depends on: #34"
issue open    34 "Parent issue"  "Sub-tasks, in order:\nDepends on: #33, #35"
issue working 35 "Child at work" "## Sub-task of #34\nBeing worked."
issue open    36 "Cycle A"       "Depends on: #37"
issue open    37 "Cycle B"       "Blocked by #36"
issue open    38 "Ring A"        "Depends on: #39"
issue open    39 "Ring B"        "Depends on: #45"
issue open    45 "Ring C"        "Depends on: #38"
issue open    46 "Mention"       "Depends on: #47\nUnlike the earlier sub-task of #47, this one is small."
issue open    47 "Prereq"        "Nothing."
issue open    48 "Heading"       "### Blocked by: #47"
for n in 40 41 42 43 44; do issue open "$n" "Dep $n" "Nothing."; done

OUT=$(run "issue_list --state open | jq -c '[.[].number] | sort'")
check "prose, self, parent and children don't gate; declared lines do" "$OUT" "[30,32,33,34,40,41,42,43,44,47]"
DEPS=$(run "issue_list --state all | _ideps_body_deps | jq -c '{\"30\": .[\"30\"], \"31\": .[\"31\"], \"32\": .[\"32\"], \"33\": .[\"33\"]}'")
check "declared forms parsed; prose, self and parent dropped" "$DEPS" '{"30":[],"31":[40,41,42,43,44],"32":[],"33":[]}'
WAITS=$(run_err "issue_list --state open")
case "$WAITS" in *"#31 waits on #40, #41, #42, #43, #44"*) ok "#31 waits on every declared line" ;; *) bad "#31's waits — got: $WAITS" ;; esac
case "$WAITS" in *"⚠ cycle: #36 ↔ #37"*) ok "a two-issue cycle is reported" ;; *) bad "two-issue cycle not reported — got: $WAITS" ;; esac
case "$WAITS" in *"⚠ cycle: #38 → #39 → #45 → #38"*) ok "a longer cycle is reported once" ;; *) bad "ring not reported — got: $WAITS" ;; esac
N=$(printf '%s\n' "$WAITS" | grep -c '⚠ cycle')
check "each cycle reported exactly once" "$N" "2"
case "$WAITS" in *"#34 waits"*|*"#33 waits"*) bad "parent/child gated — got: $WAITS" ;; *) ok "parent and child don't gate each other" ;; esac

OUT=$(run "issue_unmet_dependencies 34; echo rc=\$?")
check "a parent doesn't wait on its own sub-tasks (open or being worked)" "$OUT" "rc=0"
OUT=$(run "issue_unmet_dependencies 30; echo rc=\$?")
check "prose mentions are not dependencies" "$OUT" "rc=0"
OUT=$(run "issue_unmet_dependencies 46; echo rc=\$?")
check "a 'sub-task of' mention mid-sentence is not a parent" "$OUT" "#47
rc=1"
OUT=$(run "issue_unmet_dependencies 48; echo rc=\$?")
check "a heading can declare a dependency" "$OUT" "#47
rc=1"
ERR=$(run_err "issue_unmet_dependencies 36")
check "explicit dispatch reports a cycle" "$ERR" "⚠ cycle: #36 ↔ #37"

# Native GitHub blocked-by: the GraphQL answer becomes open blockers per issue.
NATIVE=$(bash -c "
  gh() { case \"\$1\" in
    repo) echo 'acme/shop' ;;
    api) echo '{\"data\":{\"repository\":{\"issues\":{\"nodes\":[{\"number\":5,\"blockedBy\":{\"nodes\":[{\"number\":3,\"state\":\"OPEN\"},{\"number\":2,\"state\":\"CLOSED\"}]}},{\"number\":6,\"blockedBy\":{\"nodes\":[]}}]}}}}' ;;
  esac; }
  source '$SCRIPT_DIR/issue-deps.sh'; _ideps_gh_blockers")
check "GitHub blocked-by keeps only open blockers" "$NATIVE" '{"5":[3],"6":[]}'
NATIVE=$(bash -c "gh() { return 1; }; source '$SCRIPT_DIR/issue-deps.sh'; _ideps_gh_blockers")
check "GitHub blocked-by fails open" "$NATIVE" "{}"

[ -f "$TMP/gh-was-called" ] && bad "gh was invoked: $(cat "$TMP/gh-was-called")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
