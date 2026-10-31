#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

TRIPLE="${SWIFT_TRIPLE:-x86_64-apple-macosx13.0}"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="HackintoshFixer"
APP_DIR="$ROOT_DIR/.build/packaged/$APP_NAME.app"
ARCHIVE="$ROOT_DIR/.build/packaged/$APP_NAME-macOS-Intel.zip"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
ICON_SET="$ROOT_DIR/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "$ROOT_DIR/icon.png" ]]; then
    echo "Missing app icon source: icon.png" >&2
    exit 1
fi

swift build --configuration "$CONFIGURATION" --triple "$TRIPLE"
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --triple "$TRIPLE" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$RESOURCES_DIR" "$ICON_SET"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

trap 'rm -f "$ICON_SET/AppIcon.png"' EXIT
sips -s format png -z 1024 1024 "$ROOT_DIR/icon.png" --out "$ICON_SET/AppIcon.png" >/dev/null
actool "$ROOT_DIR/Assets.xcassets" \
    --app-icon AppIcon \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --compile "$RESOURCES_DIR"

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$APP_DIR/Contents/Info.plist")" != "APPL" ]]; then
    echo "Packaged bundle is not a macOS application." >&2
    exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
echo "Created macOS application: $APP_DIR"
echo "Created distributable archive: $ARCHIVE"
