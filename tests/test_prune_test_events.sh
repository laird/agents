#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"
# tests/test_prune_test_events.sh — prune-test-events.sh (#282) drops records whose
# repo is not a known repo's id, keeps everything it cannot read, backs the file up,
# changes nothing on a dry run, and refuses when it knows no repo at all.

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRUNE="$ROOT/plugins/autocoder/scripts/prune-test-events.sh"
source "$ROOT/plugins/autocoder/scripts/repo-id-fns.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git init -q "$TMP/realrepo"
REAL_ID=$(autocoder_repo_id "$TMP/realrepo")
STATE="$TMP/state"
reset() {
  rm -rf "$STATE"; mkdir -p "$STATE"
  {
    printf '{"repo":"%s","issue":1}\n' "$REAL_ID"
    printf '{"repo":"worker-1234abcd","issue":19204}\n'
    printf '{"repo":null,"issue":2}\n'
    printf '{"issue":3}\n'
    printf 'not json\n'
    printf '{"repo":"other-5678","issue":4}\n'
  } > "$STATE/merge-events.jsonl"
  printf '{"repo":"worker-1","issue":5}\n{"repo":"%s","issue":6}\n' "$REAL_ID" > "$STATE/issue-events.jsonl"
  printf '{"kind":"batch"}\n' > "$STATE/landing-timings.jsonl"
  chmod 600 "$STATE"/*.jsonl
}
issues_in() { python3 -c 'import json,sys
for l in open(sys.argv[1]):
    try: print(json.loads(l).get("issue"))
    except ValueError: print("bad")' "$1" | tr '\n' ' '; }

echo "=== no known repo: refuse ==="
reset
: > "$AUTOCODER_REBOOT_STATE_DIR/swarm-roots"
OUT=$(bash "$PRUNE" --state-dir "$STATE" 2>&1); RC=$?
[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "refusing to drop every record" && ok "refuses with no known repo" || bad "rc=$RC: $OUT"

echo "=== dry run reports and changes nothing ==="
printf '%s\n' "$TMP/realrepo" > "$AUTOCODER_REBOOT_STATE_DIR/swarm-roots"
BEFORE=$(cat "$STATE/merge-events.jsonl")
OUT=$(bash "$PRUNE" --state-dir "$STATE" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "dry run exits 0" || bad "dry run rc=$RC: $OUT"
echo "$OUT" | grep -q "merge-events.jsonl: keep 1, drop 4, unreadable (kept) 1" && ok "dry run counts (registry root kept)" || bad "dry-run counts: $OUT"
[ "$(cat "$STATE/merge-events.jsonl")" = "$BEFORE" ] && ok "dry run leaves the file alone" || bad "dry run changed the file"
[ -z "$(ls "$STATE" | grep bak)" ] && ok "dry run makes no backup" || bad "dry run backed up: $(ls "$STATE")"

echo "=== --apply rewrites with a backup ==="
OUT=$(bash "$PRUNE" --state-dir "$STATE" --apply 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "apply exits 0" || bad "apply rc=$RC: $OUT"
[ "$(issues_in "$STATE/merge-events.jsonl")" = "1 bad " ] && ok "kept the real repo's record and the unreadable line" || bad "merge-events now: $(issues_in "$STATE/merge-events.jsonl")"
[ "$(issues_in "$STATE/issue-events.jsonl")" = "6 " ] && ok "issue-events pruned too" || bad "issue-events now: $(issues_in "$STATE/issue-events.jsonl")"
BAK=$(ls "$STATE"/merge-events.jsonl.bak-* 2>/dev/null | head -1)
[ -n "$BAK" ] && [ "$(cat "$BAK")" = "$BEFORE" ] && ok "backup holds the original" || bad "backup missing or wrong: $BAK"
[ "$(cat "$STATE/landing-timings.jsonl")" = '{"kind":"batch"}' ] && ok "landing-timings left alone" || bad "landing-timings changed"
case "$(stat -c %a "$STATE/merge-events.jsonl" 2>/dev/null || stat -f %Lp "$STATE/merge-events.jsonl")" in
  600) ok "rewritten file stays 0600" ;; *) bad "mode is $(ls -l "$STATE/merge-events.jsonl")" ;;
esac

echo "=== --keep-repo and --root add known repos ==="
reset
: > "$AUTOCODER_REBOOT_STATE_DIR/swarm-roots"
OUT=$(bash "$PRUNE" --state-dir "$STATE" --root "$TMP/realrepo" --keep-repo other-5678 2>&1)
echo "$OUT" | grep -q "merge-events.jsonl: keep 2, drop 3" && ok "--root and --keep-repo both count" || bad "keep flags: $OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
