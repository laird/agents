#!/bin/bash
# tests/test_release_gate.sh — hermetic test for scripts/check-release-version.sh.
#
# Builds a throwaway git repo with a "master" baseline, then drives the release
# gate through pass and fail cases (no bump, version drift, valid release) by
# mutating the working tree and comparing against the committed baseline.

set -u
PASS=0; FAIL=0
GATE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/scripts/check-release-version.sh"
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
no()  { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
[ -f "$GATE" ] || { echo "FAIL: gate script not found at $GATE"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q; git config user.email t@t; git config user.name t
git checkout -q -b master
mkdir -p .claude-plugin/plugins/autocoder

write_mkt() { # root_version autocoder_version
  cat > .claude-plugin/marketplace.json <<JSON
{ "name": "m", "version": "$1", "plugins": [ { "name": "autocoder", "version": "$2" } ] }
JSON
}
write_pj() { # autocoder_version
  cat > .claude-plugin/plugins/autocoder/plugin.json <<JSON
{ "name": "autocoder", "version": "$1" }
JSON
}

# Baseline on master: root 1.0.0, autocoder 2.0.0, consistent.
write_mkt 1.0.0 2.0.0
write_pj 2.0.0
git add -A; git commit -qm baseline

run_gate() { OUT=$(bash "$GATE" master 2>&1); RC=$?; }

# ── 1. valid release: bump root, versions consistent → pass (exit 0) ────────
write_mkt 1.1.0 2.0.0
write_pj 2.0.0
run_gate
[ "$RC" -eq 0 ] && ok "valid release (bump + consistent) exits 0" || no "valid release should pass — got $RC: $OUT"

# ── 2. no bump: root unchanged → fail (exit 1) ──────────────────────────────
git checkout -q -- .
write_mkt 1.0.0 2.0.0   # same root as baseline
write_pj 2.0.0
run_gate
[ "$RC" -eq 1 ] && ok "no version bump exits 1" || no "no-bump should fail — got $RC"
echo "$OUT" | grep -qi "must increase" && ok "no-bump message mentions the missing bump" || no "no-bump message unclear: $OUT"

# ── 3. version drift: root bumped but plugin.json != marketplace → fail ─────
git checkout -q -- .
write_mkt 1.1.0 2.0.0   # marketplace says autocoder 2.0.0
write_pj 9.9.9          # plugin.json disagrees
run_gate
[ "$RC" -eq 1 ] && ok "plugin.json drift exits 1" || no "drift should fail — got $RC"
echo "$OUT" | grep -qi "keep them equal" && ok "drift message points at the mismatch" || no "drift message unclear: $OUT"

# ── 4. lower version (regression) → fail ────────────────────────────────────
git checkout -q -- .
write_mkt 0.9.0 2.0.0
write_pj 2.0.0
run_gate
[ "$RC" -eq 1 ] && ok "version regression exits 1" || no "regression should fail — got $RC"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
