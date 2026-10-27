#!/bin/bash
# tests/test_install_ripgrep.sh — install-ripgrep.sh must install a verified
# binary without root, refuse a tampered download, and never download when rg
# or Homebrew is already there. Hermetic: curl, uname and brew are stubs, and
# PATH holds only a sandbox of the tools the script needs.

PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/plugins/autocoder/scripts/install-ripgrep.sh"

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label — want '$want', got '$got'"; FAIL=$((FAIL + 1))
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

TARGET="x86_64-unknown-linux-musl"
ASSET="ripgrep-9.9.9-$TARGET.tar.gz"
mkdir -p "$TMP/fixture/ripgrep-9.9.9-$TARGET"
printf '#!/bin/sh\necho "ripgrep 9.9.9"\n' > "$TMP/fixture/ripgrep-9.9.9-$TARGET/rg"
chmod +x "$TMP/fixture/ripgrep-9.9.9-$TARGET/rg"
tar -czf "$TMP/$ASSET" -C "$TMP/fixture" "ripgrep-9.9.9-$TARGET"
GOOD_SHA="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"

# make_sandbox <dir> <sha-to-serve> <uname-m>
make_sandbox() {
  local bin="$1/bin"
  mkdir -p "$bin"
  for t in bash sh env tr sed tail head mktemp rm awk sha256sum tar gzip mkdir install cat cp; do
    ln -sf "$(command -v "$t")" "$bin/$t"
  done
  cat > "$bin/curl" <<EOF
#!/bin/bash
echo "\$*" >> "$1/curl.log"
if [[ " \$* " == *" -fsSI "* ]]; then
  printf 'HTTP/2 302\r\nlocation: https://github.com/BurntSushi/ripgrep/releases/tag/9.9.9\r\n\r\n'
  exit 0
fi
out=""; while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && out="\$2"; shift; done
case "\$out" in
  *.sha256) echo "$2  $ASSET" > "\$out" ;;
  *) cp "$TMP/$ASSET" "\$out" ;;
esac
EOF
  printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo %s ;; esac\n' "$3" > "$bin/uname"
  chmod +x "$bin/curl" "$bin/uname"
}

run() { PATH="$1/bin" HOME="$1/home" RG_INSTALL_DIR="$1/home/.local/bin" bash "$SCRIPT" >"$1/out" 2>&1; echo $?; }

# ── Fresh host: resolves the latest tag from the redirect and installs it
S="$TMP/fresh"; make_sandbox "$S" "$GOOD_SHA" x86_64
assert_eq "fresh install exits 0" "0" "$(run "$S")"
assert_eq "installed binary runs" "ripgrep 9.9.9" "$("$S/home/.local/bin/rg" 2>&1)"
assert_eq "version came from the latest-release redirect" "yes" \
  "$(grep -q "download/9.9.9/$ASSET" "$S/curl.log" && echo yes || echo no)"

# ── Tampered download: refuses and installs nothing
S="$TMP/tampered"; make_sandbox "$S" "0000000000000000000000000000000000000000000000000000000000000000" x86_64
assert_eq "checksum mismatch exits 1" "1" "$(run "$S")"
assert_eq "checksum mismatch installs nothing" "no" "$([ -e "$S/home/.local/bin/rg" ] && echo yes || echo no)"

# ── rg already present: no network at all
S="$TMP/present"; make_sandbox "$S" "$GOOD_SHA" x86_64
cp "$TMP/fixture/ripgrep-9.9.9-$TARGET/rg" "$S/bin/rg"
assert_eq "existing rg exits 0" "0" "$(run "$S")"
assert_eq "existing rg skips curl" "no" "$([ -e "$S/curl.log" ] && echo yes || echo no)"

# ── Homebrew present: delegates to brew, no download
S="$TMP/brew"; make_sandbox "$S" "$GOOD_SHA" x86_64
printf '#!/bin/sh\necho "$*" > "%s/brew.log"\n' "$S" > "$S/bin/brew"; chmod +x "$S/bin/brew"
assert_eq "brew path exits 0" "0" "$(run "$S")"
assert_eq "brew installs ripgrep" "install ripgrep" "$(cat "$S/brew.log" 2>/dev/null)"
assert_eq "brew path skips curl" "no" "$([ -e "$S/curl.log" ] && echo yes || echo no)"

# ── Unsupported architecture: fails with guidance, no download
S="$TMP/arch"; make_sandbox "$S" "$GOOD_SHA" riscv64
assert_eq "unsupported arch exits 1" "1" "$(run "$S")"
assert_eq "unsupported arch skips curl" "no" "$([ -e "$S/curl.log" ] && echo yes || echo no)"

# ── Antigravity mirror stays identical
assert_eq ".agent/scripts copy is identical" "same" \
  "$(cmp -s "$SCRIPT" "$ROOT/.agent/scripts/install-ripgrep.sh" && echo same || echo differs)"

# ── Both /install commands offer the installer
for f in plugins/autocoder/commands/install.md .agent/workflows/install.md; do
  assert_eq "$f runs install-ripgrep.sh" "yes" \
    "$(grep -q 'install-ripgrep.sh' "$ROOT/$f" && echo yes || echo no)"
done

# ── Every platform's skill tells agents to prefer rg, with the -uu caveat
for f in skills/autocoder/SKILL.md plugins/autocoder/skills/autocoder/SKILL.md \
         codex-plugins/autocoder/skills/autocoder/SKILL.md .factory/skills/autocoder/SKILL.md \
         .pi/skills/autocoder.md skills/modernize/SKILL.md plugins/modernize/skills/modernize/SKILL.md \
         codex-plugins/modernize/skills/modernize/SKILL.md .factory/skills/modernize/SKILL.md \
         .pi/skills/modernize.md plugins/modernize/agents/coder.md .agent/rules/coder.md; do
  assert_eq "$f prefers rg with -uu caveat" "yes" \
    "$(grep 'rg' "$ROOT/$f" | grep -q -- '-uu' && echo yes || echo no)"
done

TOTAL=$((PASS + FAIL))
echo "$PASS passed / $FAIL failed / $TOTAL total"
[ "$FAIL" -eq 0 ]
