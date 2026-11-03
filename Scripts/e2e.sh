#!/bin/sh
# End-to-end check: a test build of the real program downloads real (short) videos by itself and the
# files are checked. Needs the internet. Takes a few minutes (the tools are downloaded into the build).
# Nothing of the real queue / history is touched (own data folder), no window comes to the front.
#   sh Scripts/e2e.sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d)"
APP="$WORK/app/Scorpena.app"
BUNDLE="com.yaroslavlukyanov.scorpena.e2e"
trap 'pkill -f "$WORK/app/Scorpena.app" 2>/dev/null || true; defaults delete "$BUNDLE" 2>/dev/null || true; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/app"

echo "== building the test build (arm64 only)"
SCORPENA_TEST_BUILD=1 SCORPENA_ARCHS=arm64 sh Scripts/build-app.sh "$WORK/app" > "$WORK/build.log" 2>&1 \
    || { echo "FAIL  the test build did not build"; tail -5 "$WORK/build.log"; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE" "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP" > /dev/null 2>&1
FFMPEG="$APP/Contents/Resources/bin/ffmpeg"

defaults write "$BUNDLE" appLanguage ru
defaults write "$BUNDLE" lastSeenChangelogVersion 3.2
defaults write "$BUNDLE" cookiePreflightDone -bool true
defaults write "$BUNDLE" destinationFolder "$WORK/dl"
defaults write "$BUNDLE" speedLimitStep -int 9

LINK="https://www.youtube.com/watch?v=jNQXAC9IVRw"      # «Me at the zoo», 19 seconds
failed=0

duration_of() {   # seconds of a media file
    "$FFMPEG" -i "$1" 2>&1 | sed -n 's/.*Duration: \([0-9]*\):\([0-9]*\):\([0-9.]*\).*/\1 \2 \3/p' | head -1 | awk '{print $1*3600+$2*60+$3}'
}

scenario() {   # name, extra env..., then the checks run by the caller on $OUTDIR / $LOG
    NAME="$1"; shift
    OUTDIR="$WORK/dl-$NAME"; LOG="$WORK/$NAME.log"; mkdir -p "$OUTDIR"; rm -f "$LOG"
    echo "== $NAME"
    open -n -g -j --env SCORPENA_SUPPORT_DIR="$WORK/support-$NAME" --env SCORPENA_E2E_LINK="$LINK" \
        --env SCORPENA_E2E_DIR="$OUTDIR" --env SCORPENA_E2E_LOG="$LOG" "$@" "$APP"
    waited=0
    until grep -q "^RESULT" "$LOG" 2>/dev/null || [ "$waited" -ge 270 ]; do sleep 2; waited=$((waited + 2)); done
    pkill -f "$APP/Contents/MacOS" 2>/dev/null || true
    sleep 1
}

check() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; failed=1; fi; }

bar_never_goes_back() {
    awk -F'|' '/^PROGRESS/ { if ($2 + 0 < max - 0.0001) bad = 1; if ($2 + 0 > max) max = $2 + 0 } END { exit bad }' "$LOG"
}

scenario video
FILE="$(sed -n 's/^RESULT|ok|//p' "$LOG" | head -1)"
check "video: finished" '[ -n "$FILE" ] && [ -f "$FILE" ]'
check "video: about 19 seconds long" '[ -f "$FILE" ] && awk -v d="$(duration_of "$FILE")" "BEGIN { exit !(d > 17 && d < 21) }"'
check "video: the bar never went back" bar_never_goes_back
check "video: the bar reached the end" 'grep -q "^PROGRESS|1.000" "$LOG"'

scenario audio --env SCORPENA_E2E_AUDIO=1
FILE="$(sed -n 's/^RESULT|ok|//p' "$LOG" | head -1)"
check "sound: finished as mp3" '[ -n "$FILE" ] && [ -f "$FILE" ] && case "$FILE" in *.mp3) true;; *) false;; esac'
check "sound: the bar never went back" bar_never_goes_back

scenario clip --env SCORPENA_E2E_CLIP=3-12
FILE="$(sed -n 's/^RESULT|ok|//p' "$LOG" | head -1)"
check "clip 3-12: finished" '[ -n "$FILE" ] && [ -f "$FILE" ]'
check "clip 3-12: about 9 seconds long" '[ -f "$FILE" ] && awk -v d="$(duration_of "$FILE")" "BEGIN { exit !(d > 8 && d < 10.5) }"'
check "clip 3-12: the bar never went back" bar_never_goes_back

[ "$failed" = 0 ] && echo "ALL E2E CHECKS PASSED" || { echo "SOME E2E CHECKS FAILED"; exit 1; }
