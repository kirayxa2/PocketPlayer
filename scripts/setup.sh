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
    xz-utils zip unzip libplist-utils \
    libtinfo5 libncurses5 dpkg-dev openssh-client
else
  warn "apt not found — install build-essential, perl, dpkg-dev manually"
fi

# 1b. ldid (not in Ubuntu repos — fetch ProcursusTeam prebuilt) ---------------
if command -v ldid >/dev/null 2>&1; then
  say "ldid already installed: $(command -v ldid)"
else
  say "Installing ldid (ProcursusTeam prebuilt)"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)  LDID_BIN="ldid_linux_x86_64" ;;
    aarch64) LDID_BIN="ldid_linux_aarch64" ;;
    *) die "Unsupported arch '$ARCH' for prebuilt ldid — install manually" ;;
  esac
  sudo curl -L --fail -o /usr/local/bin/ldid \
    "https://github.com/ProcursusTeam/ldid/releases/latest/download/$LDID_BIN" \
    || die "ldid download failed"
  sudo chmod +x /usr/local/bin/ldid
  ldid -v >/dev/null 2>&1 || warn "ldid installed but '-v' check failed (still may be fine)"
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

if ls -d "$SDK_DIR"/iPhoneOS15*.sdk >/dev/null 2>&1; then
  say "iPhoneOS15 SDK already present: $(ls -d "$SDK_DIR"/iPhoneOS15*.sdk | head -1)"
else
  say "Fetching theos/sdks (full clone, ~65 MiB) to find an iPhoneOS15 SDK"
  TMP=$(mktemp -d)
  trap "rm -rf $TMP" EXIT
  git clone --depth=1 https://github.com/theos/sdks.git "$TMP/sdks" || die "git clone of theos/sdks failed"

  FOUND_SDK="$(ls -d "$TMP/sdks"/iPhoneOS15*.sdk 2>/dev/null | sort -V | tail -1)"
  if [ -z "$FOUND_SDK" ]; then
    warn "theos/sdks has no iPhoneOS15*.sdk — falling back to xybp888/iOS-SDKs"
    rm -rf "$TMP/sdks"
    git clone --depth=1 https://github.com/xybp888/iOS-SDKs.git "$TMP/sdks" \
      || die "Fallback clone failed; install an iOS 15 SDK manually into $SDK_DIR"
    FOUND_SDK="$(ls -d "$TMP/sdks"/iPhoneOS15*.sdk 2>/dev/null | sort -V | tail -1)"
  fi
  [ -n "$FOUND_SDK" ] || die "No iPhoneOS15 SDK found in any source"

  say "Installing $(basename "$FOUND_SDK") -> $SDK_DIR"
  cp -R "$FOUND_SDK" "$SDK_DIR/" || die "SDK copy failed"
fi

say "Done. Reload your shell (or 'source ~/.bashrc') so THEOS is exported."
say "Next:  make package      # or  ./scripts/deploy.sh"
