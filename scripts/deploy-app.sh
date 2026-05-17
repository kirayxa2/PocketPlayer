#!/usr/bin/env bash
# scripts/deploy-app.sh — build + scp + dpkg -i + uicache for the
# PocketPoster companion app. Mirrors the layout of deploy.sh so you
# can use both interchangeably.
#
# Usage:
#   PP_HOST=mobile@192.168.0.112  PP_KEY=~/.ssh/iphone  ./scripts/deploy-app.sh
#   PP_PASS=vortex                ./scripts/deploy-app.sh
#
# The app icon will appear on the home screen after uicache runs.

set -e

PP_HOST="${PP_HOST:-mobile@192.168.0.112}"
PP_KEY="${PP_KEY:-$HOME/.ssh/iphone}"
PP_PASS="${PP_PASS:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
say()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}!! ${NC} $*"; }

# Repo root (one above scripts/).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${THEOS:=$HOME/theos}"
export THEOS

say "Building PocketPoster.app (theos at $THEOS)"

# Wipe stale build state from BOTH possible roots. The first failed
# build can leave a half-staged tree at PocketPlayer/.theos/obj/debug/
# because Theos was confused about which directory was the project
# root; clear that out too so the next build is deterministic.
rm -rf "$ROOT/app/.theos" "$ROOT/app/packages" \
       "$ROOT/.theos/obj/debug/PocketPoster.app" \
       "$ROOT/.theos/_/_/_root/_var/jb/Applications/PocketPoster.app" 2>/dev/null || true

# Run the app build in a CLEAN environment. The parent shell may have
# Theos variables left over from any 'make' run in the tweak directory
# (THEOS_PROJECT_DIR in particular, which pins build paths to the wrong
# directory). 'env -u' wipes only the dangerous ones so PATH/HOME/SSH
# config stays intact.
(
  cd "$ROOT/app"
  env -u THEOS_PROJECT_DIR -u THEOS_BUILD_DIR -u THEOS_OBJ_DIR \
      -u THEOS_OBJ_DIR_NAME -u THEOS_PACKAGE_DIR -u THEOS_STAGING_DIR \
      -u _THEOS_CURRENT_PACKAGE -u _THEOS_CURRENT_TYPE \
      -u _THEOS_RULES_LOADED -u _THEOS_COMMON_LOADED \
      make package FINALPACKAGE=0
) 2>&1 | tail -30

# Theos default packages dir is alongside its Makefile, so app/packages/.
DEB="$(ls -t "$ROOT"/app/packages/com.vortex.pocketposter_*.deb 2>/dev/null | head -1)"
[ -n "$DEB" ] || { warn "no PocketPoster .deb produced (looked in app/packages/)"; exit 1; }
say "Built $DEB"

say "scp -> $PP_HOST"
scp -i "$PP_KEY" -o StrictHostKeyChecking=accept-new "$DEB" "$PP_HOST:/var/mobile/"

DEB_BASE="$(basename "$DEB")"
say "dpkg -i + uicache"
if [ -n "$PP_PASS" ]; then
  ssh -i "$PP_KEY" "$PP_HOST" \
    "echo '$PP_PASS' | sudo -S dpkg -i /var/mobile/'$DEB_BASE' && echo '$PP_PASS' | sudo -S uicache -p /var/jb/Applications/PocketPoster.app" 2>&1 \
    | grep -vE 'password for|пароль для|tcgetattr' || true
else
  ssh -i "$PP_KEY" "$PP_HOST" \
    "sudo -S dpkg -i /var/mobile/'$DEB_BASE' && sudo -S uicache -p /var/jb/Applications/PocketPoster.app"
fi

say "Done. Look for the PocketPoster icon on the home screen."
