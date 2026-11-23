#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"  # #255: never write the real event logs
# tests/test_issues_gh_link.sh — the GitHub backend's `link` verb (#343).
#
# `link N --blocked-by M` adds a native "blocked by" relationship. GitHub's REST
# endpoint takes the blocker's database id, so the backend reads it first. A
# stub `gh` records every call; nothing here reaches GitHub.

PASS=0; FAIL=0
BACKEND="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugins/autocoder/scripts/issues-gh.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2' got '$3'"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "api repos/{owner}/{repo}/issues/12 --jq .id") echo 9012 ;;
  "api repos/{owner}/{repo}/issues/"*" --jq .id") echo "Not Found" >&2; exit 1 ;;
  "api -X POST repos/{owner}/{repo}/issues/7/dependencies/blocked_by -F issue_id=9012") echo '{}' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export GH_LOG="$TMP/gh.log"

run() { : > "$GH_LOG"; PATH="$TMP/bin:$PATH" bash "$BACKEND" "$@" >/dev/null 2>&1; RC=$?; }

run link 7 --blocked-by 12
eq "link exits 0" "0" "$RC"
eq "link looks up the blocker's id, then POSTs it as blocked_by" \
  "api repos/{owner}/{repo}/issues/12 --jq .id|api -X POST repos/{owner}/{repo}/issues/7/dependencies/blocked_by -F issue_id=9012" \
  "$(paste -sd'|' "$GH_LOG")"

run link 7 --blocked-by 404
eq "link to a missing blocker exits 1" "1" "$RC"
eq "and writes nothing" "1" "$(wc -l < "$GH_LOG" | tr -d ' ')"

run link 7 --blocked-by 7
eq "a self-link exits 2" "2" "$RC"
run link 7 --blocked-by '5/../x'
eq "a non-numeric blocker exits 2 and calls nothing" "2|0" "$RC|$(wc -l < "$GH_LOG" | tr -d ' ')"

run link 7
eq "link without --blocked-by exits 2" "2" "$RC"

run link 7 --blocked-by 12 --bogus
eq "link with an unknown option exits 2" "2" "$RC"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
