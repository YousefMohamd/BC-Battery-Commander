#!/bin/bash
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/BattOpt.app"
BIN="$ROOT/.build/release/BattOpt"

swift build -c release --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BattOpt"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/../../assets/icons/battopt.icns" ]; then
    cp "$ROOT/../../assets/icons/battopt.icns" "$APP/Contents/Resources/battopt.icns"
fi
chmod +x "$APP/Contents/MacOS/BattOpt"
echo "Built: $APP"
