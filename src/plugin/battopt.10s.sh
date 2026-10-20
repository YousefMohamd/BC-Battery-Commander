#!/bin/bash
# <xbar.title>BattOpt Control Center</xbar.title>
# <xbar.version>1.7.0</xbar.version>
# <xbar.author>Yousef</xbar.author>
# <xbar.desc>Sailing, smart discharge, calibration, clamshell.</xbar.desc>
# <xbar.dependencies>bash,battopt</xbar.dependencies>

DASH="$HOME/.battopt-swiftbar"
source "$DASH/state_guard.sh" 2>/dev/null
ACTIVE_MODE=$(read_effective_session 2>/dev/null)
[ -z "$ACTIVE_MODE" ] && ACTIVE_MODE="idle"

BAT="/usr/local/bin/battopt"
DISPATCH="$DASH/dispatch.sh"
CFG="/Library/Application Support/battopt/battopt_cfg"
MYCFG="$DASH/config"
NOTIFY_DIR="$DASH/.notify"
FAIL_FILE="$DASH/.daemon_fail_count"
BATTOPT_ICON="$DASH/icons/battopt.png"

mkdir -p "$NOTIFY_DIR"

_refresh_plugin() {
    /usr/bin/open -g "swiftbar://refreshplugin?name=battopt.10s" >/dev/null 2>&1 || true
}
trap '_refresh_plugin' EXIT

LAST_UPPER=80; LAST_LOWER=75; SAILING=true; SAIL_GAP=10
[ -f "$MYCFG" ] && source "$MYCFG"

NOW_TS=$(date +%s)
STATUS_CACHE="$HOME/.battopt-swiftbar/.status_cache"
CACHE_TTL=10
if [ -f "$STATUS_CACHE" ]; then
    CACHE_AGE=$(($NOW_TS - $(stat -f %m "$STATUS_CACHE" 2>/dev/null || echo 0)))
else
    CACHE_AGE=9999
fi
if [ "$CACHE_AGE" -lt "$CACHE_TTL" ]; then
    SNAP=$(cat "$STATUS_CACHE")
else
    SNAP=$(sudo -n "$BAT" status 2>/dev/null)
    [ -n "$SNAP" ] && echo "$SNAP" > "$STATUS_CACHE"
fi

notify_proactive_v2() {
    local key="$1" cooldown="$2" title="$3" msg="$4"
    local NOTIFY_DIR="$HOME/.battopt-swiftbar/.notify"
    mkdir -p "$NOTIFY_DIR"
    local now=$(date +%s) today=$(date +%Y%m%d) hour=$(date +%H)
    local daily_file="$NOTIFY_DIR/.daily_$today"
    local type_file="$NOTIFY_DIR/$key"
    local is_critical=0
    case "$key" in
        battery_critical|temp_critical|enforce_critical|daemon_recovery|hold_reached|hold_reached_*) is_critical=1 ;;
    esac
    [ "$is_critical" = "0" ] && { [ "$hour" -ge 23 ] || [ "$hour" -lt 8 ]; } && return 0
    if [ -f "$daily_file" ]; then
        local count=$(wc -l < "$daily_file" | tr -d ' ')
        [ "$count" -ge 3 ] && return 0
    fi
    if [ -f "$type_file" ]; then
        local last=$(cat "$type_file" 2>/dev/null || echo 0)
        local diff=$((now - last))
        [ "$diff" -lt 1800 ] && return 0
        [ "$diff" -lt "$cooldown" ] && return 0
    fi
    echo "$now" > "$type_file"
    echo "$key" >> "$daily_file"
    local NOTIFIER="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
    if [ -x "$NOTIFIER" ]; then
        "$NOTIFIER" -title "BattOpt" -subtitle "$title" -message "$msg" -appIcon "$BATTOPT_ICON" -group "battopt-$key" -sound default 2>/dev/null
    else
        osascript -e "display notification \"$msg\" with title \"$title\"" 2>/dev/null
    fi
}

if [ -z "$SNAP" ] || echo "$SNAP" | grep -q "Timeout\|not running"; then
    FAILS=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
    FAILS=$((FAILS + 1))
    echo "$FAILS" > "$FAIL_FILE"
    if [ "$FAILS" -ge 3 ]; then
        notify_proactive_v2 "daemon_recovery" 600 "Recovery" "Daemon unresponsive"
        echo "0" > "$FAIL_FILE"
    fi
else
    echo "0" > "$FAIL_FILE"
fi

PCT=$(echo "$SNAP" | grep -oE "Capacity [0-9]+" | grep -oE "[0-9]+")
UPPER=$(echo "$SNAP" | grep -oE "upper limit [0-9]+" | grep -oE "[0-9]+")
LOWER=$(echo "$SNAP" | grep -oE "lower limit [0-9]+" | grep -oE "[0-9]+")
HEALTH=$(echo "$SNAP" | grep -oE "Health [0-9.]+" | grep -oE "[0-9.]+")
CYCLES=$(echo "$SNAP" | grep -oE "Cycle [0-9]+" | grep -oE "[0-9]+")
TEMP=$(echo "$SNAP" | grep -oE '[0-9]+\.[0-9]+°C' | head -1 | sed 's/°C//')
TEMP_INT=${TEMP%.*}
HEALTH_INT=${HEALTH%.*}
GRAY="color=#909090"
ORANGE="color=#FF9500"

if [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 45 ]; then
    notify_proactive_v2 "temp_critical" 300 "Critical Temperature" "${TEMP}°C - reduce load"
fi
if echo "$SNAP" | grep -q ", discharging" && [ -n "$PCT" ] && [ "$PCT" -le 20 ]; then
    notify_proactive_v2 "battery_critical" 900 "Battery Critical" "Battery ${PCT}% - plug in"
fi

IOREG_DATA=$(ioreg -rn AppleSmartBattery 2>/dev/null)
ICON_ISCHG=$(echo "$IOREG_DATA" | grep -oE '"IsCharging" = [A-Za-z]+' | awk '{print $3}')
ICON_EXT=$(echo "$IOREG_DATA" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
ICON_CHCUR=$(echo "$IOREG_DATA" | grep -oE '"ChargingCurrent"=[0-9]+' | grep -oE '[0-9]+' | head -1)
ICON_CURCAP=$(echo "$IOREG_DATA" | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
ICON_MAXCAP=$(echo "$IOREG_DATA" | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')
[ -z "$ICON_CHCUR" ] && ICON_CHCUR=0

case "$ACTIVE_MODE" in
    hold)        ICON="🔌" ;;
    charge_full) ICON="⚡" ;;
    discharge)   ICON="🔋" ;;
    calibration) ICON="⚡" ;;
    *)
        if [ "$ICON_ISCHG" = "Yes" ]; then
            ICON="⚡"
        elif [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
            ICON="🔌"
        else
            ICON="🔴"
        fi
        ;;
esac

if [ -n "$ICON_CURCAP" ] && [ -n "$ICON_MAXCAP" ] && [ "$ICON_MAXCAP" -gt 0 ] 2>/dev/null; then
    SMC_PCT=$(( (ICON_CURCAP * 100 + ICON_MAXCAP / 2) / ICON_MAXCAP ))
else
    SMC_PCT="?"
fi
[ -z "$PCT" ] && [ "$SMC_PCT" != "?" ] && PCT="$SMC_PCT"

case "$ACTIVE_MODE" in
    charge_full) MODE="Charging to 100%" ;;
    calibration) MODE="Calibrating" ;;
    discharge)   MODE="Discharging to ${LAST_UPPER}%" ;;
    hold)        MODE="Holding at ${PCT:-?}%" ;;
    *)
        if echo "$SNAP" | grep -q ", charging"; then
            if [ -n "$UPPER" ] && [ -n "$PCT" ] && [ "$PCT" -lt "$UPPER" ]; then
                MODE="Topping to ${UPPER}%"
            else
                MODE="Charging"
            fi
        elif echo "$SNAP" | grep -q ", no charging"; then
            if [ -n "$UPPER" ] && [ -n "$PCT" ]; then
                if [ "$PCT" -gt "$UPPER" ]; then MODE="Above limit (${PCT}% / ${UPPER}%)"
                elif [ "$PCT" -eq "$UPPER" ]; then MODE="Holding at ${UPPER}%"
                else MODE="Below limit (${PCT}% / ${UPPER}%)"
                fi
            elif [ -n "$UPPER" ]; then MODE="Holding at ${UPPER}%"
            else MODE="On adapter"
            fi
        elif echo "$SNAP" | grep -q ", discharging"; then
            MODE="On battery"
        else
            MODE="Unknown"
        fi
        ;;
esac

if [ "$ACTIVE_MODE" = "hold" ] && [ -n "$PCT" ] && [ -n "$UPPER" ]; then
    DIFF=$((PCT - UPPER))
    [ "$DIFF" -lt 0 ] && DIFF=$((-DIFF))
    if [ "$DIFF" -le 1 ]; then
        notify_proactive_v2 "hold_reached" 3600 "Battery at Limit" "Holding at ${UPPER}%"
    fi
fi

STUCK=""
echo "$SNAP" | grep -qE "Error:.*ongoing" && STUCK="yes"

CLAM=$(cat "$CFG" 2>/dev/null | grep "^clamshell" | grep -oE "[0-9]+" | head -1)
[ -z "$CLAM" ] && CLAM=0
SCHED=$(cat "$CFG" 2>/dev/null | grep "^schedule.enable" | grep -oE "[0-9]+" | head -1)
[ -z "$SCHED" ] && SCHED=0

TEMP_COLOR=""
[ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 42 ] 2>/dev/null && TEMP_COLOR="color=#FF3B30"
[ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 38 ] && [ "$TEMP_INT" -lt 42 ] 2>/dev/null && TEMP_COLOR="color=#FF9500"

ALERT_COLOR=""
[ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 42 ] 2>/dev/null && ALERT_COLOR="color=#FF3B30"
[ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 38 ] && [ "$TEMP_INT" -lt 42 ] 2>/dev/null && ALERT_COLOR="color=#FF9500"

if [ "$ICON_ISCHG" = "Yes" ] && [ "$ICON_CHCUR" -gt 50 ] 2>/dev/null; then
    STATE_COLOR="color=#707070"
elif [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
    STATE_COLOR="color=#FFFFFF"
else
    STATE_COLOR="color=#E8A0A0"
fi

if [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 42 ] 2>/dev/null; then
    FINAL_COLOR="color=#FF3B30"
elif [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 38 ] 2>/dev/null; then
    FINAL_COLOR="color=#FF9500"
else
    FINAL_COLOR="$STATE_COLOR"
fi

echo "${ICON} ${SMC_PCT}% | size=14 ${FINAL_COLOR}"
echo "---"
echo "Charge: ${PCT}% | size=11"
echo "Mode: ${MODE} | size=11"
echo "Health: ${HEALTH}% - ${CYCLES} cycles | size=11 $GRAY"
if [ -n "$UPPER" ] && [ -n "$LOWER" ]; then
    echo "Active Limit: ${UPPER}% / ${LOWER}% | size=11 $GRAY"
else
    echo "Active Limit: disabled | size=11 $GRAY"
fi
[ -n "$TEMP" ] && echo "Temperature: ${TEMP}°C | size=11 ${ALERT_COLOR:-color=#909090}"
echo "---"

PMSET_OUT=$(pmset -g custom 2>/dev/null)
PMSET_SECTION=""
SLEEP_VAL="?"; DISPLAY_VAL="?"; DISK_VAL="?"; HIB_VAL="?"; AC_SLEEP="?"
while IFS= read -r line; do
    case "$line" in
        "Battery Power:") PMSET_SECTION="bat"; continue ;;
        "AC Power:") PMSET_SECTION="ac"; continue ;;
    esac
    [ -z "$PMSET_SECTION" ] && continue
    key=$(echo "$line" | awk '{print $1}')
    val=$(echo "$line" | awk '{print $2}')
    [ -z "$key" ] && continue
    if [ "$PMSET_SECTION" = "bat" ]; then
        case "$key" in
            sleep) [ "$SLEEP_VAL" = "?" ] && SLEEP_VAL="$val" ;;
            displaysleep) [ "$DISPLAY_VAL" = "?" ] && DISPLAY_VAL="$val" ;;
            disksleep) [ "$DISK_VAL" = "?" ] && DISK_VAL="$val" ;;
            hibernatemode) [ "$HIB_VAL" = "?" ] && HIB_VAL="$val" ;;
        esac
    elif [ "$PMSET_SECTION" = "ac" ]; then
        case "$key" in
            sleep) [ "$AC_SLEEP" = "?" ] && AC_SLEEP="$val" ;;
        esac
    fi
done <<< "$PMSET_OUT"

if [ "$SLEEP_VAL" = "5" ] && [ "$DISPLAY_VAL" = "5" ]; then
    POWER_MODE="Fast Sleep"; MODE_KEY="fast"; USE_WHEN="leaving office"
elif [ "$SLEEP_VAL" = "18" ] && [ "$DISPLAY_VAL" = "10" ]; then
    POWER_MODE="Balanced"; MODE_KEY="balanced"; USE_WHEN="daily use"
elif [ "$SLEEP_VAL" = "60" ] && [ "$DISPLAY_VAL" = "15" ]; then
    POWER_MODE="Always Awake"; MODE_KEY="awake"; USE_WHEN="presentations"
elif [ "$SLEEP_VAL" = "0" ] && [ "$HIB_VAL" = "25" ]; then
    POWER_MODE="Deep Only"; MODE_KEY="deep"; USE_WHEN="travel"
else
    POWER_MODE="Custom"; MODE_KEY="custom"; USE_WHEN="manual"
fi

echo "Quick Actions | size=11 color=#007AFF disabled=true"
echo "Power Mode — ${POWER_MODE} | size=14 color=#FFFFFF"
echo "-- Fast Sleep | bash=$DISPATCH param1=power_mode_fast terminal=false refresh=true checked=$([ "$MODE_KEY" = "fast" ] && echo true || echo false) size=12"
echo "-- Balanced | bash=$DISPATCH param1=power_mode_balanced terminal=false refresh=true checked=$([ "$MODE_KEY" = "balanced" ] && echo true || echo false) size=12"
echo "-- Always Awake | bash=$DISPATCH param1=power_mode_awake terminal=false refresh=true checked=$([ "$MODE_KEY" = "awake" ] && echo true || echo false) size=12"
echo "-- Deep Only | bash=$DISPATCH param1=power_mode_deep terminal=false refresh=true checked=$([ "$MODE_KEY" = "deep" ] && echo true || echo false) size=12"
echo "-- Set Custom… | bash=$DISPATCH param1=power_mode_custom terminal=false refresh=true checked=$([ "$MODE_KEY" = "custom" ] && echo true || echo false) size=12"
echo "-- Active: Bat ${SLEEP_VAL}/${DISPLAY_VAL}/${DISK_VAL}m · AC ${AC_SLEEP}m | size=10 color=#505050 disabled=true"

SM_STATE=$(cat "$HOME/.battopt-swiftbar/.sleep_mode" 2>/dev/null || echo "default")
case "$SM_STATE" in
    presentation) SM_TITLE="Presentation" ;;
    download)     SM_TITLE="Long Tasks" ;;
    travel)       SM_TITLE="Travel" ;;
    *)            SM_TITLE="Normal" ;;
esac
echo "Sleep Mode — ${SM_TITLE} | size=14 color=#007AFF"
echo "-- Normal | bash=$DISPATCH param1=sleep_mode_default terminal=false refresh=true checked=$([ "$SM_STATE" = "default" ] && echo true || echo false) size=12"
echo "-- Presentation | bash=$DISPATCH param1=sleep_mode_presentation terminal=false refresh=true checked=$([ "$SM_STATE" = "presentation" ] && echo true || echo false) size=12"
echo "-- Long Tasks | bash=$DISPATCH param1=sleep_mode_download terminal=false refresh=true checked=$([ "$SM_STATE" = "download" ] && echo true || echo false) size=12"
echo "-- Travel | bash=$DISPATCH param1=sleep_mode_travel terminal=false refresh=true checked=$([ "$SM_STATE" = "travel" ] && echo true || echo false) size=12"
echo "-- Prepare for Sleep | bash=$DISPATCH param1=arm_sleep terminal=false refresh=true size=12 color=#007AFF"

if [ "$ACTIVE_MODE" = "hold" ]; then
    echo "✓ Stop Charging Now (hold at ${PCT}%) | bash=$DISPATCH param1=stop_now terminal=false refresh=true"
else
    echo "Stop Charging Now (hold at ${PCT}%) | bash=$DISPATCH param1=stop_now terminal=false refresh=true"
fi
if [ "$ACTIVE_MODE" = "charge_full" ]; then
    echo "✓ Charge to 100% & Hold | bash=$DISPATCH param1=charge_full terminal=false refresh=true"
else
    echo "Charge to 100% & Hold | bash=$DISPATCH param1=charge_full terminal=false refresh=true"
fi
if [ "$ACTIVE_MODE" = "discharge" ]; then
    echo "★ ✓ Smart Discharge to ${LOWER:-?}% | bash=$DISPATCH param1=smart_discharge terminal=false refresh=true checked=true $ORANGE"
    echo "↳ Stop Discharge (hold here) | bash=$DISPATCH param1=kill_discharge terminal=false refresh=true $GRAY"
else
    echo "★ Smart Discharge... | bash=$DISPATCH param1=smart_discharge terminal=false refresh=true $ORANGE"
fi
if [ -n "$STUCK" ]; then
    echo "Force Reset (STUCK!) | bash=$DISPATCH param1=force_reset terminal=false refresh=true color=red"
else
    echo "Force Reset | bash=$DISPATCH param1=force_reset terminal=false refresh=true $GRAY"
fi
echo "Reset to Defaults | bash=$DISPATCH param1=reset_defaults terminal=false refresh=true $GRAY"
echo "---"

echo "Charge Limits | size=11 color=#007AFF disabled=true"
if [ "$ACTIVE_MODE" = "idle" ]; then
    echo "✓ Custom Limit — ${UPPER}% / ${LOWER}% | bash=$DISPATCH param1=limit_custom terminal=false refresh=true"
else
    echo "Custom Limit — ${UPPER}% / ${LOWER}% | bash=$DISPATCH param1=limit_custom terminal=false refresh=true"
fi
# Sailing sub-indicator (restored v1.7.1)
if [ "$SAILING" = "true" ]; then
    echo "-- ✓ Sailing Mode (gap ${SAIL_GAP}%) | bash=$DISPATCH param1=sail_on terminal=false refresh=true"
    echo "-- Switch to Static Hold | bash=$DISPATCH param1=sail_off terminal=false refresh=true"
else
    echo "-- Static Hold Mode | bash=$DISPATCH param1=sail_off terminal=false refresh=true checked=true"
    echo "-- Switch to Sailing (gap ${SAIL_GAP}%) | bash=$DISPATCH param1=sail_on terminal=false refresh=true"
fi
echo "Remove Limit (hold current) | bash=$DISPATCH param1=remove_limit_hold terminal=false refresh=true"
echo "Disable All Limits (charge 100%) | bash=$DISPATCH param1=disable_limit terminal=false refresh=true color=#909090"
echo "---"

echo "Battery Care | size=11 color=#007AFF disabled=true"
CAL_RUNNING=$([ "$ACTIVE_MODE" = "calibration" ] && echo " · running" || echo "")
echo "Calibration${CAL_RUNNING} | size=14 color=#FFFFFF"
echo "-- Start Calibration | bash=$DISPATCH param1=calibrate terminal=false refresh=true size=12"
echo "-- Stop Calibration | bash=$DISPATCH param1=cal_stop terminal=false refresh=true size=12"
if [ "$ACTIVE_MODE" = "calibration" ]; then
    echo "-- Force Stop | bash=$DISPATCH param1=kill_calibrate terminal=false refresh=true size=12"
fi
echo "Clamshell Mode | size=14 color=#FFFFFF"
echo "-- Off (sleep) | bash=$DISPATCH param1=clam0 terminal=false refresh=true checked=$([ "$CLAM" = "0" ] && echo true || echo false) size=12"
echo "-- On (AC only) | bash=$DISPATCH param1=clam1 terminal=false refresh=true checked=$([ "$CLAM" = "1" ] && echo true || echo false) size=12"
echo "-- On + screen | bash=$DISPATCH param1=clam2 terminal=false refresh=true checked=$([ "$CLAM" = "2" ] && echo true || echo false) size=12"
echo "Schedule | size=14 color=#FFFFFF"
echo "-- Enable | bash=$DISPATCH param1=sched_on terminal=false refresh=true checked=$([ "$SCHED" = "1" ] && echo true || echo false) size=12"
echo "-- Disable | bash=$DISPATCH param1=sched_off terminal=false refresh=true size=12"
echo "---"

echo "Refresh Now | refresh=true"
echo "Show Full Status... | bash=$DISPATCH param1=details terminal=false"
echo "Sleep & Battery Report | bash=$DISPATCH param1=sleep_report terminal=false"
echo "Save Report | bash=$DISPATCH param1=sleep_report_save terminal=false"
echo "Open Reports | bash=$DISPATCH param1=open_reports terminal=false"
echo "Open Logs | bash=/usr/bin/open param1=/Library/Logs/battopt/ terminal=false"
echo "Open Actions Log | bash=$DISPATCH param1=open_actions_log terminal=false"
LOGIN_STATE=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -c "BattOpt" || true)
if [ "$LOGIN_STATE" -gt 0 ]; then
    echo "✓ Launch at Login | bash=$DISPATCH param1=login_toggle terminal=false refresh=true"
else
    echo "Launch at Login | bash=$DISPATCH param1=login_toggle terminal=false refresh=true"
fi
echo "Open BattOpt.app | bash=$DISPATCH param1=open_app terminal=false"
echo "About | bash=$DISPATCH param1=about terminal=false"
echo "---"

PSAVER_STATE=$([ -f "$HOME/.battopt-swiftbar/.power_saver" ] && echo "ON" || echo "OFF")
POWERNAP=$(pmset -g 2>/dev/null | grep -E "^ powernap" | awk '{print $2}' | head -1); [ -z "$POWERNAP" ] && POWERNAP="0"
WOMP=$(pmset -g 2>/dev/null | grep -E "^ womp" | awk '{print $2}' | head -1); [ -z "$WOMP" ] && WOMP="0"
TCPKEEP=$(pmset -g 2>/dev/null | grep -E "^ tcpkeepalive" | awk '{print $2}' | head -1); [ -z "$TCPKEEP" ] && TCPKEEP="0"
HIBERNATE=$(pmset -g 2>/dev/null | grep -E "^ hibernatemode" | awk '{print $2}' | head -1); [ -z "$HIBERNATE" ] && HIBERNATE="3"
STANDBY_DELAY=$(pmset -g 2>/dev/null | grep -E "^ standbydelayhigh" | awk '{print $2}' | head -1)
[ -z "$STANDBY_DELAY" ] && STANDBY_DELAY=$(pmset -g 2>/dev/null | grep -E "^ standbydelay " | awk '{print $2}' | head -1)
[ -z "$STANDBY_DELAY" ] && STANDBY_DELAY="4200"
STANDBY_MIN=$((STANDBY_DELAY / 60))

USB_CACHE="$HOME/.battopt-swiftbar/.usb_cache"
USB_TTL=300
if [ -f "$USB_CACHE" ]; then USB_AGE=$(($NOW_TS - $(stat -f %m "$USB_CACHE" 2>/dev/null || echo 0))); else USB_AGE=9999; fi
if [ "$USB_AGE" -lt "$USB_TTL" ]; then
    USB_EXT=$(cat "$USB_CACHE")
else
    USB_EXT=$(system_profiler SPUSBDataType 2>/dev/null | grep -c "Wireless Device" | head -1 | tr -d ' \n')
    [ -z "$USB_EXT" ] && USB_EXT=0
    echo "$USB_EXT" > "$USB_CACHE"
fi
[ -z "$USB_EXT" ] && USB_EXT=0
case "$USB_EXT" in ''|*[!0-9]*) USB_EXT=0 ;; esac

WAKE_CACHE="$HOME/.battopt-swiftbar/.wake_cache"
WAKE_TTL=600
if [ -f "$WAKE_CACHE" ]; then WAKE_AGE=$(($NOW_TS - $(stat -f %m "$WAKE_CACHE" 2>/dev/null || echo 0))); else WAKE_AGE=9999; fi
if [ "$WAKE_AGE" -lt "$WAKE_TTL" ]; then
    WAKE_COUNT=$(cat "$WAKE_CACHE")
else
    WAKE_COUNT=$(pmset -g log 2>/dev/null | grep -cE "Wake from|DarkWake")
    echo "$WAKE_COUNT" > "$WAKE_CACHE"
fi
[ -z "$WAKE_COUNT" ] && WAKE_COUNT=0

if [ "$PSAVER_STATE" = "ON" ]; then
    echo "💤 Sleep Report: OPTIMIZED | color=#30D158"
else
    echo "💤 Sleep Report: STANDARD | color=#FF9500"
fi
echo "-- 🔋 Battery: ${PCT}% | size=11"
echo "-- 💚 Health: ${HEALTH}% · ${CYCLES} cycles | size=11 $GRAY"
[ -n "$TEMP" ] && echo "-- 🌡️ Temperature: ${TEMP}°C | size=11 $TEMP_COLOR"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
if [ "$PSAVER_STATE" = "ON" ]; then
    echo "-- ✅ Power Saver: ENABLED | size=11 color=#30D158"
else
    echo "-- ⚠️ Power Saver: DISABLED | size=11 color=#FF9500"
fi
[ "$POWERNAP" = "0" ] && echo "-- ✅ Power Nap: OFF | size=11 color=#30D158" || echo "-- ⚠️ Power Nap: ON | size=11 color=#FF9500"
[ "$WOMP" = "0" ] && echo "-- ✅ Wake on Network: OFF | size=11 color=#30D158" || echo "-- ⚠️ Wake on Network: ON | size=11 color=#FF9500"
[ "$TCPKEEP" = "0" ] && echo "-- ✅ TCP Keep-Alive: OFF | size=11 color=#30D158" || echo "-- ⚠️ TCP Keep-Alive: ON | size=11 color=#FF9500"
[ "$STANDBY_MIN" -le 30 ] && echo "-- ✅ Hibernate after: ${STANDBY_MIN} min | size=11 color=#30D158" || echo "-- ⚠️ Hibernate after: ${STANDBY_MIN} min | size=11 color=#FF9500"
[ "$HIBERNATE" = "25" ] && echo "-- ✅ Deep Hibernate | size=11 color=#30D158" || echo "-- ℹ️ Hibernatemode: ${HIBERNATE} | size=11 $GRAY"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
echo "-- 📊 Wake events: ${WAKE_COUNT} | size=11 $GRAY"
echo "-- 🔌 External USB: ${USB_EXT} | size=11 $GRAY"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
if [ "$PSAVER_STATE" = "ON" ]; then
    echo "-- Disable Power Saver | bash=$DISPATCH param1=power_saver_off terminal=false refresh=true size=12"
else
    echo "-- Enable Power Saver | bash=$DISPATCH param1=power_saver_on terminal=false refresh=true color=#30D158 size=12"
fi
echo "-- Show Full Report | bash=$DISPATCH param1=power_saver_report terminal=false size=12"

AUTO_STATE=$([ -f "$HOME/.battopt-swiftbar/.auto_cleanup" ] && echo "ON" || echo "OFF")
IDLE=$(ioreg -c IOHIDSystem 2>/dev/null | grep -E "HIDIdleTime" | awk '{print $NF}' | head -1)
IDLE_MIN=$((IDLE / 1000000000 / 60))
[ -z "$IDLE_MIN" ] && IDLE_MIN=0

if [ "$AUTO_STATE" = "ON" ]; then
    echo "Auto Cleanup: ON ▶ | color=#30D158"
else
    echo "Auto Cleanup: OFF ▶ | color=#909090"
fi
echo "-- ⏱️ Current idle: ${IDLE_MIN} min | size=11 $GRAY"
echo "-- Run Cleanup Now | bash=$DISPATCH param1=pre_sleep_now terminal=false refresh=true size=12"
echo "-- Restore Services | bash=$DISPATCH param1=post_wake_now terminal=false refresh=true size=12"
if [ "$AUTO_STATE" = "ON" ]; then
    echo "-- Disable Auto Cleanup | bash=$DISPATCH param1=auto_cleanup_toggle terminal=false refresh=true size=12"
else
    echo "-- Enable Auto Cleanup | bash=$DISPATCH param1=auto_cleanup_toggle terminal=false refresh=true color=#30D158 size=12"
fi

echo "Developer Tools ▶ | size=11 color=#007AFF"
echo "-- Project Health Check | bash=$DISPATCH param1=project_health terminal=false refresh=true size=12"
echo "-- Conflict Detection | bash=$DISPATCH param1=conflict_check terminal=false size=12"
echo "-- Predictive Analysis | bash=$DISPATCH param1=predictive terminal=false size=12"
echo "-- Process Monitor | bash=$DISPATCH param1=process_monitor terminal=false size=12"

echo "Logs ▶ | size=11 color=#007AFF"
echo "-- AI Diagnostic Bundle | bash=$DISPATCH param1=logs_ai_bundle terminal=false refresh=true color=#30D158 size=12"
echo "-- Actions Log | bash=$DISPATCH param1=logs_actions terminal=false"
echo "-- Sailing History | bash=$DISPATCH param1=logs_sailing terminal=false"
echo "-- Arm Log | bash=$DISPATCH param1=logs_arm terminal=false"
echo "-- Daemon Logs | bash=$DISPATCH param1=logs_daemon terminal=false"
echo "-- Reports Folder | bash=$DISPATCH param1=logs_reports terminal=false"

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
AGENT_COUNT=$(launchctl list 2>/dev/null | grep -c "com.battopt")
echo "Services: ${AGENT_COUNT} agents loaded | size=11 color=#909090"
echo "Stop ALL Services (full shutdown) | bash=$DISPATCH param1=shutdown terminal=false refresh=true color=red"
