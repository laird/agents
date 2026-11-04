#!/usr/bin/env bash
# install-ripgrep.sh — make `rg` available to agents on this host.
#
# Agents on every platform search code faster and with less noise through rg,
# but most worker hosts don't have it. This installs it without root:
#   1. already on PATH → report and exit
#   2. Homebrew present → brew install ripgrep
#   3. otherwise → the official release binary, SHA-256 verified, into
#      $RG_INSTALL_DIR (default ~/.local/bin)
#
# Env overrides: RG_VERSION (default: latest release), RG_INSTALL_DIR.
set -euo pipefail

REPO_URL="https://github.com/BurntSushi/ripgrep"
INSTALL_DIR="${RG_INSTALL_DIR:-$HOME/.local/bin}"

if command -v rg >/dev/null 2>&1; then
  echo "✅ ripgrep already installed ($(rg --version | head -1))"
  exit 0
fi

if command -v brew >/dev/null 2>&1; then
  brew install ripgrep
  echo "✅ ripgrep installed via Homebrew"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)               TARGET="x86_64-unknown-linux-musl" ;;
  Linux-aarch64|Linux-arm64)  TARGET="aarch64-unknown-linux-gnu" ;;
  Darwin-x86_64)              TARGET="x86_64-apple-darwin" ;;
  Darwin-arm64)               TARGET="aarch64-apple-darwin" ;;
  *)
    echo "❌ No ripgrep release binary for $(uname -s)-$(uname -m)." >&2
    echo "   Install it with your package manager: https://github.com/BurntSushi/ripgrep#installation" >&2
    exit 1 ;;
esac

# The /releases/latest redirect names the tag, which avoids the rate-limited API.
VERSION="${RG_VERSION:-}"
if [ -z "$VERSION" ]; then
  VERSION=$(curl -fsSI "$REPO_URL/releases/latest" | tr -d '\r' \
    | sed -n 's#^[Ll]ocation: .*/tag/\(.*\)$#\1#p' | tail -1)
fi
if [ -z "$VERSION" ]; then
  echo "❌ Could not determine the latest ripgrep release." >&2
  exit 1
fi

ASSET="ripgrep-$VERSION-$TARGET.tar.gz"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/$ASSET" "$REPO_URL/releases/download/$VERSION/$ASSET"
curl -fsSL -o "$WORK/$ASSET.sha256" "$REPO_URL/releases/download/$VERSION/$ASSET.sha256"

EXPECTED=$(awk '{print $1}' "$WORK/$ASSET.sha256")
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=$(sha256sum "$WORK/$ASSET" | awk '{print $1}')
else
  ACTUAL=$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')
fi
if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "❌ Checksum mismatch for $ASSET; not installing." >&2
  exit 1
fi

tar -xzf "$WORK/$ASSET" -C "$WORK"
mkdir -p "$INSTALL_DIR"
install -m 755 "$WORK/ripgrep-$VERSION-$TARGET/rg" "$INSTALL_DIR/rg"
echo "✅ ripgrep $VERSION installed to $INSTALL_DIR/rg"

if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  echo "⚠️  $INSTALL_DIR is not in your PATH. Add to ~/.bashrc or ~/.zshrc:"
  echo "   export PATH=\"$INSTALL_DIR:\$PATH\""
fi
