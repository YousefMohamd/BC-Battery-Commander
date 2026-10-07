#!/bin/bash
# <xbar.title>BattOpt Control Center</xbar.title>
# <xbar.version>13.0</xbar.version>
# <xbar.author>Yousef</xbar.author>
# <xbar.desc>Sailing mode, smart discharge, calibration, clamshell, schedule, proactive notifications.</xbar.desc>
# <xbar.abouturl>https://battopt.buddha-path.top</xbar.abouturl>
# <xbar.dependencies>bash,battopt</xbar.dependencies>

# Exit silently if disabled
if [ -f "$HOME/.battopt-swiftbar/.disabled" ]; then
    exit 0
fi

BAT="/usr/local/bin/battopt"
DISPATCH="$HOME/.battopt-swiftbar/dispatch.sh"
CFG="/Library/Application Support/battopt/battopt_cfg"
MYCFG="$HOME/.battopt-swiftbar/config"
NOTIFY_DIR="$HOME/.battopt-swiftbar/.notify"
FAIL_FILE="$HOME/.battopt-swiftbar/.daemon_fail_count"
TERMINAL_NOTIFIER="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
BATTOPT_ICON="$HOME/.battopt-swiftbar/icons/battopt.png"

mkdir -p "$NOTIFY_DIR"

LAST_UPPER=80; LAST_LOWER=75; SAILING=true; SAIL_GAP=10
[ -f "$MYCFG" ] && source "$MYCFG"

SNAP=$(sudo -n "$BAT" status 2>/dev/null)

# ============ PROACTIVE NOTIFICATIONS ============
notify_proactive() {
    local key="$1" cooldown="$2" title="$3" msg="$4"
    local f="$NOTIFY_DIR/$key"
    local now=$(date +%s)
    local last=0
    [ -f "$f" ] && last=$(cat "$f" 2>/dev/null)
    [ -z "$last" ] && last=0
    if [ $((now - last)) -ge "$cooldown" ]; then
        if [ -x "$TERMINAL_NOTIFIER" ] && [ -f "$BATTOPT_ICON" ]; then
            "$TERMINAL_NOTIFIER" -title "$title" -message "$msg" \
                -appIcon "$BATTOPT_ICON" -contentImage "$BATTOPT_ICON" \
                -sound "Ping" -group "battopt-notify" >/dev/null 2>&1 &
        else
            osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1 &
        fi
        echo "$now" > "$f"
        return 0
    fi
    return 1
}

# ============ AUTO RECOVERY ============
if [ -z "$SNAP" ] || echo "$SNAP" | grep -q "Timeout\|not running"; then
    FAILS=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
    FAILS=$((FAILS + 1))
    echo "$FAILS" > "$FAIL_FILE"
    if [ "$FAILS" -ge 3 ]; then
        notify_proactive "daemon_recovery" 600 "BattOpt Recovery" "Daemon unresponsive — auto-restarting"
        "$HOME/.battopt-swiftbar/force_reset.sh" >/dev/null 2>&1 &
        echo "0" > "$FAIL_FILE"
    fi
else
    echo "0" > "$FAIL_FILE"
fi

# ============ PARSE STATE ============
PCT=$(echo "$SNAP" | grep -oE "Capacity [0-9]+" | grep -oE "[0-9]+")
UPPER=$(echo "$SNAP" | grep -oE "upper limit [0-9]+" | grep -oE "[0-9]+")
LOWER=$(echo "$SNAP" | grep -oE "lower limit [0-9]+" | grep -oE "[0-9]+")
HEALTH=$(echo "$SNAP" | grep -oE "Health [0-9.]+" | grep -oE "[0-9.]+")
CYCLES=$(echo "$SNAP" | grep -oE "Cycle [0-9]+" | grep -oE "[0-9]+")
TEMP=$(echo "$SNAP" | grep -oE "[0-9.]+.C" | grep -oE "[0-9.]+" | head -1)
TRIAL=$(echo "$SNAP" | grep -oE "expire in [0-9]+ days" | grep -oE "[0-9]+")

TEMP_INT=${TEMP%.*}
HEALTH_INT=${HEALTH%.*}
TEMP_COLOR="color=green"
[ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 40 ] && TEMP_COLOR="color=orange"
[ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 45 ] && TEMP_COLOR="color=red"

GRAY="color=#909090"
ORANGE="color=#FF9500"

# ============ PROACTIVE CHECKS ============
if [ -n "$TEMP_INT" ]; then
    if [ "$TEMP_INT" -ge 45 ]; then
        notify_proactive "temp_critical" 300 "Battery Critical Temperature" "${TEMP}C - reduce load immediately"
    elif [ "$TEMP_INT" -ge 42 ]; then
        notify_proactive "temp_high" 900 "Battery Hot" "${TEMP}C - consider cooling"
    fi
fi

if echo "$SNAP" | grep -q ", discharging" && [ -n "$PCT" ] && [ "$PCT" -le 20 ]; then
    notify_proactive "low_batt" 1800 "Battery Low" "${PCT}% - plug in charger"
fi

if echo "$SNAP" | grep -q ", charging" && [ -n "$PCT" ] && [ "$PCT" -ge 99 ] && [ -z "$UPPER" ]; then
    notify_proactive "full_charge" 3600 "Charging Complete" "Battery at ${PCT}%"
fi

if [ -n "$HEALTH_INT" ] && [ "$HEALTH_INT" -le 75 ]; then
    notify_proactive "health_low" 604800 "Battery Health Low" "Health at ${HEALTH}% - service recommended"
fi

# Smart Discharge completion detection
SD_STATE="$HOME/.battopt-swiftbar/.sd_watch"
if [ -f "$SD_STATE" ]; then
    SD_TARGET=$(cat "$SD_STATE" 2>/dev/null)
    if [ -n "$PCT" ] && [ -n "$SD_TARGET" ] && [ "$PCT" -le "$SD_TARGET" ]; then
        notify_proactive "sd_complete" 60 "Smart Discharge" "Reached target ${SD_TARGET}%"
        rm -f "$SD_STATE"
    fi
fi

# ============ PROCESS DETECTION ============
PROC_D=$(pgrep -f "/usr/local/bin/battopt discharge" 2>/dev/null | wc -l | tr -d ' ')
PROC_C=$(pgrep -f "/usr/local/bin/battopt calibrate" 2>/dev/null | wc -l | tr -d ' ')
PROC_CH=$(pgrep -f "battopt charge " 2>/dev/null | wc -l | tr -d ' ')

if [ "$PROC_C" -gt 0 ]; then
    MODE="Calibrating"; ICON="⏳"
elif [ "$PROC_D" -gt 0 ]; then
    MODE="Discharging to ${LAST_UPPER}%"; ICON="🔋"
elif [ "$PROC_CH" -gt 0 ]; then
    MODE="Charging to 100%"; ICON="⚡"
elif echo "$SNAP" | grep -q ", charging"; then
    if [ -n "$UPPER" ] && [ -n "$PCT" ] && [ "$PCT" -lt "$UPPER" ]; then
        MODE="Topping to ${UPPER}%"; ICON="⚡"
    else
        MODE="Charging"; ICON="⚡"
    fi
elif echo "$SNAP" | grep -q ", no charging"; then
    if [ -n "$UPPER" ] && [ -n "$LOWER" ] && [ "$SAILING" = "true" ] && [ "$((UPPER - LOWER))" -ge 2 ]; then
        MODE="Sailing ${LOWER}-${UPPER}%"; ICON="🔌"
    elif [ -n "$UPPER" ]; then
        MODE="Holding at ${UPPER}%"; ICON="🔌"
    else
        MODE="On adapter (no limit)"; ICON="🔌"
    fi
elif echo "$SNAP" | grep -q ", discharging"; then
    if [ "$SAILING" = "true" ] && [ -n "$LOWER" ] && [ -n "$UPPER" ]; then
        MODE="Battery - sailing ${LOWER}-${UPPER}%"; ICON="🔴"
    else
        MODE="On battery"; ICON="🔴"
    fi
else
    MODE="Unknown"; ICON="🔌"
fi

STUCK=""
echo "$SNAP" | grep -qE "Error:.*ongoing" && STUCK="yes"

CLAM=$(sudo cat "$CFG" 2>/dev/null | grep "^clamshell" | grep -oE "[0-9]+" | head -1)
[ -z "$CLAM" ] && CLAM=0
SCHED=$(sudo cat "$CFG" 2>/dev/null | grep "^schedule.enable" | grep -oE "[0-9]+" | head -1)
[ -z "$SCHED" ] && SCHED=0

# ============ MENU ============
echo "${ICON} | size=15"
echo "---"

echo "Charge: ${PCT}% | size=11"
echo "Mode: ${MODE} | size=11"
echo "Health: ${HEALTH}% - ${CYCLES} cycles | size=11 $GRAY"
if [ -n "$UPPER" ] && [ -n "$LOWER" ]; then
    echo "Active Limit: ${UPPER}% / ${LOWER}% | size=11 $GRAY"
else
    echo "Active Limit: disabled | size=11 $GRAY"
fi
[ -n "$TEMP" ] && echo "Temperature: ${TEMP}C | size=11 $TEMP_COLOR"
[ -n "$TRIAL" ] && echo "Trial: ${TRIAL} days | size=11 color=orange"
echo "---"

echo "Quick Actions | size=11 color=#007AFF disabled=true"
echo "Stop Charging Now (hold at ${PCT}%) | bash=$DISPATCH param1=stop_now terminal=false refresh=true"
echo "Charge to 100% & Hold | bash=$DISPATCH param1=charge_full terminal=false refresh=true"

if [ "$PROC_D" -gt 0 ]; then
    echo "★ Smart Discharge - RUNNING | bash=$DISPATCH param1=force_reset terminal=false refresh=true checked=true $ORANGE"
    echo "↳ Kill Discharge (only) | bash=$DISPATCH param1=kill_discharge terminal=false refresh=true $GRAY"
elif [ "$PROC_CH" -gt 0 ]; then
    echo "★ Smart Discharge... | bash=$DISPATCH param1=smart_discharge terminal=false refresh=true $ORANGE"
    echo "↳ Kill Charge (only) | bash=$DISPATCH param1=kill_charge terminal=false refresh=true $GRAY"
else
    echo "★ Smart Discharge... | bash=$DISPATCH param1=smart_discharge terminal=false refresh=true $ORANGE"
fi

if [ -n "$STUCK" ]; then
    echo "Force Reset (STUCK!) | bash=$DISPATCH param1=force_reset terminal=false refresh=true color=red"
else
    echo "Force Reset | bash=$DISPATCH param1=force_reset terminal=false refresh=true $GRAY"
fi
echo "---"

echo "Charge Limits | size=11 color=#007AFF disabled=true"
SMC_MATCHES_SAVED=false
if [ -n "$UPPER" ] && [ -n "$LOWER" ] && [ "$UPPER" = "$LAST_UPPER" ] && [ "$LOWER" = "$LAST_LOWER" ]; then
    SMC_MATCHES_SAVED=true
fi
if [ "$SMC_MATCHES_SAVED" = "true" ]; then
    echo "Custom: ${LAST_UPPER}% / ${LAST_LOWER}% - Edit... | bash=$DISPATCH param1=limit_custom terminal=false refresh=true checked=true"
else
    echo "Custom (saved): ${LAST_UPPER}% / ${LAST_LOWER}% - Edit... | bash=$DISPATCH param1=limit_custom terminal=false refresh=true"
    if [ -n "$UPPER" ] && [ -n "$LOWER" ]; then
        echo "-- Active now: ${UPPER}% / ${LOWER}% | size=11 color=#909090 disabled=true"
    fi
fi

if [ "$SAILING" = "true" ]; then
    echo "Sailing enabled (gap ${SAIL_GAP}%) | color=#007AFF"
    echo "-- Disable Sailing (hold at upper) | bash=$DISPATCH param1=sail_off terminal=false refresh=true"
    echo "-- Gap: 5% | bash=$DISPATCH param1=sail_gap_set param2=5 terminal=false refresh=true checked=$([ "$SAIL_GAP" = "5" ] && echo true || echo false)"
    echo "-- Gap: 10% | bash=$DISPATCH param1=sail_gap_set param2=10 terminal=false refresh=true checked=$([ "$SAIL_GAP" = "10" ] && echo true || echo false)"
    echo "-- Gap: 15% | bash=$DISPATCH param1=sail_gap_set param2=15 terminal=false refresh=true checked=$([ "$SAIL_GAP" = "15" ] && echo true || echo false)"
    echo "-- Gap: 30% | bash=$DISPATCH param1=sail_gap_set param2=30 terminal=false refresh=true checked=$([ "$SAIL_GAP" = "30" ] && echo true || echo false)"
    echo "-- Gap: Custom... | bash=$DISPATCH param1=sail_gap_set param2=custom terminal=false refresh=true"
else
    echo "Sailing disabled (hold at upper) | color=#909090"
    echo "-- Enable Sailing | bash=$DISPATCH param1=sail_on terminal=false refresh=true"
    echo "-- Gap: 5% | bash=$DISPATCH param1=sail_gap_set param2=5 terminal=false refresh=true checked=$([ "$SAIL_GAP" = "5" ] && echo true || echo false)"
    echo "-- Gap: 10% | bash=$DISPATCH param1=sail_gap_set param2=10 terminal=false refresh=true checked=$([ "$SAIL_GAP" = "10" ] && echo true || echo false)"
    echo "-- Gap: 15% | bash=$DISPATCH param1=sail_gap_set param2=15 terminal=false refresh=true checked=$([ "$SAIL_GAP" = "15" ] && echo true || echo false)"
    echo "-- Gap: 30% | bash=$DISPATCH param1=sail_gap_set param2=30 terminal=false refresh=true checked=$([ "$SAIL_GAP" = "30" ] && echo true || echo false)"
    echo "-- Gap: Custom... | bash=$DISPATCH param1=sail_gap_set param2=custom terminal=false refresh=true"
fi

echo "Remove Limit (hold at current) | bash=$DISPATCH param1=remove_limit_hold terminal=false refresh=true"
echo "Disable All Limits (charge to 100%) | bash=$DISPATCH param1=disable_limit terminal=false refresh=true $GRAY"
echo "---"

echo "Battery Care | size=11 color=#007AFF disabled=true"
echo "Start Calibration | bash=$DISPATCH param1=calibrate terminal=false refresh=true"
if [ "$PROC_C" -gt 0 ]; then
    echo "↳ Kill Calibration (only) | bash=$DISPATCH param1=kill_calibrate terminal=false refresh=true $GRAY"
fi
echo "Stop Calibration (API) | bash=$DISPATCH param1=cal_stop terminal=false refresh=true"
echo "---"

echo "Clamshell Mode | size=11 color=#007AFF disabled=true"
echo "-- Standard - lid required | bash=$DISPATCH param1=clam0 terminal=false refresh=true checked=$([ "$CLAM" = "0" ] && echo true || echo false)"
echo "-- Balanced - allow lid closed | bash=$DISPATCH param1=clam1 terminal=false refresh=true checked=$([ "$CLAM" = "1" ] && echo true || echo false)"
echo "-- Ultimate - lid closed + display on | bash=$DISPATCH param1=clam2 terminal=false refresh=true checked=$([ "$CLAM" = "2" ] && echo true || echo false)"
echo "---"

echo "Schedule | size=11 color=#007AFF disabled=true"
echo "-- Enable auto calibration | bash=$DISPATCH param1=sched_on terminal=false refresh=true checked=$([ "$SCHED" = "1" ] && echo true || echo false)"
echo "-- Disable schedule | bash=$DISPATCH param1=sched_off terminal=false refresh=true"
echo "---"

echo "Refresh Now | refresh=true"
echo "Show Full Status... | bash=$DISPATCH param1=details terminal=false"
echo "Sleep & Battery Report | bash=$DISPATCH param1=sleep_report terminal=false"
echo "Save Report (silent) | bash=$DISPATCH param1=sleep_report_save terminal=false"
echo "Open Reports Folder | bash=$DISPATCH param1=open_reports terminal=false"
echo "Open BattOpt Logs | bash=/usr/bin/open param1=/Library/Logs/battopt/ terminal=false"
echo "Open Actions Log | bash=$DISPATCH param1=open_actions_log terminal=false"
echo "Renew Trial Now | bash=/usr/local/bin/battopt-trial-renew terminal=false refresh=true"

LOGIN_STATE=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -c "BattOpt" || true)
if [ "$LOGIN_STATE" -gt 0 ]; then
    echo "✓ Launch at Login | bash=$DISPATCH param1=login_toggle terminal=false refresh=true"
else
    echo "Launch at Login | bash=$DISPATCH param1=login_toggle terminal=false refresh=true"
fi
echo "Open BattOpt.app | bash=$DISPATCH param1=open_app terminal=false"

echo "About BattOpt... | bash=$DISPATCH param1=about terminal=false"
echo "---"

# ============ SLEEP & POWER SECTION ============
PSAVER_STATE=$([ -f "$HOME/.battopt-swiftbar/.power_saver" ] && echo "ON" || echo "OFF")
POWERNAP=$(pmset -g 2>/dev/null | grep -E "^ powernap" | awk '{print $2}' | head -1)
[ -z "$POWERNAP" ] && POWERNAP="0"
WOMP=$(pmset -g 2>/dev/null | grep -E "^ womp" | awk '{print $2}' | head -1)
[ -z "$WOMP" ] && WOMP="0"
TCPKEEP=$(pmset -g 2>/dev/null | grep -E "^ tcpkeepalive" | awk '{print $2}' | head -1)
[ -z "$TCPKEEP" ] && TCPKEEP="0"
HIBERNATE=$(pmset -g 2>/dev/null | grep -E "^ hibernatemode" | awk '{print $2}' | head -1)
[ -z "$HIBERNATE" ] && HIBERNATE="3"
STANDBY_DELAY=$(pmset -g 2>/dev/null | grep -E "^ standbydelayhigh" | awk '{print $2}' | head -1)
[ -z "$STANDBY_DELAY" ] && STANDBY_DELAY=$(pmset -g 2>/dev/null | grep -E "^ standbydelay " | awk '{print $2}' | head -1)
[ -z "$STANDBY_DELAY" ] && STANDBY_DELAY="4200"
STANDBY_MIN=$((STANDBY_DELAY / 60))

USB_EXT=$(system_profiler SPUSBDataType 2>/dev/null | grep -c "Wireless Device" 2>/dev/null | head -1 | tr -d ' \n')
[ -z "$USB_EXT" ] && USB_EXT=0
case "$USB_EXT" in
    ''|*[!0-9]*) USB_EXT=0 ;;
esac

WAKE_COUNT=$(pmset -g log 2>/dev/null | grep -cE "Wake from|DarkWake")
[ -z "$WAKE_COUNT" ] && WAKE_COUNT=0

if [ "$PSAVER_STATE" = "ON" ]; then
    echo "💤 Sleep Report: OPTIMIZED | color=#30D158"
else
    echo "💤 Sleep Report: STANDARD | color=#FF9500"
fi
echo "-- 🔋 Battery: ${PCT}% | size=11"
echo "-- 💚 Health: ${HEALTH}% · ${CYCLES} cycles | size=11 $GRAY"
echo "-- 🌡️ Temperature: ${TEMP}C | size=11 $TEMP_COLOR"
echo "-- ⚡ State: ${STATE} | size=11"
echo "-- ---"
if [ "$PSAVER_STATE" = "ON" ]; then
    echo "-- ✅ Power Saver: ENABLED | size=11 color=#30D158"
else
    echo "-- ⚠️ Power Saver: DISABLED | size=11 color=#FF9500"
fi
if [ "$POWERNAP" = "0" ]; then
    echo "-- ✅ Power Nap: OFF | size=11 color=#30D158"
else
    echo "-- ⚠️ Power Nap: ON | size=11 color=#FF9500"
fi
if [ "$WOMP" = "0" ]; then
    echo "-- ✅ Wake on Network: OFF | size=11 color=#30D158"
else
    echo "-- ⚠️ Wake on Network: ON | size=11 color=#FF9500"
fi
if [ "$TCPKEEP" = "0" ]; then
    echo "-- ✅ TCP Keep-Alive: OFF | size=11 color=#30D158"
else
    echo "-- ⚠️ TCP Keep-Alive: ON | size=11 color=#FF9500"
fi
if [ "$STANDBY_MIN" -le 30 ]; then
    echo "-- ✅ Hibernate after: ${STANDBY_MIN} min | size=11 color=#30D158"
else
    echo "-- ⚠️ Hibernate after: ${STANDBY_MIN} min | size=11 color=#FF9500"
fi
echo "-- ℹ️ Hibernatemode: ${HIBERNATE} | size=11 $GRAY"
echo "-- ---"
echo "-- 📊 Wake events: ${WAKE_COUNT} | size=11 $GRAY"
echo "-- 🔌 External USB: ${USB_EXT} | size=11 $GRAY"
echo "-- ---"
ISSUE_LIST=""
[ "$PSAVER_STATE" = "OFF" ] && ISSUE_LIST="${ISSUE_LIST}PS off; "
[ "$POWERNAP" != "0" ] && ISSUE_LIST="${ISSUE_LIST}PN on; "
[ "$WOMP" != "0" ] && ISSUE_LIST="${ISSUE_LIST}WoMP on; "
[ "$STANDBY_MIN" -gt 30 ] && ISSUE_LIST="${ISSUE_LIST}Slow hib; "
if [ -z "$ISSUE_LIST" ]; then
    echo "-- ✅ All systems optimized | size=11 color=#30D158"
else
    echo "-- ⚠️ Issues: ${ISSUE_LIST} | size=11 color=#FF9500"
fi
echo "-- ---"
if [ "$PSAVER_STATE" = "ON" ]; then
    echo "-- 🔄 Disable Power Saver | bash=$DISPATCH param1=power_saver_off terminal=false refresh=true"
else
    echo "-- ⚡ ENABLE Power Saver | bash=$DISPATCH param1=power_saver_on terminal=false refresh=true color=#30D158"
fi
echo "-- 📄 Show Full Report… | bash=$DISPATCH param1=power_saver_report terminal=false"
echo "-- 💾 Save Report to File | bash=$DISPATCH param1=sleep_report_save terminal=false refresh=true"
echo "-- 📂 Open Reports Folder | bash=$DISPATCH param1=open_reports terminal=false"

# ============ SYSTEM RESOURCES ============
echo "System Resources | size=11 color=#007AFF disabled=true"
SWIFTBAR_PID=$(pgrep -x SwiftBar | head -1)
if [ -n "$SWIFTBAR_PID" ]; then
    SWIFTBAR_CPU=$(ps -p "$SWIFTBAR_PID" -o %cpu= | tr -d ' ')
    SWIFTBAR_RAM=$(ps -p "$SWIFTBAR_PID" -o rss= | awk '{printf "%.1f", $1/1024}')
    echo "SwiftBar: ${SWIFTBAR_CPU}% CPU - ${SWIFTBAR_RAM}MB RAM | size=11 color=#909090"
fi
DAEMON_PID=$(pgrep -f "battopt daemon" | head -1)
if [ -n "$DAEMON_PID" ]; then
    DAEMON_CPU=$(ps -p "$DAEMON_PID" -o %cpu= | tr -d ' ')
    DAEMON_RAM=$(ps -p "$DAEMON_PID" -o rss= | awk '{printf "%.1f", $1/1024}')
    echo "battopt daemon: ${DAEMON_CPU}% CPU - ${DAEMON_RAM}MB RAM | size=11 color=#909090"
else
    echo "battopt daemon: NOT RUNNING | size=11 color=red"
fi
echo "---"
echo "Shut Down BattOpt... | bash=$DISPATCH param1=shutdown terminal=false refresh=true color=red"
