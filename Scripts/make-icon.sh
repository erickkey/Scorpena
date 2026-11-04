#!/bin/sh
# Regenerates the app icon from Scripts/icon-source.png.
# Run after replacing icon-source.png with a new square PNG.

set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/icon-source.png"
SET="$HERE/../Scorpena/Assets.xcassets/AppIcon.appiconset"
MASTER="$(mktemp -t iconmaster).png"

swift "$HERE/make-icon.swift" "$SRC" "$MASTER"

for pair in \
    16:icon_16x16.png     32:icon_16x16@2x.png \
    32:icon_32x32.png     64:icon_32x32@2x.png \
    128:icon_128x128.png  256:icon_128x128@2x.png \
    256:icon_256x256.png  512:icon_256x256@2x.png \
    512:icon_512x512.png  1024:icon_512x512@2x.png
do
    size="${pair%%:*}"
    name="${pair##*:}"
    sips -s format png -z "$size" "$size" "$MASTER" --out "$SET/$name" >/dev/null
done

rm -f "$MASTER"
echo "icon regenerated in $SET"
