#!/bin/bash
# build-app-native.sh — Battery Commander (BC) standalone app builder.
#
# Compiles the Swift + AppKit sources in this directory with the
# Command Line Tools swiftc (no xcodebuild, UI 100% in code), assembles
# BatteryCommander.app by hand (the build-app.sh pattern), ad-hoc
# signs it, and verifies the bundle.
#
# Stage A built the bench bundle with this script. Stage B adds the
# FR-006 launcher merge (Housekeeping.swift). Output is still only
# src/app/build/BatteryCommander.app: this script never installs —
# the gated install to /Applications is a separate, separately
# approved manual step (design §8.2, Stage B).
#
# Usage: $0 [--clean]   (--clean is the default behaviour: the build
#                        directory is always rebuilt from scratch)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_PATH="$BUILD_DIR/BatteryCommander.app"
EXE_NAME="BatteryCommander"

SOURCES=(
    "$SCRIPT_DIR/main.swift"
    "$SCRIPT_DIR/Shell.swift"
    "$SCRIPT_DIR/StatusProvider.swift"
    "$SCRIPT_DIR/Notifier.swift"
    "$SCRIPT_DIR/MenuModel.swift"
    "$SCRIPT_DIR/Housekeeping.swift"
    "$SCRIPT_DIR/AppDelegate.swift"
)

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- Toolchain ------------------------------------------------------------
SWIFTC="$(command -v swiftc || true)"
[ -n "$SWIFTC" ] || fail "swiftc not found"
echo "swiftc: $("$SWIFTC" --version | head -1)"

SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || true)"
SDK_FLAG=()
[ -n "$SDK_PATH" ] && SDK_FLAG=(-sdk "$SDK_PATH")

# --- Icon (same resolution order as build-app.sh) -------------------------
ICON_SOURCE=""
if [ -f "$HOME/.battery-commander/icons/Battery Commander.icns" ]; then
    ICON_SOURCE="$HOME/.battery-commander/icons/Battery Commander.icns"
elif [ -f "$SCRIPT_DIR/../../../assets/icons/Battery Commander.icns" ]; then
    ICON_SOURCE="$SCRIPT_DIR/../../../assets/icons/Battery Commander.icns"
fi
[ -n "$ICON_SOURCE" ] || fail "Battery Commander.icns not found"

# --- Clean build ----------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" \
    || fail "cannot create bundle dirs"

# --- Compile ---------------------------------------------------------------
echo "Compiling ${#SOURCES[@]} Swift sources..."
"$SWIFTC" "${SDK_FLAG[@]}" \
    -target x86_64-apple-macos10.15 \
    -module-name BatteryCommander \
    -o "$APP_PATH/Contents/MacOS/$EXE_NAME" \
    "${SOURCES[@]}" || fail "swiftc failed"
echo "PASS: compiled"

# --- Assemble ---------------------------------------------------------------
cp "$SCRIPT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist" || fail "Info.plist copy"
cp "$ICON_SOURCE" "$APP_PATH/Contents/Resources/Battery Commander.icns" || fail "icon copy"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

# --- Ad-hoc sign --------------------------------------------------------------
codesign --force --sign - "$APP_PATH" || fail "codesign failed"
echo "PASS: ad-hoc signed"

# --- Verify -------------------------------------------------------------------
PLIST="$APP_PATH/Contents/Info.plist"
BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
[ "$BID" = "com.batterycommander.launcher" ] || fail "bundle id is $BID"
UIE="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST")"
[ "$UIE" = "true" ] || fail "LSUIElement is $UIE"
FILE_OUT="$(file "$APP_PATH/Contents/MacOS/$EXE_NAME")"
echo "$FILE_OUT"
case "$FILE_OUT" in
    *"Mach-O 64-bit executable x86_64"*) echo "PASS: Mach-O x86_64 executable" ;;
    *) fail "unexpected executable type" ;;
esac
codesign -dv "$APP_PATH" 2>&1 | grep -E "Identifier|Signature" || true
echo "PASS: bundle verified"
echo "APP: $APP_PATH"
du -sh "$APP_PATH" | awk '{print "SIZE: " $1}'

