#!/bin/bash
# tests/test_merge_archive_fns.sh — merge attempts are archived, never lost (#184).
#
# merge-launch.sh archives the previous attempt before a relaunch, and main-sentinel.sh
# archives a day-old finished attempt instead of deleting it (it used to delete
# <base>.{log,exit} after a day, and its glob also caught the archives). Attempt
# numbers never repeat, archives are pruned only after AUTOCODER_MERGE_ARCHIVE_DAYS,
# and live or recent jobs are left alone.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../plugins/autocoder/scripts/merge-archive-fns.sh
source "$ROOT/plugins/autocoder/scripts/merge-archive-fns.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
B="$TMP/autocoder-merge-repo-1a2b-42"
job() { echo "$2" > "$1.log"; echo "$3" > "$1.exit"; echo 999999 > "$1.pid"; echo x > "$1.run.sh"; }
old() { touch -d '2 days ago' "$@"; }

# ── archive_attempt / next_attempt ─────────────────────────────────────────
eq "no attempts yet: next is 1" "1" "$(merge_next_attempt "$B")"
merge_archive_attempt "$B"; [ ! -e "$B.1.log" ] && ok "nothing to archive: no-op" || bad "archived from nothing"
job "$B" "first" 1; merge_archive_attempt "$B"
eq "first attempt archived as .1" "first 1" "$(cat "$B.1.log") $(cat "$B.1.exit")"
[ ! -e "$B.log" ] && [ ! -e "$B.exit" ] && ok "current names freed" || bad "current files remain"
eq "next is 2" "2" "$(merge_next_attempt "$B")"
job "$B" "second" 0; merge_archive_attempt "$B"
eq "second archived as .2" "second" "$(cat "$B.2.log")"
rm -f "$B.1.log"   # a pruned log must not reuse its number while its .exit remains
eq "numbering counts .exit archives too" "3" "$(merge_next_attempt "$B")"
B9="$TMP/autocoder-merge-repo-1a2b-4"   # issue 4 must not see issue 42's archives
eq "another issue's archives are not counted" "1" "$(merge_next_attempt "$B9")"

# ── reap_finished: the sentinel's day-old sweep ────────────────────────────
rm -f "$TMP"/autocoder-merge-*
job "$B" "old finished" 1; old "$B.exit" "$B.log"
L="$TMP/autocoder-merge-repo-1a2b-7"; job "$L" "live" 0; old "$L.exit"
R="$TMP/autocoder-merge-repo-1a2b-8"; job "$R" "recent" 0
is_live() { [ "$1" = "$L" ]; }
merge_reap_finished "$TMP" is_live
eq "day-old finished job archived, not deleted" "old finished" "$(cat "$B.1.log" 2>/dev/null)"
[ ! -e "$B.pid" ] && [ ! -e "$B.run.sh" ] && [ ! -e "$B.exit" ] && ok "its control files retired" || bad "control files left"
[ -e "$L.log" ] && [ -e "$L.exit" ] && ok "live job untouched" || bad "live job reaped"
[ -e "$R.log" ] && [ -e "$R.exit" ] && ok "recent job untouched" || bad "recent job reaped"
merge_reap_finished "$TMP" is_live
[ -e "$B.1.log" ] && [ ! -e "$B.2.log" ] && ok "archives are not re-archived by a second sweep" || bad "second sweep touched archives"

# A repo id with ".<digit>" in it is not an archive (only <base>.<digits>.exit is).
D="$TMP/autocoder-merge-my.2app-1a2b-9"; job "$D" "dotted" 0; old "$D.exit" "$D.log"
merge_reap_finished "$TMP" is_live
eq "a dotted repo id's job is still archived" "dotted" "$(cat "$D.1.log" 2>/dev/null)"
D2="$TMP/autocoder-merge-my.2app-1a2b-10"; echo live > "$D2.log"; touch -d '20 days ago' "$D2.log"
merge_reap_finished "$TMP" is_live
[ -e "$D2.log" ] && ok "a dotted repo id's current log is never pruned as an archive" || bad "current dotted log pruned"

# Retention counts from archiving: an attempt archived late is not pruned at once.
LT="$TMP/autocoder-merge-repo-1a2b-11"; job "$LT" "late" 1; touch -d '20 days ago' "$LT.log" "$LT.exit"
merge_archive_attempt "$LT"; merge_reap_finished "$TMP" is_live
[ -e "$LT.1.log" ] && ok "a late-archived attempt is kept for the full retention" || bad "late archive pruned at once"

# ── archive retention ──────────────────────────────────────────────────────
touch -d '20 days ago' "$B.1.log" "$B.1.exit"
echo keep > "$B.2.log"; echo 0 > "$B.2.exit"
merge_reap_finished "$TMP" is_live
[ ! -e "$B.1.log" ] && [ ! -e "$B.1.exit" ] && ok "archives past 14 days pruned" || bad "old archive kept"
[ -e "$B.2.log" ] && ok "recent archive kept" || bad "recent archive pruned"
touch -d '20 days ago' "$B.2.log"
AUTOCODER_MERGE_ARCHIVE_DAYS=30 merge_reap_finished "$TMP" is_live
[ -e "$B.2.log" ] && ok "AUTOCODER_MERGE_ARCHIVE_DAYS extends retention" || bad "retention override ignored"

echo ""
echo "Tests: $FAIL failed, $PASS passed, $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
