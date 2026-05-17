#!/usr/bin/env bash
# scripts/setup.sh — one-time WSL setup for PocketPlayer
#
# Installs:
#   - build deps (clang, perl, dpkg-deb, ...)
#   - Theos (~/theos)
#   - rootless iOS 15 SDK
#
# Run:  bash scripts/setup.sh
#
# Re-runnable: it skips steps that are already done.

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
say()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}!! ${NC} $*"; }
die()  { echo -e "${RED}xx ${NC} $*"; exit 1; }

# 1. Apt deps -----------------------------------------------------------------
if command -v apt >/dev/null 2>&1; then
  say "Installing apt packages"
  sudo apt update
  sudo apt install -y \
    build-essential fakeroot rsync curl wget git perl \
    ldid xz-utils zip unzip libplist-utils \
    libtinfo5 libncurses5 dpkg-dev openssh-client
else
  warn "apt not found — install build-essential, perl, ldid, dpkg-dev manually"
fi

# 2. Theos --------------------------------------------------------------------
if [ -d "$HOME/theos" ]; then
  say "Theos already at $HOME/theos — pulling latest"
  git -C "$HOME/theos" pull --rebase --recurse-submodules || true
  git -C "$HOME/theos" submodule update --init --recursive
else
  say "Cloning Theos to $HOME/theos"
  git clone --recursive https://github.com/theos/theos.git "$HOME/theos"
fi

# Persist THEOS in shell rc files (idempotent)
for rc in ~/.bashrc ~/.zshrc; do
  [ -f "$rc" ] || continue
  if ! grep -q 'export THEOS=' "$rc"; then
    echo '' >> "$rc"
    echo '# Theos' >> "$rc"
    echo 'export THEOS=$HOME/theos' >> "$rc"
    echo 'export PATH=$THEOS/bin:$PATH' >> "$rc"
  fi
done
export THEOS="$HOME/theos"
export PATH="$THEOS/bin:$PATH"

# 3. iOS 15 SDK (rootless build still needs an iOS SDK) -----------------------
SDK_DIR="$THEOS/sdks"
mkdir -p "$SDK_DIR"

if ls "$SDK_DIR"/iPhoneOS15*.sdk >/dev/null 2>&1; then
  say "iPhoneOS15 SDK already present"
else
  say "Downloading iPhoneOS15.5 SDK"
  curl -L -o /tmp/ios15sdk.tar.xz \
    https://github.com/theos/sdks/archive/refs/heads/master.tar.gz
  # The repo is huge; instead pull just the SDK we need via sparse checkout.
  rm -f /tmp/ios15sdk.tar.xz
  TMP=$(mktemp -d)
  git clone --depth=1 --filter=blob:none --sparse https://github.com/theos/sdks.git "$TMP/sdks"
  git -C "$TMP/sdks" sparse-checkout set iPhoneOS15.5.sdk
  if [ -d "$TMP/sdks/iPhoneOS15.5.sdk" ]; then
    cp -R "$TMP/sdks/iPhoneOS15.5.sdk" "$SDK_DIR/"
  else
    warn "Could not fetch iPhoneOS15.5.sdk via sparse checkout — falling back to full clone"
    git clone --depth=1 https://github.com/theos/sdks.git "$TMP/sdks_full"
    cp -R "$TMP/sdks_full/iPhoneOS15.5.sdk" "$SDK_DIR/" || die "SDK copy failed"
  fi
  rm -rf "$TMP"
fi

say "Done. Reload your shell (or 'source ~/.bashrc') so THEOS is exported."
say "Next:  make package      # or  ./scripts/deploy.sh"
