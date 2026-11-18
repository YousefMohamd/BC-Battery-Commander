#!/bin/bash
# build-app.sh — Battery Commander app bundle builder (W5.1)
#
# Builds BatteryCommander.app from BatteryCommander.applescript via
# osacompile, copies BatteryCommander-launcher.sh into Resources, copies
# the icon if present, and configures the bundle metadata.
#
# Usage: $0 [--install] [--test]
#   (no flags)  build to /tmp/BatteryCommander.app only, verify, exit.
#   --install   also install to /Applications/BatteryCommander.app (uses
#               sudo mv; this is a USER deploy step, never run by the agent).
#   --test      retain the temporary app (do not clean it up).
#
# BC rules: no battopt binary, no trial-renew helpers, no hardcoded user.
# Bundle identity: com.batterycommander.launcher, "Battery Commander",
# icon "Battery Commander". The old BattOpt.app bundle is NOT touched by
# this script; it is on the dead-file removal list (W6/deploy).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_SCRIPT="$SCRIPT_DIR/BatteryCommander.applescript"
LAUNCHER_SCRIPT="$SCRIPT_DIR/BatteryCommander-launcher.sh"
TMP_APP="/tmp/BatteryCommander.app"
INSTALL_APP="/Applications/BatteryCommander.app"
APP_PATH="$TMP_APP"
INSTALL=0
TEST=0
BUILD_OK=0
ICON_OK=0
BACKUP_PATH=""

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cleanup() {
    [ -d "$TMP_APP" ] && rm -rf "$TMP_APP"
}
trap cleanup EXIT

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

set_plist_value() {
    local plist="$1"
    local key="$2"
    local type="$3"
    local value="$4"

    /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$plist"
}

configure_bundle() {
    local app_path="$1"
    local plist="$app_path/Contents/Info.plist"

    [ -f "$plist" ] || {
        echo "FAIL: missing Info.plist: $plist"
        return 1
    }

    set_plist_value "$plist" "LSUIElement" "bool" "true" || return 1
    set_plist_value "$plist" "CFBundleIdentifier" "string" "com.batterycommander.launcher" || return 1
    set_plist_value "$plist" "CFBundleName" "string" "Battery Commander" || return 1

    if [ "$ICON_OK" -eq 1 ]; then
        set_plist_value "$plist" "CFBundleIconFile" "string" "Battery Commander" || return 1
    fi

    return 0
}

find_icon() {
    # "Battery Commander.icns" - generate it from the repo-root
    # "Battery Commander.png" with iconutil at deploy time if it is absent.
    if [ -f "$HOME/.battery-commander/icons/Battery Commander.icns" ]; then
        ICON_SOURCE="$HOME/.battery-commander/icons/Battery Commander.icns"
        return 0
    fi
    if [ -f "$SCRIPT_DIR/../../assets/icons/Battery Commander.icns" ]; then
        ICON_SOURCE="$SCRIPT_DIR/../../assets/icons/Battery Commander.icns"
        return 0
    fi

    return 1
}

verify_mach_o() {
    local app_path="$1"
    local applet="$app_path/Contents/MacOS/applet"
    local file_output=""

    [ -f "$applet" ] || {
        echo "FAIL: missing applet executable: $applet"
        return 1
    }

    file_output=$(file "$applet" 2>&1)
    echo "$file_output"

    if echo "$file_output" | grep -q "Mach-O"; then
        echo "PASS: applet is a Mach-O binary"
        return 0
    fi

    echo "FAIL: applet is not a Mach-O binary"
    return 1
}

verify_launcher() {
    local app_path="$1"
    local launcher="$app_path/Contents/Resources/BatteryCommander-launcher.sh"

    if [ -f "$launcher" ] && [ -x "$launcher" ]; then
        echo "PASS: BatteryCommander-launcher.sh is present and executable"
        return 0
    fi

    echo "FAIL: missing or non-executable launcher: $launcher"
    return 1
}

verify_app() {
    local path="$1"
    local file_output=""
    local executable_value=""
    local bundle_identifier=""
    local lsui_element=""
    local file_ok=0
    local plist_ok=0
    local identifier_ok=0
    local lsui_ok=0
    local launcher_ok=0

    echo
    echo "=== BatteryCommander.app Verification ==="
    echo "App path: $path"

    if verify_mach_o "$path"; then
        file_ok=1
    fi

    local plist="$path/Contents/Info.plist"
    if [ -f "$plist" ]; then
        executable_value=$(
            /usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
                "$plist" 2>/dev/null || true
        )
        if [ "$executable_value" = "applet" ]; then
            plist_ok=1
            echo "PASS: CFBundleExecutable is applet"
        else
            echo "FAIL: CFBundleExecutable is ${executable_value:-missing}, expected applet"
        fi

        bundle_identifier=$(
            /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
                "$plist" 2>/dev/null || true
        )
        if [ "$bundle_identifier" = "com.batterycommander.launcher" ]; then
            identifier_ok=1
            echo "PASS: CFBundleIdentifier is com.batterycommander.launcher"
        else
            echo "FAIL: CFBundleIdentifier is ${bundle_identifier:-missing}, expected com.batterycommander.launcher"
        fi

        lsui_element=$(
            /usr/libexec/PlistBuddy -c "Print :LSUIElement" \
                "$plist" 2>/dev/null || true
        )
        if [ "$lsui_element" = "true" ]; then
            lsui_ok=1
            echo "PASS: LSUIElement is true"
        else
            echo "FAIL: LSUIElement is ${lsui_element:-missing}, expected true"
        fi
    else
        echo "FAIL: missing Info.plist: $plist"
    fi

    if [ -f "$path/Contents/Resources/Battery Commander.icns" ]; then
        echo "PASS: Battery Commander.icns is present"
    else
        echo "SKIP: icon is not present (optional - generate from Battery Commander.png at deploy)"
    fi

    if verify_launcher "$path"; then
        launcher_ok=1
    fi

    echo "Code-signing status:"
    codesign -dv "$path" 2>&1 | head -2 || true

    echo "Built app: $path"

    [ "$file_ok" -eq 1 ] &&
    [ "$plist_ok" -eq 1 ] &&
    [ "$identifier_ok" -eq 1 ] &&
    [ "$lsui_ok" -eq 1 ] &&
    [ "$launcher_ok" -eq 1 ]
}

register_app() {
    local app_path="$1"

    if [ ! -x "$LSREGISTER" ]; then
        echo "FAIL: lsregister not found: $LSREGISTER"
        return 1
    fi

    if "$LSREGISTER" -f "$app_path"; then
        echo "LaunchServices registration completed: $app_path"
        return 0
    fi

    echo "FAIL: LaunchServices registration failed: $app_path"
    return 1
}

if [ ! -f "$APPLE_SCRIPT" ]; then
    echo "FAIL: AppleScript source not found: $APPLE_SCRIPT"
    exit 1
fi

if [ ! -f "$LAUNCHER_SCRIPT" ]; then
    echo "FAIL: launcher source not found: $LAUNCHER_SCRIPT"
    exit 1
fi

rm -rf "$TMP_APP"

if osacompile -s -o "$TMP_APP" "$APPLE_SCRIPT"; then
    if cp "$LAUNCHER_SCRIPT" "$TMP_APP/Contents/Resources/BatteryCommander-launcher.sh" &&
        chmod 755 "$TMP_APP/Contents/Resources/BatteryCommander-launcher.sh"; then

        if find_icon; then
            if cp "$ICON_SOURCE" "$TMP_APP/Contents/Resources/Battery Commander.icns"; then
                ICON_OK=1
                echo "Icon copied: $ICON_SOURCE"
            else
                echo "WARN: could not copy icon from $ICON_SOURCE; continuing without it"
            fi
        else
            echo "WARN: icon not found; continuing without it (generate Battery Commander.icns from Battery Commander.png at deploy)"
        fi

        if configure_bundle "$TMP_APP"; then
            BUILD_OK=1
            echo "Build completed: $TMP_APP"
        else
            echo "FAIL: could not configure app bundle metadata"
        fi
    else
        echo "FAIL: could not add launcher to app resources"
    fi
else
    echo "FAIL: osacompile failed"
fi

if [ "$BUILD_OK" -eq 1 ]; then
    if ! verify_app "$TMP_APP"; then
        echo "FAIL: temporary app verification failed"
        BUILD_OK=0
    fi
fi

if [ "$INSTALL" -eq 1 ] && [ "$BUILD_OK" -eq 1 ]; then
    BACKUP_PATH="/Applications/BatteryCommander.app.backup-$(date +%Y%m%d-%H%M%S)"
    BACKUP_SUFFIX=1

    while [ -e "$BACKUP_PATH" ]; do
        BACKUP_PATH="/Applications/BatteryCommander.app.backup-$(date +%Y%m%d-%H%M%S)-${BACKUP_SUFFIX}"
        BACKUP_SUFFIX=$((BACKUP_SUFFIX + 1))
    done

    if [ -e "$INSTALL_APP" ]; then
        echo "Backing up existing app to: $BACKUP_PATH"

        if ! sudo mv "$INSTALL_APP" "$BACKUP_PATH"; then
            echo "FAIL: could not move existing app to backup"
            BUILD_OK=0
        fi
    fi

    if [ "$BUILD_OK" -eq 1 ]; then
        if sudo mv "$TMP_APP" "$INSTALL_APP"; then
            APP_PATH="$INSTALL_APP"
            echo "Installed app: $APP_PATH"

            if ! verify_mach_o "$INSTALL_APP"; then
                echo "FAIL: installed applet is not a Mach-O binary"
                BUILD_OK=0
            fi

            if ! verify_launcher "$INSTALL_APP"; then
                echo "FAIL: installed launcher is missing or not executable"
                BUILD_OK=0
            fi

            if [ "$BUILD_OK" -eq 1 ] && ! register_app "$INSTALL_APP"; then
                BUILD_OK=0
            fi
        else
            echo "FAIL: could not install app at $INSTALL_APP"
            BUILD_OK=0
        fi
    fi
fi

if [ "$TEST" -eq 1 ]; then
    echo
    echo "Test mode: temporary app retained at $TMP_APP"
    trap - EXIT
fi

echo
echo "=== Final Verification ==="
if verify_app "$APP_PATH"; then
    echo "PASS: all required app checks passed"
else
    echo "FAIL: one or more required app checks failed"
    BUILD_OK=0
fi

if [ "$INSTALL" -eq 1 ] && [ -n "$BACKUP_PATH" ] && [ -d "$BACKUP_PATH" ]; then
    echo "Backup path: $BACKUP_PATH"
fi

if [ "$BUILD_OK" -eq 1 ]; then
    exit 0
fi

exit 1
