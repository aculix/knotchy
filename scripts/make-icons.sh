#!/usr/bin/env bash
# Regenerates every icon (app, SVGs, Chrome extension, menu bar glyph) from scripts/icons/knot.py,
# the disk image background and the Chrome Web Store promo images.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 "$root/scripts/icons/knot.py"
swift "$root/scripts/icons/render.swift" "$work"
iconutil -c icns "$work/AppIcon.iconset" -o "$root/assets/AppIcon.icns"
for size in 16 32 48 128; do
  cp "$work/chrome-$size.png" "$root/extensions/chrome/icons/icon-$size.png"
done
mkdir -p "$root/extensions/chrome/store"
cp "$work/promo-440x280.png" "$work/marquee-1400x560.png" "$root/extensions/chrome/store/"
tiffutil -cathidpicheck "$work/dmg-background.png" "$work/dmg-background@2x.png" -out "$root/assets/dmg-background.tiff"
echo "Wrote assets/AppIcon.icns, assets/dmg-background.tiff, extensions/chrome/icons/ and extensions/chrome/store/"
