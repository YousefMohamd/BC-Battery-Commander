#!/bin/sh
# Battery Commander — reproducible DMG build (publish artifact).
#
# Packages the VERIFIED live end-state into BatteryCommander-1.0.dmg:
#   - the installed app (exe md5-checked against the live-proven build)
#     with the distribution payload added under Contents/Resources/payload/
#   - payload: daemon binary (md5-checked), publish LaunchDaemon plist
#     (generated from the canonical daemon/ template: program path ->
#     /Library/PrivilegedHelperTools/bc-limit, comments stripped),
#     the deployed helper set (from ~/.battery-commander/), the user
#     agent plists (from src/agents/, @HOME@ templates), the sudoers
#     rule (@USER@ template), the default config, setup.sh, uninstall.sh
#   - DMG root: the app, Install/Uninstall .command launchers, README,
#     and an /Applications shortcut
# The staged app is re-sealed with an ad-hoc signature after the
# payload is added (v1 ships unsigned; see README). No live path is
# touched: the build reads the live install and writes only the DMG.
#
# Output: <repo>/release/BatteryCommander-1.0.dmg (git-ignored).

set -eu

PKG_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$PKG_DIR/.." && pwd)
STATE_DIR="$HOME/.battery-commander"
APP_SRC="/Applications/BatteryCommander.app"
DAEMON_BIN_SRC="$REPO/battopt-project/bc-build/bc-limit"
DAEMON_SRC="$REPO/daemon/bc-limit-v1.7.1.c"
PLIST_TEMPLATE="$REPO/daemon/com.batterycommander.bclimit.plist"
OUT_DIR="$REPO/release"
DMG="$OUT_DIR/BatteryCommander-1.0.dmg"
VOLNAME="Battery Commander 1.0"

# The verified end-state (2026-11-18). The build refuses to package
# anything else.
EXPECT_APP_EXE=a967ccaffa6ba3d91068116b6feb8857
EXPECT_DAEMON_BIN=83297d730680bfada97da1eee22f4554
EXPECT_DAEMON_SRC=441c61dc3c0da36ced9170470df5b9b4
EXPECT_DISPLAY_STATE=784299079ca5b6f05c8fdb7fd53fe986
EXPECT_DISPATCH=d9881746228de0916bf94642dd9cb0d1
EXPECT_WATCHDOG=8956968de23e8af1882f81999a0f5c5d

# The deployed helper set (state-dir scripts + powerwatch binary).
# Deliberately excluded: swiftbar_watchdog.sh (retired with the
# SwiftBar plugin; referenced by nothing live), *.pre-* backups, logs,
# runtime state, and the legacy icons/battopt.png fallback.
HELPERS="ac_watcher.sh adaptive.sh arm_sleep.sh bc-episode-tracker.py \
bc-episode-tracker.sh bc-status bc-tracker-live.py bc-tracker-live.sh \
bc-verify-run.sh bc-verify.py bc-verify.sh bc-watchdog-sentinel.sh \
bc-watchdog.sh cleanup_logs.sh conflict_check.sh dispatch.sh \
display_state.sh ensure_limit.sh force_reset.sh launch_swiftbar.sh \
morning_report.sh pmset_check.sh post_wake_restore.sh power_mode.sh \
power_saver.sh powerwatch predictive.sh pre_sleep_cleanup.sh \
process_monitor.sh project_health.sh sailing_tracker.sh \
self_healing.sh self_maintenance.sh sleep_manager.sh sleep_monitor.sh \
state_guard.sh state_hygiene.sh system_guard.sh wake_analyzer.sh"

# The live user-agent set (canonical templates in src/agents/).
AGENTS="com.batterycommander.acwatcher.plist \
com.batterycommander.hygiene.plist \
com.batterycommander.log-cleanup.plist \
com.batterycommander.morning-report.plist \
com.batterycommander.pmsetcheck.plist \
com.batterycommander.powerwatch.plist \
com.batterycommander.predictive.plist \
com.batterycommander.process-monitor.plist \
com.batterycommander.self-healing.plist \
com.batterycommander.selfmaintenance.plist \
com.batterycommander.sleepmanager.plist \
com.batterycommander.sleepmonitor.plist \
com.batterycommander.wakeanalyzer.plist \
com.batterycommander.watchdog.plist \
com.batterycommander.watchdogsentinel.plist"

md5_of() { md5 -q "$1"; }
check_md5() {
    actual=$(md5_of "$1")
    if [ "$actual" != "$2" ]; then
        echo "BUILD ABORT: md5 mismatch for $1" >&2
        echo "  got      $actual" >&2
        echo "  expected $2" >&2
        exit 1
    fi
    echo "md5 ok: $1"
}

echo "== Verifying the end-state to package =="
check_md5 "$APP_SRC/Contents/MacOS/BatteryCommander" "$EXPECT_APP_EXE"
check_md5 "$DAEMON_BIN_SRC" "$EXPECT_DAEMON_BIN"
check_md5 "$DAEMON_SRC" "$EXPECT_DAEMON_SRC"
check_md5 "$STATE_DIR/display_state.sh" "$EXPECT_DISPLAY_STATE"
check_md5 "$STATE_DIR/dispatch.sh" "$EXPECT_DISPATCH"
check_md5 "$STATE_DIR/bc-watchdog.sh" "$EXPECT_WATCHDOG"

echo "== Staging =="
STAGE=$(mktemp -d /tmp/bc-dmg-stage.XXXXXX)
IMG_ROOT="$STAGE/root"
mkdir -p "$IMG_ROOT"
echo "stage: $STAGE"

ditto "$APP_SRC" "$IMG_ROOT/BatteryCommander.app"
APP="$IMG_ROOT/BatteryCommander.app"
PAYLOAD="$APP/Contents/Resources/payload"
mkdir -p "$PAYLOAD/daemon" "$PAYLOAD/helpers/icons" "$PAYLOAD/agents" \
         "$PAYLOAD/sudoers" "$PAYLOAD/defaults"

echo "== Payload: daemon =="
cp -p "$DAEMON_BIN_SRC" "$PAYLOAD/daemon/bc-limit"
# Publish plist from the canonical template: strip the dev-era comment
# block, point the program + working directory at the publish home.
# @HOME@ stays in place for the config/log paths (setup substitutes).
sed -e '/<!--/,/-->/d' \
    -e 's|@HOME@/Projects/BattOpt-CC-Release/battopt-project/bc-build/bc-limit|/Library/PrivilegedHelperTools/bc-limit|g' \
    -e 's|@HOME@/Projects/BattOpt-CC-Release/battopt-project/bc-build|/Library/PrivilegedHelperTools|g' \
    "$PLIST_TEMPLATE" > "$PAYLOAD/daemon/com.batterycommander.bclimit.plist"
plutil -lint "$PAYLOAD/daemon/com.batterycommander.bclimit.plist"

echo "== Payload: helpers (deployed set) =="
for f in $HELPERS; do
    cp -p "$STATE_DIR/$f" "$PAYLOAD/helpers/$f"
done
cp -p "$STATE_DIR/icons/battery-commander.png" "$PAYLOAD/helpers/icons/battery-commander.png"

echo "== Payload: agents, sudoers, defaults, engines =="
for f in $AGENTS; do
    # Normalize the one template that still carries the build user's
    # literal home (watchdogsentinel) to the @HOME@ placeholder form.
    sed 's|/Users/Yousef|@HOME@|g' "$REPO/src/agents/$f" > "$PAYLOAD/agents/$f"
    plutil -lint "$PAYLOAD/agents/$f" >/dev/null
done
sed 's|^Yousef |@USER@ |' "$REPO/src/sudoers/battery-commander" > "$PAYLOAD/sudoers/battery-commander"
printf 'LAST_UPPER=86\nLAST_LOWER=85\nSAILING=false\nSAIL_GAP=1\n' > "$PAYLOAD/defaults/config"
cp -p "$PKG_DIR/setup.sh" "$PAYLOAD/setup.sh"
cp -p "$PKG_DIR/uninstall.sh" "$PAYLOAD/uninstall.sh"
chmod +x "$PAYLOAD/setup.sh" "$PAYLOAD/uninstall.sh" "$PAYLOAD/daemon/bc-limit"

echo "== DMG root =="
cp -p "$PKG_DIR/README.md" "$IMG_ROOT/README.md"
cp -p "$PKG_DIR/install-wrapper.sh" "$IMG_ROOT/Install Battery Commander.command"
cp -p "$PKG_DIR/uninstall.sh" "$IMG_ROOT/Uninstall Battery Commander.command"
chmod +x "$IMG_ROOT/Install Battery Commander.command" "$IMG_ROOT/Uninstall Battery Commander.command"
ln -s /Applications "$IMG_ROOT/Applications"

echo "== Re-sealing the app (ad-hoc, v1 unsigned) =="
xattr -cr "$APP"
codesign --force --sign - "$PAYLOAD/daemon/bc-limit"
codesign --force --sign - "$PAYLOAD/helpers/powerwatch"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "codesign verify: OK"

echo "== Building DMG =="
mkdir -p "$OUT_DIR"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$IMG_ROOT" -ov -format UDZO "$DMG"
echo "DMG: $DMG"
md5 "$DMG"
du -h "$DMG" | cut -f1 | sed 's/^/size: /'
rm -rf "$STAGE"
echo "BUILD OK"
