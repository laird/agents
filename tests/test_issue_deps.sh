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
