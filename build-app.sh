#!/bin/bash
# Builds SheetFeed.app and installs it in ~/Applications (or the folder given as the first argument).
#
# Build output lives in ~/Library/Caches because files in an iCloud-synced Documents folder pick up
# Finder metadata that code signing refuses. The Homebrew formula overrides it with SHEETFEED_WORK and passes
# --disable-sandbox in SHEETFEED_SWIFT_FLAGS, since Homebrew already builds inside its own sandbox.
set -euo pipefail

cd "$(dirname "$0")"
DEST="${1:-$HOME/Applications}"
WORK="${SHEETFEED_WORK:-$HOME/Library/Caches/SheetFeed}"
APP="$WORK/SheetFeed.app"
VERSION="$(cat VERSION)"
read -r -a SWIFT_FLAGS <<< "${SHEETFEED_SWIFT_FLAGS:-}"

swift build --configuration release --scratch-path "$WORK/build" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
BIN="$(swift build --configuration release --scratch-path "$WORK/build" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path)/SheetFeed"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SheetFeed"
sed "s/__VERSION__/$VERSION/g" Info.plist > "$APP/Contents/Info.plist"

# App icon: Icon/AppIcon-1024.png (drawn by Icon/make-icon.swift) at every size macOS asks for.
ICONSET="$WORK/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for px in 16 32 128 256 512; do
    sips -z $px $px Icon/AppIcon-1024.png --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) Icon/AppIcon-1024.png --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

xattr -cr "$APP"
codesign --force --sign - "$APP"

mkdir -p "$DEST"
rm -rf "$DEST/SheetFeed.app"
ditto "$APP" "$DEST/SheetFeed.app"
echo "Installed $DEST/SheetFeed.app ($VERSION)"
