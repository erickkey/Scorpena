#!/bin/sh
#
# Builds VideoDownloader.app WITHOUT Xcode — just swiftc + Command Line Tools.
# Produces a universal (arm64 + x86_64) ad-hoc signed .app.
#
# Usage:  Scripts/build-app.sh [output-dir]      (default: ~/Desktop)

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/YouTubeDownloader"
OUT="${1:-$HOME/Desktop}"
APP="$OUT/VideoDownloader.app"
SDK="$(xcrun --show-sdk-path)"
DT="13.0"
BUNDLE_ID="com.yaroslavlukyanov.VideoDownloader"
FFMPEG_TAG="b6.0"
DENO_TAG="v2.9.8"   # JS engine yt-dlp needs to solve YouTube challenges

# Bump this for every release that should trigger the in-app "update available"
# notice (must match the "version" in version.json on GitHub).
APP_VERSION="2.1"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"

echo "==> compiling Swift (arm64 + x86_64)"
BUILD="$(mktemp -d)"
for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -swift-version 5 \
        -sdk "$SDK" -target "${arch}-apple-macos${DT}" \
        "$SRC"/*.swift \
        -o "$BUILD/vd-${arch}"
done
lipo -create "$BUILD/vd-arm64" "$BUILD/vd-x86_64" -o "$APP/Contents/MacOS/VideoDownloader"
rm -rf "$BUILD"

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>VideoDownloader</string>
	<key>CFBundleDisplayName</key><string>VideoDownloader</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleExecutable</key><string>VideoDownloader</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
	<key>CFBundleVersion</key><string>${APP_VERSION}</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIconName</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>${DT}</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHumanReadableCopyright</key><string>© Yaroslav Lukyanov</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> icon (.icns)"
ISDIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ISDIR"
cp "$SRC/Assets.xcassets/AppIcon.appiconset/"icon_*.png "$ISDIR/"
iconutil -c icns "$ISDIR" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ISDIR")"

# compiled asset catalog too (for CFBundleIconName on newer macOS)
if command -v actool >/dev/null 2>&1; then
    actool --compile "$APP/Contents/Resources" \
        --app-icon AppIcon --output-partial-info-plist "$(mktemp)" \
        --platform macosx --minimum-deployment-target "$DT" \
        --errors --warnings "$SRC/Assets.xcassets" >/dev/null 2>&1 \
        && echo "    Assets.car built" || echo "    (actool skipped — .icns is enough)"
fi

echo "==> resources"
cp "$SRC/DownloadComplete.mp3" "$APP/Contents/Resources/"
cp "$SRC/AppLaunch.mp3" "$APP/Contents/Resources/"

echo "==> bundling yt-dlp + universal ffmpeg (~90 MB download)"
BIN="$APP/Contents/Resources/bin"
curl -fL --retry 3 --retry-delay 2 -o "$BIN/yt-dlp" \
    "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
chmod +x "$BIN/yt-dlp"

base="https://github.com/eugeneware/ffmpeg-static/releases/download/${FFMPEG_TAG}"
curl -fL --retry 3 --retry-delay 2 -o "$BIN/.ff-arm64" "$base/ffmpeg-darwin-arm64"
curl -fL --retry 3 --retry-delay 2 -o "$BIN/.ff-x86_64" "$base/ffmpeg-darwin-x64"
lipo -create "$BIN/.ff-arm64" "$BIN/.ff-x86_64" -o "$BIN/ffmpeg"
chmod +x "$BIN/ffmpeg"
rm -f "$BIN/.ff-arm64" "$BIN/.ff-x86_64"

echo "==> bundling universal deno (~75 MB download)"
dbase="https://github.com/denoland/deno/releases/download/${DENO_TAG}"
DTMP="$(mktemp -d)"
curl -fL --retry 3 --retry-delay 2 -o "$DTMP/arm64.zip"  "$dbase/deno-aarch64-apple-darwin.zip"
curl -fL --retry 3 --retry-delay 2 -o "$DTMP/x86_64.zip" "$dbase/deno-x86_64-apple-darwin.zip"
unzip -q -o "$DTMP/arm64.zip"  -d "$DTMP/arm64"
unzip -q -o "$DTMP/x86_64.zip" -d "$DTMP/x86_64"
lipo -create "$DTMP/arm64/deno" "$DTMP/x86_64/deno" -o "$BIN/deno"
chmod +x "$BIN/deno"
rm -rf "$DTMP"

for t in yt-dlp ffmpeg deno; do
    codesign --verify --quiet "$BIN/$t" 2>/dev/null \
        || codesign --force --sign - --timestamp=none "$BIN/$t"
done

echo "==> ad-hoc signing the app"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" \
    && echo "    signature ok" \
    || echo "    signature verify warned (fine for local use / sharing without notarization)"

echo
echo "built: $APP"
echo "arch:  $(lipo -archs "$APP/Contents/MacOS/VideoDownloader")"
echo "  yt-dlp: $(lipo -archs "$BIN/yt-dlp")"
echo "  ffmpeg: $(lipo -archs "$BIN/ffmpeg")"
echo "  deno:   $(lipo -archs "$BIN/deno")"
