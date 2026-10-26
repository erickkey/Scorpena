#!/bin/sh
#
# Packages a built Scorpena.app for sharing:
#   - <Name>.zip  — plain archive
#   - <Name>.dmg  — pretty window with an arrow → Applications
#
# Usage:
#   Scripts/package.sh [/path/to/Scorpena.app] [output-dir]
#
# With no path, the newest Scorpena.app in DerivedData is used.
# Output defaults to ~/Desktop.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-}"
OUT="${2:-$HOME/Desktop}"
BG="$HERE/dmg-background.png"
VOL="Scorpena"

# ---- locate the app --------------------------------------------------------
if [ -z "$APP" ]; then
    APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -type d -name 'Scorpena.app' -path '*/Build/Products/*' 2>/dev/null \
        | xargs -I{} stat -f '%m %N' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
fi
[ -n "$APP" ] && [ -d "$APP" ] || {
    echo "Scorpena.app not found — build it in Xcode (Release) first."
    exit 1
}
NAME="$(basename "$APP" .app)"
echo "packaging: $APP"

# ---- clean copy + ad-hoc sign -------------------------------------------------
WORK="$(mktemp -d)"
cp -R "$APP" "$WORK/"
APP="$WORK/$NAME.app"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" \
    && echo "signature: ok" \
    || echo "signature: verify warned (fine for sharing without notarization)"

BIN="$APP/Contents/Resources/bin"
for t in yt-dlp ffmpeg deno; do
    if [ -x "$BIN/$t" ]; then
        echo "  $t: $(lipo -archs "$BIN/$t" 2>/dev/null || echo '?')"
    else
        echo "  WARNING: $t is NOT bundled — recipients would need to install it"
    fi
done

mkdir -p "$OUT"

# ---- zip -------------------------------------------------------------------
ZIP="$OUT/$NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "→ $ZIP"

# ---- dmg with styled window ----------------------------------------------
DMG="$OUT/$NAME.dmg"
TMP_DMG="$(mktemp -u).dmg"
STAGE="$(mktemp -d)"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [ -f "$BG" ]; then
    mkdir "$STAGE/.background"
    cp "$BG" "$STAGE/.background/bg.png"
fi
README_RTF="$HERE/readme-unlock.rtf"
BANG_ICON="$HERE/bang-icon.png"
if [ -f "$README_RTF" ]; then
    cp "$README_RTF" "$STAGE/Если не открывается.rtf"
    if [ -f "$BANG_ICON" ]; then
        swift "$HERE/set-file-icon.swift" "$BANG_ICON" "$STAGE/Если не открывается.rtf" \
            || echo "note: could not set custom icon on readme.rtf"
    fi
fi
# volume icon = app icon
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
    cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
    SetFile -a C "$STAGE" 2>/dev/null || true
fi

SIZE_KB=$(( $(du -sk "$STAGE" | cut -f1) + 40000 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ \
    -format UDRW -size "${SIZE_KB}k" "$TMP_DMG" >/dev/null

hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true
hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen >/dev/null
sleep 1

osascript >/dev/null 2>&1 <<EOF || echo "note: could not style the DMG window (approve 'Terminal → control Finder' and re-run for the arrow layout)"
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 104
        set text size of opts to 12
        try
            set label position of opts to bottom
        end try
        try
            -- white icon labels, for the dark background
            set color of opts to {65535, 65535, 65535}
        end try
        try
            set background picture of opts to file ".background:bg.png"
        end try
        set position of item "$NAME.app" of container window to {150, 185}
        set position of item "Applications" of container window to {490, 185}
        try
            set position of item "Если не открывается.rtf" of container window to {545, 330}
        end try
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

sync
hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true

rm -f "$DMG"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
echo "→ $DMG"

rm -f "$TMP_DMG"
rm -rf "$STAGE"

# ---- legacy dmg for apps that are already installed ----------------------------
# Versions up to 2.1 update themselves from releases/latest/download/VideoDownloader.dmg
# and look for VideoDownloader.app inside it. Keep that asset (same app, old folder
# name) next to Scorpena.dmg so they can still reach this version.
if [ "$NAME" = "Scorpena" ]; then
    LEGACY_STAGE="$(mktemp -d)"
    ditto "$APP" "$LEGACY_STAGE/VideoDownloader.app"
    codesign --verify --deep --strict "$LEGACY_STAGE/VideoDownloader.app" \
        || { echo "legacy copy: signature check FAILED"; exit 1; }
    LEGACY_DMG="$OUT/VideoDownloader.dmg"
    rm -f "$LEGACY_DMG"
    hdiutil create -srcfolder "$LEGACY_STAGE" -volname "VideoDownloader" -fs HFS+ \
        -format UDZO -imagekey zlib-level=9 "$LEGACY_DMG" >/dev/null
    echo "→ $LEGACY_DMG   (for older versions' in-app update)"
    rm -rf "$LEGACY_STAGE"
fi

rm -rf "$WORK"

echo
echo "Send $NAME.dmg (or .zip). First launch on another Mac:"
echo "  right-click the app → Open → Open"
echo "  if it says \"damaged\":  xattr -dr com.apple.quarantine /Applications/$NAME.app"
