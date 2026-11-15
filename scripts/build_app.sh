#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
case "$CONFIG" in
    debug|release) ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 1
        ;;
esac
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
# 单二进制无需 --deep（Apple 已不推荐），直接对 bundle 签名
codesign --force --sign - --identifier com.mypaste.app "$APP" >/dev/null
codesign --verify --strict "$APP"

echo "Built: $APP"
echo "Run:   open \"$APP\""
echo "Note:  Ad-hoc signed; every rebuild changes the signature, so Screen Recording"
echo "       permission may need to be granted again in System Settings."
