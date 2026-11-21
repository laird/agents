#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"
# tests/test_suite_state_isolation.sh — the suite never writes the user's real
# per-user state (#282):
#   - every test gets a private XDG_STATE_HOME from the prelude;
#   - run-shell-suite.sh runs under a scratch HOME, so the real
#     ~/.local/state/autocoder is out of reach, and a test that writes under
#     $HOME/.local/state anyway (a hard-coded path, an unset XDG_STATE_HOME)
#     fails the run;
#   - a test that keeps to XDG_STATE_HOME passes, and git still finds the
#     user's identity through the scratch HOME.
#
# Runs a copy of the runner and prelude over throwaway tests, with HOME pointing
# at a fake "real" home, and checks that home is byte-for-byte unchanged.

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REAL="$TMP/realhome"
mkdir -p "$REAL/.local/state/autocoder"
printf '{"repo":"agents-1","issue":1}\n' > "$REAL/.local/state/autocoder/merge-events.jsonl"
printf '[user]\n\tname = Suite User\n\temail = suite@example.com\n' > "$REAL/.gitconfig"
snapshot() { (cd "$REAL" && find . | sort && find . -type f | sort | while read -r f; do printf '== %s\n' "$f"; cat "$f"; done); }
BEFORE=$(snapshot)

# A fresh repo layout: tests/run-shell-suite.sh, tests/lib/private-event-logs.sh,
# and the throwaway tests named by each case.
mkroot() {
  local r="$TMP/$1"; shift
  rm -rf "$r"; mkdir -p "$r/tests/lib"
  cp "$ROOT/tests/run-shell-suite.sh" "$r/tests/"
  cp "$ROOT/tests/lib/private-event-logs.sh" "$r/tests/lib/"
  echo "$r"
}
add_test() {  # add_test <root> <name> <body>
  printf '#!/bin/bash\nsource "$(dirname "${BASH_SOURCE[0]}")/lib/private-event-logs.sh"\n%s\n' "$3" > "$1/tests/$2"
}
suite() { (cd "$1" && env -u XDG_STATE_HOME HOME="$REAL" TMPDIR="$TMP" bash tests/run-shell-suite.sh 2>&1); }

echo "=== a test that keeps to XDG_STATE_HOME passes ==="
R=$(mkroot clean)
add_test "$R" test_clean.sh '
case "$XDG_STATE_HOME" in "$HOME"/*|"") echo "XDG_STATE_HOME not private: $XDG_STATE_HOME"; exit 1 ;; esac
mkdir -p "$XDG_STATE_HOME/autocoder" && echo x >> "$XDG_STATE_HOME/autocoder/merge-events.jsonl"
[ "$(git config --global user.email)" = suite@example.com ] || { echo "git identity lost: $(git config --global user.email)"; exit 1; }'
OUT=$(suite "$R"); RC=$?
[ "$RC" -eq 0 ] && ok "clean suite exits 0" || bad "clean suite rc=$RC: $OUT"
echo "$OUT" | grep -q "Tests: 0 failed, 1 passed, 1 total" && ok "clean suite summary" || bad "clean summary: $OUT"

echo "=== a test that writes to \$HOME/.local/state fails the suite ==="
R=$(mkroot leaky)
add_test "$R" test_leaky.sh '
mkdir -p "$HOME/.local/state/autocoder" && echo "{\"repo\":\"worker-1\"}" >> "$HOME/.local/state/autocoder/merge-events.jsonl"'
OUT=$(suite "$R"); RC=$?
[ "$RC" -ne 0 ] && ok "leaky suite exits non-zero" || bad "leaky suite passed: $OUT"
echo "$OUT" | grep -q "FAIL  per-user state isolation" && ok "failure names the isolation check" || bad "no isolation failure line: $OUT"
echo "$OUT" | grep -q "~/.local/state/autocoder/merge-events.jsonl" && ok "failure names the leaked file" || bad "leaked file not named: $OUT"
echo "$OUT" | grep -q "Tests: 1 failed, 1 passed, 2 total" && ok "the leak counts in the summary" || bad "leaky summary: $OUT"

echo "=== a test that unsets XDG_STATE_HOME and uses the default fails too ==="
R=$(mkroot unset)
add_test "$R" test_unset.sh '
unset XDG_STATE_HOME
d="${XDG_STATE_HOME:-$HOME/.local/state}/autocoder"; mkdir -p "$d" && echo x >> "$d/issue-events.jsonl"'
OUT=$(suite "$R"); RC=$?
[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "issue-events.jsonl" && ok "default-path write is caught" || bad "default-path write not caught (rc=$RC): $OUT"

[ "$(snapshot)" = "$BEFORE" ] && ok "the real home is byte-identical after all three runs" || bad "the real home changed"
[ -z "$(find "$TMP" -maxdepth 1 -name 'suite-home.*' -o -maxdepth 1 -name 'suite-state.*' | head -1)" ] \
  && ok "scratch HOME and state dirs are removed" || bad "scratch dirs left behind: $(ls "$TMP")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
