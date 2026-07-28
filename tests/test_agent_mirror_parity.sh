#!/bin/bash
# tests/test_agent_mirror_parity.sh — guards the .agent/ (Antigravity) mirror of
# the issue layer against drift from plugins/autocoder/scripts/ (Claude Code).
#
# CLAUDE.md declares mirror parity CRITICAL, but nothing enforced it. The layer
# drifted far enough that .agent/workflows/fix.md called three verbs its own
# issue-fns.sh never defined (issue_claim, issue_release, issue_any_claimable),
# so the Antigravity /fix exited 127 at its preflight check on every run — see
# #71. These files are shared infrastructure and must stay byte-identical.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
PLUGIN_DIR="$ROOT/plugins/autocoder/scripts"
AGENT_DIR="$ROOT/.agent/scripts"

ok()   { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# The 9-verb contract both backends must honour.
VERBS=(issue_list issue_get issue_update issue_comment issue_close \
       issue_create issue_claim issue_release issue_any_claimable)

# Files that are shared infrastructure, not platform-specific.
SHARED=(issue-fns.sh issue-config.sh issues-file.py issues-gh.sh)

# ── The mirror must ship every shared file ────────────────────────────────
for f in "${SHARED[@]}"; do
  if [ -f "$AGENT_DIR/$f" ]; then
    ok "mirror has $f"
  else
    bad "mirror is missing $f"
  fi
done

# ── Shared files must be identical, not merely present ────────────────────
for f in "${SHARED[@]}"; do
  if [ ! -f "$AGENT_DIR/$f" ] || [ ! -f "$PLUGIN_DIR/$f" ]; then
    bad "$f: cannot compare (missing on one side)"
  elif diff -q "$PLUGIN_DIR/$f" "$AGENT_DIR/$f" >/dev/null 2>&1; then
    ok "$f identical across mirrors"
  else
    n=$(diff "$PLUGIN_DIR/$f" "$AGENT_DIR/$f" | grep -c '^[<>]')
    bad "$f diverged ($n differing lines)"
  fi
done

# ── Every verb the contract defines must resolve on BOTH sides ────────────
# Sourced in a subshell with cwd inside a throwaway repo so issue-config.sh
# resolves that repo's config, never this checkout's. A poisoned gh guarantees
# a resolution regression cannot reach the real tracker.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.issues/open" "$TMP/.issues/working" "$TMP/.issues/blocked" \
         "$TMP/.issues/closed" "$TMP/bin"
git -C "$TMP" init -q
cat > "$TMP/.autocoder.json" <<EOF
{"issueSource": "file", "issueDir": "$TMP/.issues"}
EOF
GH_TRIPWIRE="$TMP/gh-was-called"
cat > "$TMP/bin/gh" <<EOF
#!/bin/bash
echo "gh called: \$*" >> "$GH_TRIPWIRE"
exit 97
EOF
chmod +x "$TMP/bin/gh"

check_verbs() {
  local label="$1" lib="$2"
  local missing
  missing=$( (cd "$TMP" && PATH="$TMP/bin:$PATH" bash -c "
    source '$lib' 2>/dev/null
    for v in ${VERBS[*]}; do
      declare -F \"\$v\" >/dev/null || echo \"\$v\"
    done") 2>/dev/null )
  if [ -z "$missing" ]; then
    ok "$label defines all ${#VERBS[@]} contract verbs"
  else
    bad "$label missing verbs: $(echo "$missing" | tr '\n' ' ')"
  fi
}

check_verbs "plugins issue-fns.sh" "$PLUGIN_DIR/issue-fns.sh"
[ -f "$AGENT_DIR/issue-fns.sh" ] && check_verbs "mirror issue-fns.sh" "$AGENT_DIR/issue-fns.sh"

# ── `--state blocked` must be a supported state, not passed through to gh ──
# The mirror used to forward --state straight to `gh issue list`, which rejects
# anything outside {open,closed,all}. list-needs-feedback and approve-proposal
# both rely on this state.
for side in "plugins:$PLUGIN_DIR" "mirror:$AGENT_DIR"; do
  label="${side%%:*}"; dir="${side#*:}"
  [ -f "$dir/issue-fns.sh" ] || continue
  out=$( (cd "$TMP" && PATH="$TMP/bin:$PATH" bash -c "
    source '$dir/issue-fns.sh' 2>/dev/null; issue_list --state blocked --limit 5") 2>&1 )
  if echo "$out" | grep -q "invalid argument"; then
    bad "$label: --state blocked forwarded to gh (rejected as invalid)"
  elif echo "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    ok "$label: --state blocked returns valid JSON"
  else
    bad "$label: --state blocked produced neither JSON nor a known error: ${out:0:80}"
  fi
done

# ── The real gh must never have been reached ──────────────────────────────
if [ -f "$GH_TRIPWIRE" ]; then
  bad "test shelled out to real gh: $(head -1 "$GH_TRIPWIRE")"
else
  ok "no call reached the real gh CLI"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
