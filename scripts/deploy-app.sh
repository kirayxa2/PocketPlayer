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

# Optional first arg "build-only" — just build the .deb, don't ssh to device.
BUILD_ONLY=0
if [ "${1:-}" = "build-only" ]; then BUILD_ONLY=1; fi

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
[ -d "$THEOS" ] || { warn "THEOS not found at $THEOS"; exit 1; }

# Wipe stale build state from BOTH possible roots. The first failed
# build can leave a half-staged tree at PocketPlayer/.theos/obj/debug/
# because Theos was confused about which directory was the project
# root; clear that out too so the next build is deterministic.
rm -rf "$ROOT/app/.theos" "$ROOT/app/packages" \
       "$ROOT/.theos/obj/debug/PocketPoster.app" \
       "$ROOT/.theos/_/var/jb/Applications/PocketPoster.app" 2>/dev/null || true

LOG="/tmp/pocketposter-build.log"
say "Building PocketPoster.app (theos at $THEOS) -- full log: $LOG"

# Run the build with `env -i` -- a TOTALLY clean environment. The parent
# 'make app-deploy' invocation pollutes the env with both THEOS_*
# variables (from the tweak's common.mk include) and MAKEFLAGS that
# carry a now-broken jobserver fd. Either of those can make Theos
# either build into the wrong directory or skip the compile rules
# entirely (we saw 'Making stage' fire with no preceding 'Compiling'
# lines, then rsync ENOENT). Wiping the env and re-injecting only
# HOME / PATH / SHELL / THEOS is the only deterministic fix.
set +e
(
  cd "$ROOT/app"
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

# Theos default packages dir is alongside its Makefile, so app/packages/.
DEB="$(ls -t "$ROOT"/app/packages/com.vortex.pocketposter_*.deb 2>/dev/null | head -1)"
if [ -z "$DEB" ]; then
  warn "no PocketPoster .deb produced (looked in app/packages/)."
  warn "Last 40 lines of $LOG:"
  echo "----------------------------------------"
  tail -40 "$LOG"
  echo "----------------------------------------"
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
