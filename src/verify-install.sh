#!/bin/bash
# verify-install.sh - read-only verification of a complete BattOpt install.
DASH="$HOME/.battopt-swiftbar"
LA_DIR="$HOME/Library/LaunchAgents"
APP="/Applications/BattOpt.app"
SUDOERS="/etc/sudoers.d/battopt"

PASS_N=0
FAIL_N=0

pass() { PASS_N=$((PASS_N + 1)); printf '[PASS] %s\n' "$1"; }
fail() { FAIL_N=$((FAIL_N + 1)); printf '[FAIL] %s: %s\n' "$1" "$2"; }

sudo -v

if [ -x /usr/local/bin/battopt ]; then
    pass "/usr/local/bin/battopt executable"
else
    fail "/usr/local/bin/battopt" "missing or not executable"
fi

missing=""
for h in battopt-daemon-start battopt-daemon-stop battopt-daemon-restart \
         battopt-trial-renew battopt-release-cfg battopt-restore-cfg \
         battopt-powerwatch-start battopt-powerwatch-stop
do
    [ -x "/usr/local/bin/$h" ] || missing="$missing $h"
done
missing="${missing# }"
if [ -z "$missing" ]; then
    pass "all 8 root helpers executable in /usr/local/bin"
else
    fail "root helpers in /usr/local/bin" "missing or not executable: $missing"
fi

notloaded=""
for d in com.buddha-path.BattOpt.daemon com.battopt.powerwatch; do
    sudo launchctl print "system/$d" >/dev/null 2>&1 || notloaded="$notloaded $d"
done
notloaded="${notloaded# }"
if [ -z "$notloaded" ]; then
    pass "root LaunchDaemons loaded (daemon, powerwatch)"
else
    fail "root LaunchDaemons" "not loaded: $notloaded"
fi

missing=""
notloaded=""
for a in com.battopt.acwatcher com.battopt.adaptive-governor \
         com.battopt.chargingguard com.battopt.consolidated \
         com.battopt.enforce com.battopt.guardian com.battopt.hygiene \
         com.battopt.log-cleanup com.battopt.morning-report \
         com.battopt.pmsetcheck com.battopt.predictive \
         com.battopt.process-monitor com.battopt.self-healing \
         com.battopt.sleepmanager com.battopt.sleepmonitor \
         com.battopt.swiftbar-watchdog com.battopt.wakeanalyzer
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
    pass "all 17 user LaunchAgents installed and loaded"
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
    pass "all .sh scripts in ~/.battopt-swiftbar executable"
else
    fail "~/.battopt-swiftbar scripts" "not executable: $nonexec"
fi

if [ ! -f "$SUDOERS" ]; then
    fail "sudoers file" "$SUDOERS missing"
else
    scontent="$(sudo -n cat "$SUDOERS" 2>/dev/null)"
    sreason=""
    printf '%s\n' "$scontent" | grep -q 'battopt-daemon-restart' \
        || sreason="missing battopt-daemon-restart"
    printf '%s\n' "$scontent" | grep -q '\.sys_info' \
        || sreason="${sreason:+$sreason; }missing .sys_info"
     grep -o 'pmset' | grep -o 'pmset' | wc -l | tr -d ' ')"
    [ "$pmset_n" = "1" ] \
        || sreason="${sreason:+$sreason; }pmset appears $pmset_n times (want 1)"
    if [ -z "$sreason" ]; then
        pass "sudoers $SUDOERS contents"
    else
        fail "sudoers $SUDOERS" "$sreason"
    fi
fi

PLUGIN="$HOME/SwiftBar/battopt.10s.sh"
if [ -x "$PLUGIN" ]; then
    pass "SwiftBar plugin battopt.10s.sh executable"
else
    fail "SwiftBar plugin" "$PLUGIN missing or not executable"
fi

APPLET="$APP/Contents/MacOS/applet"
LAUNCHER="$APP/Contents/Resources/BattOpt-launcher.sh"
areason=""
if [ ! -f "$APPLET" ]; then
    areason="applet missing"
elif ! file -b "$APPLET" 2>/dev/null | grep -q 'Mach-O'; then
    areason="applet is not a Mach-O binary"
fi
[ -f "$LAUNCHER" ] || areason="${areason:+$areason; }BattOpt-launcher.sh missing"
if [ -z "$areason" ]; then
    pass "BattOpt.app bundle (applet Mach-O + launcher)"
else
    fail "BattOpt.app bundle" "$areason"
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

status_out="$(sudo -n /usr/local/bin/battopt status 2>/dev/null)"
if [ -n "$status_out" ]; then
    pass "battopt status returns output"
else
    fail "battopt status" "empty output or command failed"
fi

if pgrep -f "dispatch.sh shutdown" >/dev/null 2>&1; then
    fail "shutdown dispatch" "dispatch.sh shutdown process still running"
else
    pass "no dispatch.sh shutdown process running"
fi

TOTAL=$((PASS_N + FAIL_N))
if [ "$FAIL_N" -eq 0 ]; then
    echo "ALL CHECKS PASSED ($PASS_N/$TOTAL)"
    exit 0
else
    echo "FAIL: $FAIL_N failed (out of $TOTAL)"
    exit 1
fi
