#!/bin/bash
# Deterministic sizes from the selected image; no image generation during builds.
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="$PWD/assets/icon-candidates/switcher-flow-v6.png"
ICONSET="$PWD/build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$PWD/build/AppIcon.icns"
