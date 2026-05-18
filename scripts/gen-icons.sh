#!/usr/bin/env bash
# scripts/gen-icons.sh
#
# Resizes the master icon (app/Resources/posterPlayer.png, 1024x1024)
# into the iPhone home-screen icon variants iOS expects:
#
#     AppIcon@2x.png       120x120   (iPhone 6s / 7 / 8 / SE)
#     AppIcon@3x.png       180x180   (iPhone 6/7/8 Plus, X and later)
#     AppIcon~ipad.png      76x76    (iPad)
#     AppIcon@2x~ipad.png  152x152   (iPad @2x)
#
# Output is written next to the master in app/Resources/, where Theos
# picks them up at build time (the CFBundleIcons key in Info.plist
# tells iOS to look for files named "AppIcon...").
#
# Re-run after replacing posterPlayer.png with a new master.
#
# Resize tools tried in order: sips (preinstalled on macOS), magick /
# convert (ImageMagick), and finally a tiny Python+Pillow fallback.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/app/Resources/posterPlayer.png"
DST_DIR="$ROOT/app/Resources"

if [ ! -f "$SRC" ]; then
  echo "!! source icon not found at $SRC"
  echo "   Put a 1024x1024 PNG there and re-run this script."
  exit 1
fi

GREEN='\033[0;32m'; NC='\033[0m'
say() { echo -e "${GREEN}==>${NC} $*"; }

resize() {
  local size="$1" out="$2"
  if command -v sips >/dev/null 2>&1; then
    sips -z "$size" "$size" "$SRC" --out "$out" >/dev/null
  elif command -v magick >/dev/null 2>&1; then
    magick "$SRC" -resize "${size}x${size}" "$out"
  elif command -v convert >/dev/null 2>&1; then
    convert "$SRC" -resize "${size}x${size}" "$out"
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import PIL' 2>/dev/null; then
    python3 - <<EOF
from PIL import Image
img = Image.open("$SRC").convert("RGBA")
img = img.resize(($size, $size), Image.LANCZOS)
img.save("$out")
EOF
  else
    echo "!! no resize tool found (need sips, magick, convert, or python3+Pillow)"
    echo "   On WSL Ubuntu:  sudo apt install imagemagick"
    exit 1
  fi
}

say "Generating icon variants from $SRC"
resize 120 "$DST_DIR/AppIcon@2x.png"
resize 180 "$DST_DIR/AppIcon@3x.png"
resize  76 "$DST_DIR/AppIcon~ipad.png"
resize 152 "$DST_DIR/AppIcon@2x~ipad.png"
say "Done. Generated:"
ls -la "$DST_DIR"/AppIcon*.png
