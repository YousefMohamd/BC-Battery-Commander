#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_SCRIPT="$SCRIPT_DIR/BattOpt.applescript"
TMP_APP="/tmp/BattOpt.app"
INSTALL_APP="/Applications/BattOpt.app"
APP_PATH="$TMP_APP"
INSTALL=0
TEST=0
BUILD_OK=0
BACKUP_PATH=""

usage() {
    echo "Usage: $0 [--install] [--test]"
    exit 2
}

for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --test) TEST=1 ;;
        *) usage ;;
    esac
done

if [ ! -f "$APPLE_SCRIPT" ]; then
    echo "FAIL: AppleScript source not found: $APPLE_SCRIPT"
    BUILD_OK=0
else
    rm -rf "$TMP_APP"

    if osacompile -o "$TMP_APP" "$APPLE_SCRIPT"; then
        BUILD_OK=1
        echo "Build completed: $TMP_APP"
    else
        echo "FAIL: osacompile failed"
        BUILD_OK=0
    fi
fi

verify_app() {
    local path="$1"
    local file_output=""
    local executable_value=""
    local file_ok=0
    local plist_ok=0

    echo
    echo "=== BattOpt.app Verification ==="
    echo "App path: $path"

    if [ -x "$path/Contents/MacOS/applet" ]; then
        file_output=$(file "$path/Contents/MacOS/applet" 2>&1)
        echo "$file_output"
        if echo "$file_output" | grep -q "Mach-O"; then
            file_ok=1
            echo "PASS: executable is Mach-O"
        else
            echo "FAIL: executable is not Mach-O"
        fi
    else
        echo "FAIL: missing executable: $path/Contents/MacOS/applet"
    fi

    if [ -f "$path/Contents/Info.plist" ]; then
        plutil -p "$path/Contents/Info.plist" 2>&1 | grep "CFBundleExecutable" || true
        executable_value=$(
            /usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
                "$path/Contents/Info.plist" 2>/dev/null || true
        )
        if [ "$executable_value" = "applet" ]; then
            plist_ok=1
            echo "PASS: CFBundleExecutable is applet"
        else
            echo "FAIL: CFBundleExecutable is ${executable_value:-missing}, expected applet"
        fi
    else
        echo "FAIL: missing Info.plist: $path/Contents/Info.plist"
    fi

    echo "Code-signing status:"
    codesign -dv "$path" 2>&1 | head -2 || true

    echo "Built app: $path"

    [ "$file_ok" -eq 1 ] && [ "$plist_ok" -eq 1 ]
}

if [ "$BUILD_OK" -eq 1 ]; then
    if ! verify_app "$TMP_APP"; then
        echo "FAIL: temporary app verification failed"
        BUILD_OK=0
    fi
fi

if [ "$INSTALL" -eq 1 ] && [ "$BUILD_OK" -eq 1 ]; then
    BACKUP_PATH="/Applications/BattOpt.app.backup-$(date +%Y%m%d-%H%M%S)"

    if [ -e "$INSTALL_APP" ]; then
        echo "Backing up existing app to: $BACKUP_PATH"
        if ! sudo mv "$INSTALL_APP" "$BACKUP_PATH"; then
            echo "FAIL: could not back up existing app"
            BUILD_OK=0
        fi
    fi

    if [ "$BUILD_OK" -eq 1 ]; then
        if sudo mv "$TMP_APP" "$INSTALL_APP"; then
            APP_PATH="$INSTALL_APP"
            echo "Installed app: $APP_PATH"
        else
            echo "FAIL: could not install app at $INSTALL_APP"
            BUILD_OK=0
        fi
    fi
fi

if [ "$TEST" -eq 1 ]; then
    echo
    echo "Test mode: temporary app retained at $TMP_APP"
fi

echo
echo "=== Final Verification ==="
if verify_app "$APP_PATH"; then
    echo "PASS: all required app checks passed"
else
    echo "FAIL: one or more required app checks failed"
    BUILD_OK=0
fi

if [ "$INSTALL" -eq 1 ] && [ -n "$BACKUP_PATH" ]; then
    echo "Backup path: $BACKUP_PATH"
fi

exit $([ "$BUILD_OK" -eq 1 ] && echo 0 || echo 1)
