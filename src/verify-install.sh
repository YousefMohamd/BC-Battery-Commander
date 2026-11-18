#!/bin/bash
# verify-install.sh - read-only verification of a complete Battery Commander
# install (BC v2.0.0). Replaces the battopt verifier (W2.4).
#
# BC checks (no sudo, no battopt):
#   - bc-status / bc-limit / bc-candidates binaries exist and are executable
#   - BC LaunchDaemon plist exists and lints (loading is Phase C — the
#     loaded state is reported as INFO, not a failure)
#   - all 14 user LaunchAgents installed and loaded (chargingguard is gone;
#     selfmaintenance is present — W0-extension §3.3)
#   - all .sh scripts in the state dir executable
#   - BatteryCommander app executable present (Stage C; plugin retired)
#   - powerwatch binary executable
#   - config parses with LAST_UPPER/LAST_LOWER
#   - .active_mode holds a known value
#   - bc-status returns output (replaces the dead `battopt status` check)
#   - no dispatch.sh shutdown process running
# The sudoers content check is dropped: the BC sudoers (pmset-only) is a
# W5.1 item and the file is not readable without sudo. A pmset entry is
# reported as INFO when the file happens to be readable.
# The Battery Commander.app bundle check is INFO until it is installed in
# /Applications (built in the repo since W5.1 + icon task).
# BC state dir: ~/.battery-commander/ is the ONLY live state dir
# (consolidation 2026-11-13, M2: the old-dir fallback is retired — the
# pre-migration dir is a kept, inert backup and must never be read or
# written as a live target). BC_DASH overrides (tests / dry-runs).
if [ -n "${BC_DASH:-}" ]; then
    DASH="$BC_DASH"
elif [ -d "$HOME/.battery-commander" ]; then
    DASH="$HOME/.battery-commander"
else
    echo "ERROR: Battery Commander state dir missing - ~/.battery-commander not found; refusing to run (old-dir fallback retired)" >&2
    exit 1
fi
LA_DIR="$HOME/Library/LaunchAgents"
BC_BUILD_DIR="${BC_BUILD_DIR:-$HOME/Projects/BattOpt-CC-Release/battopt-project/bc-build}"
BC_DAEMON_PLIST="$BC_BUILD_DIR/com.batterycommander.bclimit.plist"
APP="/Applications/BatteryCommander.app"

PASS_N=0
FAIL_N=0

pass() { PASS_N=$((PASS_N + 1)); printf '[PASS] %s\n' "$1"; }
fail() { FAIL_N=$((FAIL_N + 1)); printf '[FAIL] %s: %s\n' "$1" "$2"; }
info() { printf '[INFO] %s: %s\n' "$1" "$2"; }

missing=""
for b in bc-status bc-limit bc-candidates; do
    [ -x "$BC_BUILD_DIR/$b" ] || missing="$missing $b"
done
missing="${missing# }"
if [ -z "$missing" ]; then
    pass "BC binaries executable in bc-build (bc-status, bc-limit, bc-candidates)"
else
    fail "BC binaries in bc-build" "missing or not executable: $missing"
fi

if [ ! -f "$BC_DAEMON_PLIST" ]; then
    fail "BC LaunchDaemon plist" "$BC_DAEMON_PLIST missing"
elif ! plutil -lint "$BC_DAEMON_PLIST" >/dev/null 2>&1; then
    fail "BC LaunchDaemon plist" "$BC_DAEMON_PLIST fails plutil -lint"
else
    pass "BC LaunchDaemon plist exists and lints (com.batterycommander.bclimit)"
fi
# The enforcer is a SYSTEM daemon — `launchctl list` (user domain)
# can never see it, so the daemon log mtime is the proxy (W6.4).
if [ -f "$DASH/bc-limit-daemon.log" ]; then
    _AGE=$(( $(date +%s) - $(stat -f %m "$DASH/bc-limit-daemon.log" 2>/dev/null || echo 0) ))
    if [ "$_AGE" -lt 180 ]; then
        info "BC LaunchDaemon" "running (daemon log ${_AGE}s old, Phase C enforcement active)"
    else
        info "BC LaunchDaemon" "log stale (${_AGE}s) — daemon may not be loaded (expected until Phase C approval)"
    fi
else
    info "BC LaunchDaemon" "not loaded (expected until Phase C approval)"
fi

missing=""
notloaded=""
for a in com.batterycommander.acwatcher com.batterycommander.hygiene \
         com.batterycommander.log-cleanup com.batterycommander.morning-report \
         com.batterycommander.pmsetcheck com.batterycommander.predictive \
         com.batterycommander.process-monitor com.batterycommander.self-healing \
         com.batterycommander.selfmaintenance \
         com.batterycommander.sleepmanager com.batterycommander.sleepmonitor \
         com.batterycommander.wakeanalyzer \
         com.batterycommander.watchdog com.batterycommander.powerwatch
do
    if [ ! -f "$LA_DIR/$a.plist" ]; then
        missing="$missing $a"
    elif ! launchctl print "gui/$(id -u)/$a" >/dev/null 2>&1; then
        notloaded="$notloaded $a"
    fi
done
missing="${missing# }"
notloaded="${notloaded# }"
reason=""
[ -n "$missing" ] && reason="no plist: $missing"
[ -n "$notloaded" ] && reason="${reason:+$reason; }not loaded: $notloaded"
if [ -z "$reason" ]; then
    pass "all 14 user LaunchAgents installed and loaded"
else
    fail "user LaunchAgents" "$reason"
fi

nonexec=""
for f in "$DASH"/*.sh; do
    [ -f "$f" ] || continue
    [ -x "$f" ] || nonexec="$nonexec $(basename "$f")"
done
nonexec="${nonexec# }"
if [ -z "$nonexec" ]; then
    pass "all .sh scripts in $DASH executable"
else
    fail "$DASH scripts" "not executable: $nonexec"
fi

SUDOERS="/etc/sudoers.d/battery-commander"
if [ -r "$SUDOERS" ]; then
    if grep -q 'pmset' "$SUDOERS" 2>/dev/null; then
        pass "sudoers $SUDOERS contains a pmset entry"
    else
        fail "sudoers $SUDOERS" "no pmset entry (BC needs pmset-only sudoers, W5.1)"
    fi
else
    info "sudoers $SUDOERS" "not readable without sudo (BC sudoers is pmset-only, W5.1)"
fi

# Stage C: the SwiftBar plugin is retired; the native app is the UI.
APP_EXE="/Applications/BatteryCommander.app/Contents/MacOS/BatteryCommander"
if [ -x "$APP_EXE" ]; then
    pass "BatteryCommander app executable present"
else
    fail "BatteryCommander app" "$APP_EXE missing or not executable"
fi

APPLET="$APP/Contents/MacOS/applet"
LAUNCHER="$APP/Contents/Resources/BatteryCommander-launcher.sh"
NATIVE_EXE="$APP/Contents/MacOS/BatteryCommander"
if [ ! -d "$APP" ]; then
    info "Battery Commander.app bundle" "not installed in /Applications (built in repo)"
elif [ -f "$NATIVE_EXE" ]; then
    # Native Swift app (Stage B, 2026-11-14): the launcher applet was
    # replaced by the native menu-bar app under the same bundle id.
    # The old applet-only check false-FAILed the correct Stage B
    # install (hardening 2026-11-14: FAIL must mean failure).
    areason=""
    file -b "$NATIVE_EXE" 2>/dev/null | grep -q 'Mach-O' || areason="native executable is not a Mach-O binary"
    _bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)
    [ "$_bid" = "com.batterycommander.launcher" ] || areason="${areason:+$areason; }bundle id is '$_bid'"
    if [ -z "$areason" ]; then
        pass "Battery Commander.app bundle (native Mach-O, com.batterycommander.launcher)"
    else
        fail "Battery Commander.app bundle" "$areason"
    fi
else
    areason=""
    if [ ! -f "$APPLET" ]; then
        areason="applet missing"
    elif ! file -b "$APPLET" 2>/dev/null | grep -q 'Mach-O'; then
        areason="applet is not a Mach-O binary"
    fi
    [ -f "$LAUNCHER" ] || areason="${areason:+$areason; }launcher missing"
    if [ -z "$areason" ]; then
        pass "Battery Commander.app bundle (applet Mach-O + launcher)"
    else
        fail "Battery Commander.app bundle" "$areason"
    fi
fi

if [ -x "$DASH/powerwatch" ]; then
    pass "powerwatch binary executable"
else
    fail "powerwatch binary" "$DASH/powerwatch missing or not executable"
fi

CFG="$DASH/config"
if [ ! -f "$CFG" ]; then
    fail "config" "$CFG missing"
else
    creason=""
    bad="$(awk 'NF && $0 !~ /^[ \t]*#/ && $0 !~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/ {c++} END{print c+0}' "$CFG")"
    [ "$bad" = "0" ] || creason="$bad unparsable line(s)"
    grep -q 'LAST_UPPER=' "$CFG" || creason="${creason:+$creason; }LAST_UPPER missing"
    grep -q 'LAST_LOWER=' "$CFG" || creason="${creason:+$creason; }LAST_LOWER missing"
    if [ -z "$creason" ]; then
        pass "config parses with LAST_UPPER/LAST_LOWER"
    else
        fail "config" "$creason"
    fi
fi

MODE_FILE="$DASH/.active_mode"
if [ ! -f "$MODE_FILE" ]; then
    pass ".active_mode absent (idle)"
else
    mode="$(tr -d '[:space:]' < "$MODE_FILE")"
    case "$mode" in
        ""|idle|hold|charge_full|discharge|calibration)
            pass ".active_mode = ${mode:-idle}"
            ;;
        *)
            fail ".active_mode" "unexpected value: $mode"
            ;;
    esac
fi

status_out=""
if [ -x "$BC_BUILD_DIR/bc-status" ]; then
    status_out="$("$BC_BUILD_DIR/bc-status" 2>/dev/null)"
fi
if [ -n "$status_out" ] && printf '%s\n' "$status_out" | grep -q '^Capacity:'; then
    pass "bc-status returns output (Capacity line present)"
else
    fail "bc-status" "empty output or no Capacity line"
fi

if pgrep -f "dispatch.sh shutdown" >/dev/null 2>&1; then
    fail "shutdown dispatch" "dispatch.sh shutdown process still running"
else
    pass "no dispatch.sh shutdown process running"
fi

INSTALLED_DAEMON_PLIST="/Library/LaunchDaemons/com.batterycommander.bclimit.plist"
if [ ! -f "$INSTALLED_DAEMON_PLIST" ]; then
    info "installed BC LaunchDaemon plist" "not installed in /Library/LaunchDaemons yet (install step, before Phase C)"
elif ! plutil -lint "$INSTALLED_DAEMON_PLIST" >/dev/null 2>&1; then
    fail "installed BC LaunchDaemon plist" "$INSTALLED_DAEMON_PLIST fails plutil -lint"
elif grep -q '@HOME@' "$INSTALLED_DAEMON_PLIST" 2>/dev/null; then
    fail "installed BC LaunchDaemon plist" "still contains unsubstituted @HOME@ (install substitution was not run)"
else
    _bin=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$INSTALLED_DAEMON_PLIST" 2>/dev/null || echo "")
    _owner=$(stat -f '%Su:%Sg:%Lp' "$INSTALLED_DAEMON_PLIST" 2>/dev/null || echo "?")
    if [ -z "$_bin" ] || [ ! -x "$_bin" ]; then
        fail "installed BC LaunchDaemon plist" "binary ${_bin:-missing} is not executable"
    elif [ "$_owner" != "root:wheel:644" ]; then
        fail "installed BC LaunchDaemon plist" "owner/mode $_owner, expected root:wheel:644"
    else
        pass "installed BC LaunchDaemon plist (binary $_bin executable, root:wheel 644)"
    fi
fi

if pgrep -f '/Library/Application Support/battopt/battopt daemon' >/dev/null 2>&1; then
    info "old battopt daemon" "still running (enforces the limit until Phase C loads the BC daemon)"
fi

TOTAL=$((PASS_N + FAIL_N))
if [ "$FAIL_N" -eq 0 ]; then
    echo "ALL CHECKS PASSED ($PASS_N/$TOTAL)"
    exit 0
else
    echo "FAIL: $FAIL_N failed (out of $TOTAL)"
    exit 1
fi

