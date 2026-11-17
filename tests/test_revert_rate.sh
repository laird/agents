#!/bin/bash
# tests/test_revert_rate.sh — revert-rate.sh counts sentinel reverts by their
# Autocoder-Reverts trailers, never by the word "revert" (#250).
# Everything runs in a private temp git repo; nothing touches the issue layer.

PASS=0; FAIL=0
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/plugins/autocoder/scripts/revert-rate.sh"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
git init -q -b master "$REPO"
cd "$REPO" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false

N=0
commit() {  # commit <date> <message paragraphs...>
  local date="$1"; shift
  N=$((N + 1)); echo "$N" > f
  local args=(); for p in "$@"; do args+=(-m "$p"); done
  git add f
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" git commit -q "${args[@]}"
}

# Oldest first. Issues 1..6 land; the sentinel reverts #2 and #5; two commits only
# mention reverting; #3 has a review-round commit; one commit is no issue at all.
commit "2026-01-01T00:00:00Z" "#1: first"
commit "2026-01-02T00:00:00Z" "#2: second"
commit "2026-01-03T00:00:00Z" "Revert autocoder push abc1234 (issue #2)" "Range a..b" \
  "Autocoder-Reverts: abc1234
Autocoder-Reverts-Issue: 2"
commit "2026-02-01T00:00:00Z" "#3: third"
commit "2026-02-02T00:00:00Z" "#3 review round 1: fix it"
commit "2026-02-03T00:00:00Z" "Revert \"#3: third\"" "This reverts commit deadbeef."
commit "2026-02-04T00:00:00Z" "#4: revert the old parser to the stable one"
commit "2026-02-05T00:00:00Z" "docs: tidy"
commit "2026-03-01T00:00:00Z" "Issue #5: feature/issue-5 (squashed: the branch contained merge commits)"
commit "2026-03-02T00:00:00Z" "Revert autocoder push def5678 (issue #5)" "Range c..d" \
  "Autocoder-Reverts: def5678
Autocoder-Reverts-Issue: 5"
commit "2026-03-03T00:00:00Z" "Fix #6: old-style title"

J=$(bash "$SCRIPT" --ref HEAD --json)
eq "default window: landed issues"   "6"       "$(jq -r .landed <<<"$J")"
eq "default window: trailer reverts" "2"       "$(jq -r .reverts <<<"$J")"
eq "default window: rate"            "0.3333"  "$(jq -r .rate <<<"$J")"
eq "default window: reverted issues" "[2,5]"   "$(jq -c .reverted_issues <<<"$J")"
eq "default window: shape"           '["landed","rate","reverted_issues","reverts","window"]' "$(jq -c 'keys' <<<"$J")"
eq "default window: window"          '{"ref":"HEAD","last":50}' "$(jq -c .window <<<"$J")"

# --last 2: the newest two issues are #6 and #5; #5's revert lies inside that window.
J=$(bash "$SCRIPT" --ref HEAD --last 2 --json)
eq "--last 2: landed"  "2"   "$(jq -r .landed <<<"$J")"
eq "--last 2: reverts" "1"   "$(jq -r .reverts <<<"$J")"
eq "--last 2: issues"  "[5]" "$(jq -c .reverted_issues <<<"$J")"
eq "--last 2: rate"    "0.5" "$(jq -r .rate <<<"$J")"

# --last 4: #6 #5 #4 #3. A multi-commit issue counts once; the keyword revert of #3 is not one.
J=$(bash "$SCRIPT" --ref HEAD --last 4 --json)
eq "--last 4: landed"  "4" "$(jq -r .landed <<<"$J")"
eq "--last 4: reverts" "1" "$(jq -r .reverts <<<"$J")"

# --last never counts a revert of an issue outside the window, however new the revert.
commit "2026-04-01T00:00:00Z" "#7: seventh"
commit "2026-04-02T00:00:00Z" "Revert autocoder push aaa1111 (issue #1)" "Range e..f" \
  "Autocoder-Reverts: aaa1111
Autocoder-Reverts-Issue: 1"
J=$(bash "$SCRIPT" --ref HEAD --last 1 --json)
eq "--last 1: revert of an older issue not counted" "0" "$(jq -r .reverts <<<"$J")"
eq "--last 1: reverted issues empty"                "[]" "$(jq -c .reverted_issues <<<"$J")"
J=$(bash "$SCRIPT" --ref HEAD --since 2026-04-01T00:00:00Z --json)
eq "--since counts every revert made in the window" "1" "$(jq -r .reverts <<<"$J")"
git reset -q --hard HEAD~2

# --since: February onward holds #3 #4 #5 #6 and only #5's revert.
J=$(bash "$SCRIPT" --ref HEAD --since 2026-02-01T00:00:00Z --json)
eq "--since: landed"  "4"   "$(jq -r .landed <<<"$J")"
eq "--since: reverts" "1"   "$(jq -r .reverts <<<"$J")"
eq "--since: window"  '{"ref":"HEAD","since":"2026-02-01T00:00:00Z"}' "$(jq -c .window <<<"$J")"

# A window with nothing landed has no rate.
J=$(bash "$SCRIPT" --ref HEAD --since 2027-01-01 --json)
eq "empty window: landed" "0"    "$(jq -r .landed <<<"$J")"
eq "empty window: rate"   "null" "$(jq -r .rate <<<"$J")"

# Human output is one line.
OUT=$(bash "$SCRIPT" --ref HEAD)
eq "human output is one line" "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
case "$OUT" in *"2 sentinel revert(s) / 6 landed issue(s) = 33.3%; reverted: #2, #5"*) ok "human line content" ;;
  *) bad "human line content — got '$OUT'" ;; esac

# Default ref: origin/HEAD when there is one.
git clone -q "$REPO" "$TMP/clone"
J=$(cd "$TMP/clone" && bash "$SCRIPT" --json)
eq "default ref is origin/HEAD" "origin/HEAD" "$(jq -r .window.ref <<<"$J")"
eq "origin/HEAD history read"   "6"           "$(jq -r .landed <<<"$J")"

# Usage errors.
bash "$SCRIPT" --last 0 >/dev/null 2>&1;            eq "--last 0 rejected"        "2" "$?"
bash "$SCRIPT" --last x >/dev/null 2>&1;            eq "--last x rejected"        "2" "$?"
bash "$SCRIPT" --last 2 --since 2026-01-01 >/dev/null 2>&1; eq "both windows rejected" "2" "$?"
bash "$SCRIPT" --bogus >/dev/null 2>&1;             eq "unknown flag rejected"    "2" "$?"
bash "$SCRIPT" --ref --json >/dev/null 2>&1;        eq "option-shaped ref rejected" "2" "$?"
bash "$SCRIPT" --ref nosuchref >/dev/null 2>&1;     eq "missing ref fails"        "1" "$?"

echo ""
echo "Tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
