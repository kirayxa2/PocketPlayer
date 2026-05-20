#!/usr/bin/env bash
# scripts/deploy-lockforge.sh — build + scp + dpkg -i + respring for
# the LockForge tweak. Independent .deb from PocketPlayer.
#
# Usage:
#   PP_HOST=mobile@192.168.0.112 PP_KEY=~/.ssh/iphone PP_PASS=vortex \
#     ./scripts/deploy-lockforge.sh
#
# Optional first arg "build-only" -- just build the .deb, don't ssh
# to the device.

set -e

BUILD_ONLY=0
if [ "${1:-}" = "build-only" ]; then BUILD_ONLY=1; fi

PP_HOST="${PP_HOST:-mobile@192.168.0.112}"
PP_KEY="${PP_KEY:-$HOME/.ssh/iphone}"
PP_PASS="${PP_PASS:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
say()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}!! ${NC} $*"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${THEOS:=$HOME/theos}"
[ -d "$THEOS" ] || { warn "THEOS not found at $THEOS"; exit 1; }

# Wipe stale build state in case we're switching schemes / arches.
rm -rf "$ROOT/lockforge/.theos" "$ROOT/lockforge/packages" 2>/dev/null || true

LOG="/tmp/lockforge-build.log"
say "Building LockForge tweak (theos at $THEOS) -- full log: $LOG"

# Same env-i pattern as deploy-app.sh: clean env so the parent make's
# THEOS_PROJECT_DIR / MAKEFLAGS don't poison the child build.
set +e
(
  cd "$ROOT/lockforge"
  env -i \
      HOME="$HOME" \
      PATH="$PATH" \
      SHELL="${SHELL:-/bin/bash}" \
      LANG="${LANG:-C.UTF-8}" \
      THEOS="$THEOS" \
      make package FINALPACKAGE=0
) >"$LOG" 2>&1
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  warn "build failed (exit $RC). Last 60 lines of $LOG:"
  echo "----------------------------------------"
  tail -60 "$LOG"
  echo "----------------------------------------"
  exit "$RC"
fi

DEB="$(ls -t "$ROOT"/lockforge/packages/com.vortex.lockforge_*.deb 2>/dev/null | head -1)"
if [ -z "$DEB" ]; then
  warn "no LockForge .deb produced (looked in lockforge/packages/)."
  warn "Last 40 lines of $LOG:"
  tail -40 "$LOG"
  exit 1
fi
say "Built $DEB"

if [ "$BUILD_ONLY" = "1" ]; then
    say "build-only: skipping scp/dpkg"
    exit 0
fi

say "scp -> $PP_HOST"
scp -i "$PP_KEY" -o StrictHostKeyChecking=accept-new "$DEB" "$PP_HOST:/var/mobile/"

DEB_BASE="$(basename "$DEB")"
say "dpkg -i + respring"
if [ -n "$PP_PASS" ]; then
  ssh -i "$PP_KEY" "$PP_HOST" \
    "echo '$PP_PASS' | sudo -S dpkg -i /var/mobile/'$DEB_BASE' && echo '$PP_PASS' | sudo -S killall SpringBoard" 2>&1 \
    | grep -vE 'password for|пароль для|tcgetattr' || true
else
  ssh -i "$PP_KEY" "$PP_HOST" \
    "sudo -S dpkg -i /var/mobile/'$DEB_BASE' && sudo -S killall SpringBoard"
fi

say "Done. Lock the device and try long-pressing the lockscreen to open the editor."
