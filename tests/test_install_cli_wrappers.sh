#!/bin/bash
# tests/test_install_cli_wrappers.sh — pins how /autocoder:install puts the
# terminal commands (start-parallel, add-worker, ...) into ~/.local/bin.
#
# The regression this guards: the installer used to SYMLINK into the plugin
# cache's versioned directory (.../autocoder/4.21.0/scripts). Plugin updates
# install into a NEW versioned directory, so those links silently ran stale
# code after every update — a start-parallel pinned to 4.21.0 kept picking
# tmux because herdr support shipped in 4.22.0. Cache installs must instead
# generate wrappers that resolve the CURRENT version at run time.

set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
INSTALL_MD="$ROOT/plugins/autocoder/commands/install.md"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ── 1. Static invariants on the install protocol ─────────────────────────────
grep -q 'installed_plugins.json' "$INSTALL_MD" \
  && pass "install.md wrappers resolve the current version via installed_plugins.json" \
  || fail "install.md never consults installed_plugins.json"

grep -q '"\$HOME/.claude/plugins/cache/"\*' "$INSTALL_MD" \
  && pass "install.md branches on cache vs checkout installs" \
  || fail "install.md does not distinguish cache installs from checkouts"

# Exactly ONE ln -sf against $SCRIPT_DIR may remain: the checkout branch of
# install_cli. A second one means someone reintroduced direct cache symlinks.
LN_COUNT=$(grep -c 'ln -sf "\$SCRIPT_DIR/' "$INSTALL_MD")
[ "$LN_COUNT" = "1" ] \
  && pass "install.md symlinks \$SCRIPT_DIR only in the checkout branch" \
  || fail "install.md has $LN_COUNT ln -sf \$SCRIPT_DIR lines (want 1 — cache installs must generate wrappers)"

# ── 2. Functional: run the installer block against a fake plugin cache ───────
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAKE_HOME="$WORK/home"

# Fake cache with an OLD and a NEW version; installed_plugins.json says NEW.
for v in 4.21.0 4.23.0; do
  mkdir -p "$FAKE_HOME/.claude/plugins/cache/mp/autocoder/$v/scripts"
  printf '#!/bin/bash\necho "ran-version %s args:$*"\n' "$v" \
    > "$FAKE_HOME/.claude/plugins/cache/mp/autocoder/$v/scripts/start-parallel-agents.sh"
done
cat > "$FAKE_HOME/.claude/plugins/installed_plugins.json" <<EOF
{"version": 2, "plugins": {"autocoder@mp": [{"installPath": "$FAKE_HOME/.claude/plugins/cache/mp/autocoder/4.23.0", "version": "4.23.0"}]}}
EOF

# Extract the fenced bash block containing install_cli from install.md.
BLOCK="$WORK/installer-block.sh"
python3 - "$INSTALL_MD" > "$BLOCK" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
for block in re.findall(r'```bash\n(.*?)```', text, re.S):
    if 'install_cli()' in block:
        print(block)
        break
else:
    sys.exit(1)
PY
[ -s "$BLOCK" ] && pass "extracted the install_cli block from install.md" \
  || { fail "could not extract the install_cli block from install.md"; echo ""; echo "$PASS passed / $FAIL failed"; exit 1; }

run_installer() {
  HOME="$FAKE_HOME" USER_APPROVED_SCRIPTS=yes PATH_OK=true SHELL_RC=/dev/null \
    INSTALL_DIR="$FAKE_HOME/.local/bin" SCRIPT_DIR="$1" \
    bash -c "set -e; USER_APPROVED_SCRIPTS=yes; PATH_OK=true; SHELL_RC=/dev/null; INSTALL_DIR='$FAKE_HOME/.local/bin'; SCRIPT_DIR='$1'; source '$BLOCK'" >/dev/null 2>&1
}

# 2a. Cache install -> generated wrapper (not a symlink), runs CURRENT version
run_installer "$FAKE_HOME/.claude/plugins/cache/mp/autocoder/4.21.0/scripts" \
  || fail "installer block exited non-zero for a cache install"
CLI="$FAKE_HOME/.local/bin/start-parallel"
if [ -L "$CLI" ]; then
  fail "cache install produced a symlink (the stale-version regression)"
elif [ -x "$CLI" ]; then
  pass "cache install generates an executable wrapper"
else
  fail "cache install produced neither symlink nor wrapper"
fi

OUT=$(HOME="$FAKE_HOME" bash "$CLI" 3 --paused 2>/dev/null)
case "$OUT" in
  *"ran-version 4.23.0"*) pass "wrapper runs the CURRENT installed version, not the install-time one" ;;
  *) fail "wrapper ran: '$OUT' (want the 4.23.0 install from installed_plugins.json)" ;;
esac
case "$OUT" in
  *"args:3 --paused"*) pass "wrapper forwards its arguments" ;;
  *) fail "wrapper did not forward arguments: '$OUT'" ;;
esac

# 2b. A later plugin update is picked up with NO reinstall
mkdir -p "$FAKE_HOME/.claude/plugins/cache/mp/autocoder/9.9.9/scripts"
printf '#!/bin/bash\necho "ran-version 9.9.9"\n' \
  > "$FAKE_HOME/.claude/plugins/cache/mp/autocoder/9.9.9/scripts/start-parallel-agents.sh"
cat > "$FAKE_HOME/.claude/plugins/installed_plugins.json" <<EOF
{"version": 2, "plugins": {"autocoder@mp": [{"installPath": "$FAKE_HOME/.claude/plugins/cache/mp/autocoder/9.9.9", "version": "9.9.9"}]}}
EOF
OUT=$(HOME="$FAKE_HOME" bash "$CLI" 2>/dev/null)
case "$OUT" in
  *"ran-version 9.9.9"*) pass "wrapper follows plugin updates without reinstall" ;;
  *) fail "after update, wrapper ran: '$OUT' (want 9.9.9)" ;;
esac

# 2c. installed_plugins.json missing -> falls back to highest cache version
rm "$FAKE_HOME/.claude/plugins/installed_plugins.json"
OUT=$(HOME="$FAKE_HOME" bash "$CLI" 2>/dev/null)
case "$OUT" in
  *"ran-version 9.9.9"*) pass "wrapper falls back to the highest cached version" ;;
  *) fail "fallback ran: '$OUT' (want 9.9.9)" ;;
esac

# 2d. Checkout install -> plain symlink to the stable path
CHECKOUT="$WORK/checkout/plugins/autocoder/scripts"
mkdir -p "$CHECKOUT"
printf '#!/bin/bash\necho checkout\n' > "$CHECKOUT/start-parallel-agents.sh"
rm -f "$CLI"
run_installer "$CHECKOUT" || fail "installer block exited non-zero for a checkout install"
[ -L "$CLI" ] && [ "$(readlink "$CLI")" = "$CHECKOUT/start-parallel-agents.sh" ] \
  && pass "checkout install symlinks the stable repo path" \
  || fail "checkout install did not symlink the repo path"

echo ""
echo "$PASS passed / $FAIL failed / $((PASS + FAIL)) total"
[ "$FAIL" -eq 0 ]
