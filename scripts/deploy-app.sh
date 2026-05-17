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

cd "$(dirname "$0")/.."

: "${THEOS:=$HOME/theos}"
export THEOS

say "Building PocketPoster.app (theos at $THEOS)"
make -C app clean >/dev/null 2>&1 || true
make -C app package FINALPACKAGE=0 2>&1 | tail -8

# Theos default packages dir is alongside its Makefile, so app/packages/.
DEB="$(ls -t app/packages/com.vortex.pocketposter_*.deb 2>/dev/null | head -1)"
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
