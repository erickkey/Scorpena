#!/bin/sh
# Runs every check: the translations, then each test in Tests/ built together with the app's sources
# (without the app's own entry point). Needs YouTubeDownloader/Secrets.swift (an empty stand-in is fine).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
failed=0

echo "== translations"
python3 Scripts/check-translations.py || failed=1

SOURCES="$(ls YouTubeDownloader/*.swift | grep -v YouTubeDownloaderApp.swift)"
for dir in Tests/*/; do
    name="$(basename "$dir")"
    echo "== $name"
    # shellcheck disable=SC2086
    swiftc -sdk "$SDK" -target arm64-apple-macosx13.0 $SOURCES "$dir/main.swift" -o "$OUT/$name" 2>"$OUT/$name.log" \
        || { echo "FAIL  did not compile"; grep error "$OUT/$name.log" | head -5; failed=1; continue; }
    "$OUT/$name" || failed=1
done

[ "$failed" = 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
