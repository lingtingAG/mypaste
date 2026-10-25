#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
cd "$ROOT"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/MyPaste.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/MyPaste" "$APP/Contents/MacOS/MyPaste"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - --identifier com.mypaste.app "$APP" >/dev/null

echo "Built: $APP"
echo "Run:   open \"$APP\""
echo "Note:  Grant Screen Recording to this app once in System Settings."
