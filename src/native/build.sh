#!/bin/bash
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/BattOpt.app"
BIN="$ROOT/.build/BattOpt"
SRC="$ROOT/Sources/BattOpt"

rm -rf "$ROOT/.build"
mkdir -p "$ROOT/.build"

echo "=== Building with swiftc ==="
swiftc -O \
  -target x86_64-apple-macosx10.15 \
  -framework AppKit -framework IOKit -framework Foundation \
  -o "$BIN" \
  "$SRC/main.swift" \
  "$SRC/AppDelegate.swift" \
  "$SRC/StatusItemController.swift" \
  "$SRC/SMCReader.swift" \
  "$SRC/StateStore.swift" \
  "$SRC/DispatchBridge.swift" \
  "$SRC/MenuBuilder.swift" \
  2>&1

if [ ! -f "$BIN" ]; then echo "BUILD FAILED"; exit 1; fi
echo "Compiled: $BIN"

echo "=== Bundling .app ==="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BattOpt"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/../../assets/icons/battopt.icns" ]; then
    cp "$ROOT/../../assets/icons/battopt.icns" "$APP/Contents/Resources/"
fi
chmod +x "$APP/Contents/MacOS/BattOpt"
echo "Built: $APP"
