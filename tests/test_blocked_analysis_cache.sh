#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_blocked_analysis_cache.sh — the per-issue analysis cache for blocked
# issues (#310, part of #308).
#
# put stores an analysis under the repo's git common dir (shared by worktrees);
# get returns it only for the same updatedAt and exits 1 when missing or stale;
# put refuses a malformed analysis with a reason and a non-zero exit; list reports
# every entry with a stale flag computed offline against --current.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/plugins/autocoder/scripts/blocked-analysis-cache.py"

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset AUTOCODER_BLOCKED_CACHE_DIR
g() { git -c user.email=t@example.com -c user.name=T "$@"; }

cd "$TMP" || exit 1
git init -q -b master repo; cd repo || exit 1
printf 'a\n' > f; g add .; g commit -qm base
g worktree add -q ../wt -b side

cat > "$TMP/good.json" <<'JSON'
{"summary": "Pick a storage backend",
 "options": [
   {"title": "SQLite", "pros": ["one file"], "cons": ["locking"], "effort": "small"},
   {"title": "JSON files", "pros": ["no dependency"], "cons": ["no queries"], "effort": "tiny"}
 ],
 "recommended": 1}
JSON

python3 "$S" put 42 --updated-at 2026-11-20T10:00:00Z --file "$TMP/good.json" >/dev/null
eq "put of a valid analysis exits 0" "$?" 0
CACHE="$(git rev-parse --path-format=absolute --git-common-dir)/autocoder-blocked-analyses/42.json"
[ -f "$CACHE" ] && ok "the entry lands under the git common dir" || bad "no entry at $CACHE"

OUT=$(python3 "$S" get 42 --updated-at 2026-11-20T10:00:00Z); RC=$?
eq "get with the same updatedAt exits 0" "$RC" 0
eq "get prints the analysis" "$(printf '%s' "$OUT" | jq -r '.options[1].title')" "JSON files"

OUT=$(cd ../wt && python3 "$S" get 42 --updated-at 2026-11-20T10:00:00Z | jq -r .recommended)
eq "another worktree of the repo reads the same cache" "$OUT" 1

ERR=$(python3 "$S" get 42 --updated-at 2026-11-21T09:00:00Z 2>&1 >/dev/null); RC=$?
eq "get with a changed updatedAt exits 1" "$RC" 1
case "$ERR" in *stale*) ok "get says the entry is stale" ;; *) bad "stale get said: $ERR" ;; esac

python3 "$S" get 7 --updated-at x >/dev/null 2>&1
eq "get of an uncached issue exits 1" "$?" 1

# Malformed analyses: each is refused with a reason naming the problem.
refuse() {  # name, json, expected substring
  printf '%s' "$2" > "$TMP/bad.json"
  local err rc
  err=$(python3 "$S" put 43 --updated-at t --file "$TMP/bad.json" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && [[ "$err" == *"$3"* ]]; then ok "refuses $1"
  else bad "$1 — rc=$rc, said: $err"; fi
}
refuse "invalid JSON" '{"summary":' "not valid JSON"
refuse "a non-object" '[1,2]' "must be a JSON object"
refuse "one option" '{"summary":"s","options":[{"title":"a","pros":["p"],"cons":["c"],"effort":"e"}],"recommended":0}' "2 or 3 options"
refuse "four options" '{"summary":"s","options":[{},{},{},{}],"recommended":0}' "2 or 3 options"
refuse "an option without pros" '{"summary":"s","options":[{"title":"a","cons":["c"],"effort":"e"},{"title":"b","pros":["p"],"cons":["c"],"effort":"e"}],"recommended":0}' "options[0].pros"
refuse "a missing effort" '{"summary":"s","options":[{"title":"a","pros":["p"],"cons":["c"]},{"title":"b","pros":["p"],"cons":["c"],"effort":"e"}],"recommended":0}' "options[0].effort"
refuse "recommended out of range" '{"summary":"s","options":[{"title":"a","pros":["p"],"cons":["c"],"effort":"e"},{"title":"b","pros":["p"],"cons":["c"],"effort":"e"}],"recommended":2}' "outside options"
refuse "a boolean recommended" '{"summary":"s","options":[{"title":"a","pros":["p"],"cons":["c"],"effort":"e"},{"title":"b","pros":["p"],"cons":["c"],"effort":"e"}],"recommended":true}' "integer index"
refuse "a multi-line summary" '{"summary":"a\nb","options":[{"title":"a","pros":["p"],"cons":["c"],"effort":"e"},{"title":"b","pros":["p"],"cons":["c"],"effort":"e"}],"recommended":0}' "one line"
[ -f "$(dirname "$CACHE")/43.json" ] && bad "a refused analysis was cached" || ok "a refused analysis leaves no entry"

python3 "$S" put abc --updated-at t --file "$TMP/good.json" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "put refuses a non-numeric issue" || bad "put accepted issue 'abc'"

# put replaces an earlier entry.
python3 "$S" put 42 --updated-at 2026-11-21T09:00:00Z --file "$TMP/good.json" >/dev/null
python3 "$S" get 42 --updated-at 2026-11-21T09:00:00Z >/dev/null
eq "a second put replaces the entry's updatedAt" "$?" 0
python3 "$S" get 42 --updated-at 2026-11-20T10:00:00Z >/dev/null 2>&1
eq "after the second put the old updatedAt reads stale" "$?" 1

python3 "$S" put 44 --updated-at "" --file "$TMP/good.json" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "put refuses an empty --updated-at" || bad "put accepted an empty --updated-at"

touch "$(dirname "$CACHE")/².json" "$(dirname "$CACHE")/notes.json"

python3 "$S" put 5 --updated-at old --file "$TMP/good.json" >/dev/null
OUT=$(python3 "$S" list)
eq "list without --current names every entry, in order" "$(printf '%s' "$OUT" | jq -c '[.[].number]')" "[5,42]"
eq "list without --current leaves stale null" "$(printf '%s' "$OUT" | jq -c '[.[].stale]')" "[null,null]"

printf '{"issues":[{"number":5,"updatedAt":"new"},{"number":42,"updatedAt":"2026-11-21T09:00:00Z"}]}' > "$TMP/cur.json"
OUT=$(python3 "$S" list --current "$TMP/cur.json")
eq "list --current flags the changed issue stale and the other fresh" \
  "$(printf '%s' "$OUT" | jq -c '[.[] | [.number, .stale]]')" "[[5,true],[42,false]]"
eq "list reports each entry's updatedAt" "$(printf '%s' "$OUT" | jq -r '.[0].updatedAt')" "old"

printf '[{"number":42,"updatedAt":"zzz"}]' > "$TMP/cur.json"
OUT=$(python3 "$S" list --current "$TMP/cur.json")
eq "list --current takes a bare list too; unmentioned issues stay null" \
  "$(printf '%s' "$OUT" | jq -c '[.[] | [.number, .stale]]')" "[[5,null],[42,true]]"

mkdir -p "$TMP/ro"; chmod 555 "$TMP/ro"
if [ -w "$TMP/ro" ]; then ok "unwritable cache check skipped (running as root)"; else
  ERR=$(AUTOCODER_BLOCKED_CACHE_DIR="$TMP/ro/c" python3 "$S" put 9 --updated-at t --file "$TMP/good.json" 2>&1); RC=$?
  if [ "$RC" -eq 2 ] && [[ "$ERR" == "blocked-analysis-cache: cannot write"* ]]; then ok "an unwritable cache fails with a message, exit 2"
  else bad "unwritable cache — rc=$RC, said: $ERR"; fi
fi
chmod 755 "$TMP/ro"

(cd "$TMP" && python3 "$S" list >/dev/null 2>&1); eq "outside a git repository the script exits 2" "$?" 2

OUT=$(AUTOCODER_BLOCKED_CACHE_DIR="$TMP/empty" python3 "$S" list)
eq "list of an empty cache prints []" "$(printf '%s' "$OUT" | jq -c .)" "[]"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
