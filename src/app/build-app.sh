#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_SCRIPT="$SCRIPT_DIR/BattOpt.applescript"
LAUNCHER_SCRIPT="$SCRIPT_DIR/BattOpt-launcher.sh"
ICON_SOURCE="$SCRIPT_DIR/battopt.icns"
TMP_APP="/tmp/BattOpt.app"
INSTALL_APP="/Applications/BattOpt.app"
APP_PATH="$TMP_APP"
INSTALL=0
TEST=0
BUILD_OK=0
BACKUP_PATH=""

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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
    set_plist_value "$plist" "CFBundleIdentifier" "string" "com.yousef.battopt.launcher" || return 1
    set_plist_value "$plist" "CFBundleName" "string" "BattOpt" || return 1
    set_plist_value "$plist" "CFBundleIconFile" "string" "battopt" || return 1

    return 0
}

if [ ! -f "$APPLE_SCRIPT" ]; then
    echo "FAIL: AppleScript source not found: $APPLE_SCRIPT"
    BUILD_OK=0
elif [ ! -f "$LAUNCHER_SCRIPT" ]; then
    echo "FAIL: launcher source not found: $LAUNCHER_SCRIPT"
    BUILD_OK=0
elif [ ! -f "$ICON_SOURCE" ]; then
    echo "FAIL: icon source not found: $ICON_SOURCE"
    BUILD_OK=0
else
    rm -rf "$TMP_APP"

    if osacompile -o "$TMP_APP" "$APPLE_SCRIPT"; then
        if cp "$LAUNCHER_SCRIPT" "$TMP_APP/Contents/Resources/BattOpt-launcher.sh"; then
            chmod 755 "$TMP_APP/Contents/Resources/BattOpt-launcher.sh"

            if cp "$ICON_SOURCE" "$TMP_APP/Contents/Resources/battopt.icns"; then
                if configure_bundle "$TMP_APP"; then
                    BUILD_OK=1
                    echo "Build completed: $TMP_APP"
                else
                    echo "FAIL: could not configure app bundle metadata"
                    BUILD_OK=0
                fi
            else
                echo "FAIL: could not copy icon into app resources"
                BUILD_OK=0
            fi
        else
            echo "FAIL: could not add launcher to app resources"
            BUILD_OK=0
        fi
    else
        echo "FAIL: osacompile failed"
        BUILD_OK=0
    fi
fi

verify_app() {
    local path="$1"
    local file_output=""
    local executable_value=""
    local bundle_identifier=""
    local bundle_name=""
    local icon_file=""
    local lsui_element=""
    local file_ok=0
    local executable_ok=0
    local plist_ok=0
    local identifier_ok=0
    local name_ok=0
    local icon_ok=0
    local lsui_ok=0
    local launcher_ok=0

    echo
    echo "=== BattOpt.app Verification ==="
    echo "App path: $path"

    if [ -x "$path/Contents/MacOS/applet" ]; then
        file_output=$(file "$path/Contents/MacOS/applet" 2>&1)
        echo "$file_output"
        if echo "$file_output" | grep -q "Mach-O"; then
            file_ok=1
            executable_ok=1
            echo "PASS: executable is Mach-O"
        else
            echo "FAIL: executable is not Mach-O"
        fi
    else
        echo "FAIL: missing executable: $path/Contents/MacOS/applet"
    fi

    if [ -f "$path/Contents/Info.plist" ]; then
        plutil -p "$path/Contents/Info.plist" 2>&1 | grep -E "CFBundleExecutable|CFBundleIdentifier|CFBundleName|CFBundleIconFile|LSUIElement" || true

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

        bundle_identifier=$(
            /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
                "$path/Contents/Info.plist" 2>/dev/null || true
        )
        if [ "$bundle_identifier" = "com.yousef.battopt.launcher" ]; then
            identifier_ok=1
            echo "PASS: CFBundleIdentifier is com.yousef.battopt.launcher"
        else
            echo "FAIL: CFBundleIdentifier is ${bundle_identifier:-missing}, expected com.yousef.battopt.launcher"
        fi

        bundle_name=$(
            /usr/libexec/PlistBuddy -c "Print :CFBundleName" \
                "$path/Contents/Info.plist" 2>/dev/null || true
        )
        if [ "$bundle_name" = "BattOpt" ]; then
            name_ok=1
            echo "PASS: CFBundleName is BattOpt"
        else
            echo "FAIL: CFBundleName is ${bundle_name:-missing}, expected BattOpt"
        fi

        icon_file=$(
            /usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" \
                "$path/Contents/Info.plist" 2>/dev/null || true
        )
        if [ "$icon_file" = "battopt" ]; then
            echo "PASS: CFBundleIconFile is battopt"
        else
            echo "FAIL: CFBundleIconFile is ${icon_file:-missing}, expected battopt"
        fi
    else
        echo "FAIL: missing Info.plist: $path/Contents/Info.plist"
    fi

    if [ -f "$path/Contents/Resources/battopt.icns" ]; then
        icon_ok=1
        echo "PASS: battopt.icns is present"
    else
        echo "FAIL: missing icon: $path/Contents/Resources/battopt.icns"
    fi

    lsui_element=$(
        /usr/libexec/PlistBuddy -c "Print :LSUIElement" \
            "$path/Contents/Info.plist" 2>/dev/null || true
    )
    if [ "$lsui_element" = "true" ]; then
        lsui_ok=1
        echo "PASS: LSUIElement is true"
    else
        echo "FAIL: LSUIElement is ${lsui_element:-missing}, expected true"
    fi

    if [ -x "$path/Contents/Resources/BattOpt-launcher.sh" ]; then
        launcher_ok=1
        echo "PASS: BattOpt-launcher.sh is present and executable"
    else
        echo "FAIL: missing or non-executable launcher: $path/Contents/Resources/BattOpt-launcher.sh"
    fi

    echo "Code-signing status:"
    codesign -dv "$path" 2>&1 | head -2 || true

    echo "Built app: $path"

    [ "$file_ok" -eq 1 ] &&
    [ "$executable_ok" -eq 1 ] &&
    [ "$plist_ok" -eq 1 ] &&
    [ "$identifier_ok" -eq 1 ] &&
    [ "$name_ok" -eq 1 ] &&
    [ "$icon_ok" -eq 1 ] &&
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

            if ! register_app "$INSTALL_APP"; then
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
