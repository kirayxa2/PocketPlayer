#!/usr/bin/env bash
# scripts/deploy.sh — build + scp + dpkg -i + killall SpringBoard, in one shot.
#
# Usage:
#   PP_HOST=mobile@192.168.0.112  PP_KEY=~/.ssh/iphone  ./scripts/deploy.sh
#
# Sudo password handling on the device:
#   By default the script uses `sudo -S` and reads the password from PP_PASS.
#   Recommended: configure NOPASSWD once on the phone and forget it:
#     ssh -i ~/.ssh/iphone mobile@<ip> \
#       'echo "mobile ALL=(ALL) NOPASSWD: ALL" | sudo tee /var/jb/etc/sudoers.d/mobile && sudo chmod 440 /var/jb/etc/sudoers.d/mobile'
#   Otherwise put the password in env, e.g.:
#     PP_PASS=vortex ./scripts/deploy.sh
#
# Tail live device log:
#   ./scripts/deploy.sh tail

set -e

PP_HOST="${PP_HOST:-mobile@192.168.0.112}"
PP_KEY="${PP_KEY:-$HOME/.ssh/iphone}"
PP_PASS="${PP_PASS:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
say()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}!! ${NC} $*"; }

cd "$(dirname "$0")/.."

if [ "$1" = "tail" ]; then
  say "Tailing /var/mobile/pocketplayer.log on $PP_HOST"
  ssh -i "$PP_KEY" "$PP_HOST" "tail -f /var/mobile/pocketplayer.log"
  exit 0
fi

# 1. Build --------------------------------------------------------------------
: "${THEOS:=$HOME/theos}"
export THEOS

say "Building (theos at $THEOS)"
make package FINALPACKAGE=0 2>&1 | tail -5

DEB="$(ls -t packages/*.deb 2>/dev/null | head -1)"
[ -n "$DEB" ] || { warn "no .deb produced"; exit 1; }
say "Built $DEB"

# 2. Copy ---------------------------------------------------------------------
say "scp -> $PP_HOST"
scp -i "$PP_KEY" -o StrictHostKeyChecking=accept-new "$DEB" "$PP_HOST:/var/mobile/"

# 3. Install + respring -------------------------------------------------------
DEB_BASE="$(basename "$DEB")"
say "dpkg -i + respring"
if [ -n "$PP_PASS" ]; then
  ssh -i "$PP_KEY" "$PP_HOST" "echo '$PP_PASS' | sudo -S dpkg -i /var/mobile/'$DEB_BASE' && echo '$PP_PASS' | sudo -S killall SpringBoard" 2>&1 \
    | grep -vE 'password for|пароль для|tcgetattr' || true
else
  ssh -i "$PP_KEY" "$PP_HOST" "sudo -S dpkg -i /var/mobile/'$DEB_BASE' && sudo -S killall SpringBoard"
fi

say "Done. Lock the device, swipe, then:  ./scripts/deploy.sh tail"
