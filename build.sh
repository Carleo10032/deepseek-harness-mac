#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/DeepSeek Harness.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/DeepSeekHarnessApp"

/bin/rm -rf "$BUILD_DIR"
/bin/mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

SOURCES=("$SCRIPT_DIR"/Sources/*.swift)

/usr/bin/xcrun swiftc \
    -O \
    -parse-as-library \
    -framework AppKit \
    -framework Combine \
    -framework SwiftUI \
    -framework WebKit \
    "${SOURCES[@]}" \
    -o "$EXECUTABLE"

/bin/cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/bin/cp "$SCRIPT_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
/bin/cp "$SCRIPT_DIR/Assets/AppIcon-blue.png" "$APP_BUNDLE/Contents/Resources/AppIcon-blue.png"
/usr/bin/codesign --force --sign - "$APP_BUNDLE"

echo "$APP_BUNDLE"
