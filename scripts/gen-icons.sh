#!/usr/bin/env bash
# scripts/gen-icons.sh
#
# Resizes the master icon (app/Resources/posterPlayer.png, 1024x1024)
# into every iPhone home-screen icon variant iOS / uicache might look
# for. We're generous with filenames here because rootless iOS 15
# uicache + SpringBoard have been observed to fall back through several
# different naming conventions before giving up and showing the white
# square.
#
# Filenames generated (all in app/Resources/):
#
#     Icon.png             60x60    (legacy 1x)
#     Icon@2x.png         120x120
#     Icon@3x.png         180x180
#     Icon-60.png          60x60    (modern, 1x)
#     Icon-60@2x.png      120x120
#     Icon-60@3x.png      180x180
#     Icon-76.png          76x76    (iPad 1x)
#     Icon-76@2x.png      152x152   (iPad @2x)
#     AppIcon@2x.png      120x120   (kept for back-compat with old Info.plist)
#     AppIcon@3x.png      180x180
#     AppIcon~ipad.png     76x76
#     AppIcon@2x~ipad.png 152x152
#
# Re-run after replacing posterPlayer.png with a new master.

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

# "Icon" family (the names declared in our Info.plist's CFBundleIconFiles).
resize  60 "$DST_DIR/Icon.png"
resize 120 "$DST_DIR/Icon@2x.png"
resize 180 "$DST_DIR/Icon@3x.png"
resize  60 "$DST_DIR/Icon-60.png"
resize 120 "$DST_DIR/Icon-60@2x.png"
resize 180 "$DST_DIR/Icon-60@3x.png"
resize  76 "$DST_DIR/Icon-76.png"
resize 152 "$DST_DIR/Icon-76@2x.png"

# "AppIcon" family (back-compat for any older Info.plist references).
resize 120 "$DST_DIR/AppIcon@2x.png"
resize 180 "$DST_DIR/AppIcon@3x.png"
resize  76 "$DST_DIR/AppIcon~ipad.png"
resize 152 "$DST_DIR/AppIcon@2x~ipad.png"

say "Done. Generated:"
ls -la "$DST_DIR"/Icon*.png "$DST_DIR"/AppIcon*.png 2>/dev/null
