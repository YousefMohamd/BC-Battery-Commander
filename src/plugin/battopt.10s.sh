#!/bin/bash
# <xbar.title>BattOpt Control Center</xbar.title>
# <xbar.version>1.3.0</xbar.version>
# <xbar.author>Yousef</xbar.author>
# <xbar.desc>Sailing mode, smart discharge, calibration, clamshell, schedule, proactive notifications.</xbar.desc>
# <xbar.abouturl>https://battopt.buddha-path.top</xbar.abouturl>
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
TERMINAL_NOTIFIER="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
BATTOPT_ICON="$DASH/icons/battopt.png"

mkdir -p "$NOTIFY_DIR"

# TASK 2: Immediate SwiftBar refresh trigger
_refresh_plugin() {
    /usr/bin/open -g "swiftbar://refreshplugin?name=battopt.10s" >/dev/null 2>&1 || true
}
trap '_refresh_plugin' EXIT

LAST_UPPER=80; LAST_LOWER=75; SAILING=true; SAIL_GAP=10
[ -f "$MYCFG" ] && source "$MYCFG"

# Always re-read config — bypasses any stale variable state
[ -f "$MYCFG" ] && source "$MYCFG" 2>/dev/null
LAST_UPPER="${LAST_UPPER:-80}"
LAST_LOWER="${LAST_LOWER:-75}"

# === STATUS CACHE (20s TTL) ===
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

# === notify_proactive_v2 (v1.5.2) ===
notify_proactive_v2() {
    local key="$1" cooldown="$2" title="$3" msg="$4"
    local NOTIFY_DIR="$HOME/.battopt-swiftbar/.notify"
    mkdir -p "$NOTIFY_DIR"
    local now=$(date +%s)
    local today=$(date +%Y%m%d)
    local hour=$(date +%H)
    local daily_file="$NOTIFY_DIR/.daily_$today"
    local type_file="$NOTIFY_DIR/$key"
    local is_critical=0
    case "$key" in
        battery_critical|temp_critical|enforce_critical|daemon_recovery|hold_reached|hold_reached_*)
            is_critical=1 ;;
    esac
    if [ "$is_critical" = "0" ]; then
        if [ "$hour" -ge 23 ] || [ "$hour" -lt 8 ]; then
            return 0
        fi
    fi
    if [ -f "$daily_file" ]; then
        local count=$(wc -l < "$daily_file" | tr -d ' ')
        if [ "$count" -ge 3 ]; then
            return 0
        fi
    fi
    if [ "$is_critical" = "0" ] && [ -f "$type_file" ]; then
        local last=$(cat "$type_file" 2>/dev/null || echo 0)
        local diff=$((now - last))
        [ "$diff" -lt 1800 ] && return 0
    fi
    if [ "$is_critical" = "1" ] && [ -f "$type_file" ]; then
        local last=$(cat "$type_file" 2>/dev/null || echo 0)
        local diff=$((now - last))
        [ "$diff" -lt 1800 ] && return 0
    fi
    if [ -f "$type_file" ]; then
        local last=$(cat "$type_file" 2>/dev/null || echo 0)
        local diff=$((now - last))
        [ "$diff" -lt "$cooldown" ] && return 0
    fi
    echo "$now" > "$type_file"
    echo "$key" >> "$daily_file"
    local NOTIFIER="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
    if [ -x "$NOTIFIER" ]; then
        "$NOTIFIER" -title "BattOpt" -subtitle "$title" -message "$msg" -appIcon "$BATTOPT_ICON" -contentImage "$BATTOPT_ICON" -group "battopt-$key" -sound default 2>/dev/null
    else
        osascript -e "display notification \"$msg\" with title \"$title\"" 2>/dev/null
    fi
}

# ============ AUTO RECOVERY ============
# F1: Respect shutdown - do not auto-recover daemon after intentional shutdown
if [ -f "$HOME/.battopt-swiftbar/.user_shutdown" ]; then
    echo "0" > "$FAIL_FILE" 2>/dev/null || true
elif [ -z "$SNAP" ] || echo "$SNAP" | grep -q "Timeout\|not running"; then
    FAILS=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
    FAILS=$((FAILS + 1))
    echo "$FAILS" > "$FAIL_FILE"
    if [ "$FAILS" -ge 3 ]; then
        notify_proactive_v2 "daemon_recovery" 600 "BattOpt Recovery" "Daemon unresponsive — auto-restarting"
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
TEMP=$(echo "$SNAP" | grep -oE '[0-9]+\.[0-9]+°C' | head -1 | sed 's/°C//')
[ -z "$TEMP" ] && TEMP=$(echo "$SNAP" | grep 'Capacity' | head -1 | grep -oE '[0-9]+\.[0-9]+°C' | head -1 | sed 's/°C//')
[ -z "$TEMP" ] && TEMP=$(echo "$SNAP" | grep 'Capacity' | head -1 | awk -F',' '{print $3}' | grep -oE '[0-9]+\.[0-9]+' | head -1)
[ -z "$TEMP" ] && TEMP=""
TRIAL=$(echo "$SNAP" | grep -oE "expire in [0-9]+ days" | grep -oE "[0-9]+")
TEMP_INT=${TEMP%.*}
HEALTH_INT=${HEALTH%.*}
GRAY="color=#909090"
ORANGE="color=#FF9500"

# ============ PROACTIVE CHECKS ============
if [ -n "$TEMP_INT" ]; then
    if [ "$TEMP_INT" -ge 45 ]; then
        notify_proactive_v2 "temp_critical" 300 "Battery Critical Temperature" "${TEMP}°C - reduce load immediately"
    elif [ "$TEMP_INT" -ge 42 ]; then
        : # REMOVED v1.5.2 (noise) temp_high
    fi
fi
if echo "$SNAP" | grep -q ", discharging" && [ -n "$PCT" ] && [ "$PCT" -le 20 ]; then
    : # REMOVED v1.5.2 (noise) low_batt
fi
if echo "$SNAP" | grep -q ", charging" && [ -n "$PCT" ] && [ "$PCT" -ge 99 ] && [ -z "$UPPER" ]; then
    : # REMOVED v1.5.2 (noise) full_charge
fi
if [ -n "$HEALTH_INT" ] && [ "$HEALTH_INT" -le 75 ]; then
    : # REMOVED v1.5.2 (noise) health_low
fi
SD_STATE="$HOME/.battopt-swiftbar/.sd_watch"
if [ -f "$SD_STATE" ]; then
    SD_TARGET=$(cat "$SD_STATE" 2>/dev/null)
    if [ -n "$PCT" ] && [ -n "$SD_TARGET" ] && [ "$PCT" -le "$SD_TARGET" ]; then
        notify_proactive_v2 "sd_complete" 1800 "Smart Discharge" "Reached target ${SD_TARGET}%"
        rm -f "$SD_STATE"
    fi
fi
if echo "$SNAP" | grep -q ", discharging"; then
    if [ -n "$PCT" ] && [ "$PCT" -le 61 ] && [ "$PCT" -gt 20 ]; then
        : # REMOVED v1.5.2 (noise) battery_low_warning
    fi
    if [ -n "$PCT" ] && [ "$PCT" -le 20 ]; then
        notify_proactive_v2 "battery_critical" 900 "🔴 Battery Critical" "Battery at ${PCT}% - plug in charger immediately"
    fi
fi
if [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 40 ]; then
    if [ -n "$PCT" ] && [ -n "$UPPER" ] && [ "$PCT" -gt "$UPPER" ]; then
        notify_proactive_v2 "load_heat_override" 600 "⚠️ Load + Heat" "Battery ${PCT}% > limit ${UPPER}% with temp ${TEMP}C — check for macOS override"
    fi
fi
TEMP_INT=${TEMP%.*}
TEMP_FLAG="$HOME/.battopt-swiftbar/.temp_alert_state"
if [ -n "$TEMP_INT" ]; then
    PREV_STATE=$(cat "$TEMP_FLAG" 2>/dev/null || echo "0")
    if [ "$TEMP_INT" -ge 42 ] && [ "$PREV_STATE" != "1" ]; then
        notify_proactive_v2 "temp_critical" 1800 "🌡️ Battery Hot" "Temperature: ${TEMP}°C — unplug charger, check cooling"
        echo "1" > "$TEMP_FLAG"
    elif [ "$TEMP_INT" -lt 38 ] && [ "$PREV_STATE" = "1" ]; then
        echo "0" > "$TEMP_FLAG"
    fi
fi

# Process inspection is gone on purpose. The Sentinel session is the only UI state.

IOREG_DATA=$(ioreg -rn AppleSmartBattery 2>/dev/null)
ICON_ISCHG=$(echo "$IOREG_DATA" | grep -oE '"IsCharging" = [A-Za-z]+' | awk '{print $3}')
ICON_EXT=$(echo "$IOREG_DATA" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
ICON_CHCUR=$(echo "$IOREG_DATA" | grep -oE '"ChargingCurrent"=[0-9]+' | grep -oE '[0-9]+' | head -1)
ICON_NCR=$(echo "$IOREG_DATA" | grep -oE '"NotChargingReason"=[0-9]+' | grep -oE '[0-9]+' | head -1)
ICON_CURCAP=$(echo "$IOREG_DATA" | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
ICON_MAXCAP=$(echo "$IOREG_DATA" | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')
[ -z "$ICON_CHCUR" ] && ICON_CHCUR=0
[ -z "$ICON_NCR" ] && ICON_NCR=0

# Display-state system (separate, read-only): primary decision, original logic below is fallback
DISPLAY_OK=0
DISPLAY_HELPER=""
if [ -x "$HOME/.battopt-swiftbar/display_state.sh" ]; then
    DISPLAY_HELPER="$HOME/.battopt-swiftbar/display_state.sh"
elif [ -x "$(dirname "$0")/display_state.sh" ]; then
    DISPLAY_HELPER="$(dirname "$0")/display_state.sh"
fi
if [ -n "$DISPLAY_HELPER" ]; then
    DISPLAY_OUT=$(DISPLAY_MODE="$ACTIVE_MODE" TEMP_INT="${TEMP_INT:-}" "$DISPLAY_HELPER" 2>/dev/null) || DISPLAY_OUT=""
    case "$DISPLAY_OUT" in
        *ICON=*FINAL_COLOR=*)
            eval "$DISPLAY_OUT"
            ACTIVE_MODE="$DISPLAY_MODE"
            DISPLAY_OK=1
            ;;
    esac
fi
if [ "$DISPLAY_OK" != "1" ]; then
# Hardware-first override: silent hold detection
if [ "$ICON_NCR" = "14" ] && [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ] && \
   [ "$ACTIVE_MODE" != "discharge" ] && [ "$ACTIVE_MODE" != "calibration" ]; then
    ACTIVE_MODE="hold"
fi

# Discharge icon: trust ACTIVE_MODE AND verify with non-sudo pgrep
if [ "$ACTIVE_MODE" = "discharge" ]; then
    if ! pgrep -f "battopt discharge" >/dev/null 2>&1; then
        ACTIVE_MODE="hold"
    fi
fi

# Fallback: if discharge process is running but ACTIVE_MODE is stale, fix it
if [ "$ACTIVE_MODE" != "discharge" ] && pgrep -f "battopt discharge" >/dev/null 2>&1; then
    ACTIVE_MODE="discharge"
fi

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

# Battery-first: on battery, show red regardless of mode (user decision 03:01)
if [ "$ICON_EXT" = "No" ] && [ "$ICON_ISCHG" = "No" ]; then
    ICON="🔴"
fi
fi

if [ -n "$ICON_CURCAP" ] && [ -n "$ICON_MAXCAP" ] && [ "$ICON_MAXCAP" -gt 0 ] 2>/dev/null; then
    SMC_PCT=$(( (ICON_CURCAP * 100 + ICON_MAXCAP / 2) / ICON_MAXCAP ))
else
    SMC_PCT="?"
fi

if [ -z "$PCT" ] && [ "$SMC_PCT" != "?" ]; then
    PCT="$SMC_PCT"
fi

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
                if [ "$PCT" -gt "$UPPER" ]; then
                    MODE="Above limit (${PCT}% / ${UPPER}%)"
                elif [ "$PCT" -eq "$UPPER" ]; then
                    MODE="Holding at ${UPPER}%"
                else
                    MODE="Below limit (${PCT}% / ${UPPER}%)"
                fi
            elif [ -n "$UPPER" ]; then
                MODE="Holding at ${UPPER}%"
            else
                MODE="On adapter"
            fi
        elif echo "$SNAP" | grep -q ", discharging"; then
            MODE="On battery"
        else
            MODE="Unknown"
        fi
        ;;
esac

STATE=$(echo "$SNAP" | grep -oE ', (charging|discharging|no charging)' | head -1 | sed 's/^, //')

if [ "$ACTIVE_MODE" = "hold" ] && [ -n "$PCT" ] && [ -n "$UPPER" ]; then
    DIFF=$((PCT - UPPER))
    [ "$DIFF" -lt 0 ] && DIFF=$((-DIFF))
    if [ "$DIFF" -le 1 ]; then
        notify_proactive_v2 "hold_reached" 3600 \
            "Battery at Limit" \
            "Holding at ${UPPER}% (charge limit enforced)"
    fi
fi

STUCK=""
echo "$SNAP" | grep -qE "Error:.*ongoing" && STUCK="yes"

CLAM=$(cat "$CFG" 2>/dev/null | grep "^clamshell" | grep -oE "[0-9]+" | head -1)
[ -z "$CLAM" ] && CLAM=0
SCHED=$(cat "$CFG" 2>/dev/null | grep "^schedule.enable" | grep -oE "[0-9]+" | head -1)
[ -z "$SCHED" ] && SCHED=0

TEMP_COLOR=""
if [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 42 ] 2>/dev/null; then
    TEMP_COLOR="color=#FF3B30"
elif [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 38 ] 2>/dev/null; then
    TEMP_COLOR="color=#FF9500"
fi
if [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 42 ] 2>/dev/null; then
    ALERT_COLOR="color=#FF3B30"
elif [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 38 ] 2>/dev/null; then
    ALERT_COLOR="color=#FF9500"
else
    ALERT_COLOR=""
fi

if [ "$DISPLAY_OK" != "1" ]; then
if [ "$ICON_ISCHG" = "Yes" ] && [ "$ICON_CHCUR" -gt 50 ] 2>/dev/null; then
    STATE_COLOR="color=#707070"
elif [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
    STATE_COLOR="color=#FFFFFF"
else
    STATE_COLOR="color=#E8A0A0"
fi

if [ "$ACTIVE_MODE" = "discharge" ]; then
    FINAL_COLOR="color=#8A9AAB"
elif [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 42 ] 2>/dev/null; then
    FINAL_COLOR="color=#FF3B30"
elif [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 38 ] 2>/dev/null; then
    FINAL_COLOR="color=#FF9500"
else
    FINAL_COLOR="$STATE_COLOR"
fi
fi

echo "${ICON} ${SMC_PCT}% | size=14 ${FINAL_COLOR}"
echo "---"
echo "Charge: ${PCT}% | size=11"
echo "Mode: ${MODE} | size=11"
echo "Health: ${HEALTH}% - ${CYCLES} cycles | size=11 $GRAY"
if [ -n "$TEMP" ]; then
    echo "Temperature: ${TEMP}°C | size=11 ${ALERT_COLOR:-color=#909090}"
fi
[ -n "$TRIAL" ] && echo "Trial: ${TRIAL} days | size=11 color=orange"

echo "---"

PMSET_OUT=$(pmset -g custom 2>/dev/null)
PMSET_SECTION=""
PMSET_SLEEP_BAT=""; PMSET_DISPLAY_BAT=""; PMSET_DISK_BAT=""; PMSET_HIB_BAT=""
PMSET_SLEEP_AC=""
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
            sleep) [ -z "$PMSET_SLEEP_BAT" ] && PMSET_SLEEP_BAT="$val" ;;
            displaysleep) [ -z "$PMSET_DISPLAY_BAT" ] && PMSET_DISPLAY_BAT="$val" ;;
            disksleep) [ -z "$PMSET_DISK_BAT" ] && PMSET_DISK_BAT="$val" ;;
            hibernatemode) [ -z "$PMSET_HIB_BAT" ] && PMSET_HIB_BAT="$val" ;;
        esac
    elif [ "$PMSET_SECTION" = "ac" ]; then
        case "$key" in
            sleep) [ -z "$PMSET_SLEEP_AC" ] && PMSET_SLEEP_AC="$val" ;;
        esac
    fi
done <<< "$PMSET_OUT"

SLEEP_VAL="${PMSET_SLEEP_BAT:-?}"
DISPLAY_VAL="${PMSET_DISPLAY_BAT:-?}"
DISK_VAL="${PMSET_DISK_BAT:-?}"
HIB_VAL="${PMSET_HIB_BAT:-?}"
AC_SLEEP="${PMSET_SLEEP_AC:-?}"
[ -z "$SLEEP_VAL" ] && SLEEP_VAL="?"
[ -z "$DISPLAY_VAL" ] && DISPLAY_VAL="?"
[ -z "$DISK_VAL" ] && DISK_VAL="?"
[ -z "$HIB_VAL" ] && HIB_VAL="?"
[ -z "$AC_SLEEP" ] && AC_SLEEP="?"

if [ "$SLEEP_VAL" = "5" ] && [ "$DISPLAY_VAL" = "5" ]; then
    POWER_MODE="Fast Sleep"; MODE_KEY="fast"; USE_WHEN="leaving office"
elif [ "$SLEEP_VAL" = "18" ] && [ "$DISPLAY_VAL" = "10" ]; then
    POWER_MODE="Balanced"; MODE_KEY="balanced"; USE_WHEN="daily use"
elif [ "$SLEEP_VAL" = "60" ] && [ "$DISPLAY_VAL" = "15" ]; then
    POWER_MODE="Always Awake"; MODE_KEY="awake"; USE_WHEN="presentations"
elif [ "$SLEEP_VAL" = "0" ] && [ "$HIB_VAL" = "25" ]; then
    POWER_MODE="Deep Only"; MODE_KEY="deep"; USE_WHEN="travel / storage"
else
    POWER_MODE="Custom"; MODE_KEY="custom"; USE_WHEN="manual values"
fi

M_FAST=" "; M_BAL=" "; M_AWK=" "; M_DP=" "; M_CUS=" "
case "$MODE_KEY" in
    fast)     M_FAST="✓" ;;
    balanced) M_BAL="✓" ;;
    awake)    M_AWK="✓" ;;
    deep)     M_DP="✓" ;;
    custom)   M_CUS="✓" ;;
esac

echo "Quick Actions | size=11 color=#007AFF disabled=true"
echo "Power Mode — ${POWER_MODE} | size=14 color=#FFFFFF"
echo "-- Fast Sleep | bash=$DISPATCH param1=power_mode_fast terminal=false refresh=true checked=$([ "$MODE_KEY" = "fast" ] && echo true || echo false) size=12"
echo "-- 5/5/15 · office profile | size=9 color=#909090 disabled=true"
echo "-- Balanced | bash=$DISPATCH param1=power_mode_balanced terminal=false refresh=true checked=$([ "$MODE_KEY" = "balanced" ] && echo true || echo false) size=12"
echo "-- 18/10/15 · daily use | size=9 color=#909090 disabled=true"
echo "-- Always Awake | bash=$DISPATCH param1=power_mode_awake terminal=false refresh=true checked=$([ "$MODE_KEY" = "awake" ] && echo true || echo false) size=12"
echo "-- AC required · presentations | size=9 color=#909090 disabled=true"
echo "-- Deep Only | bash=$DISPATCH param1=power_mode_deep terminal=false refresh=true checked=$([ "$MODE_KEY" = "deep" ] && echo true || echo false) size=12"
echo "-- Immediate sleep · travel | size=9 color=#909090 disabled=true"
echo "-- Set Custom Values… | bash=$DISPATCH param1=power_mode_custom terminal=false refresh=true checked=$([ "$MODE_KEY" = "custom" ] && echo true || echo false) size=12"
echo "-- Configure manually | size=9 color=#909090 disabled=true"
echo "-- Active: Bat ${SLEEP_VAL}/${DISPLAY_VAL}/${DISK_VAL}m · AC ${AC_SLEEP}m | size=10 color=#505050 disabled=true"
echo "-- Usage: ${USE_WHEN} | size=10 color=#505050 disabled=true"

SM_STATE=$(cat "$HOME/.battopt-swiftbar/.sleep_mode" 2>/dev/null || echo "default")
case "$SM_STATE" in
    presentation) SM_TITLE="Presentation" ;;
    download)     SM_TITLE="Long Tasks" ;;
    travel)       SM_TITLE="Travel" ;;
    *)            SM_TITLE="Normal" ;;
esac
SM_DEF_MARK=" "; SM_PRE_MARK=" "; SM_LT_MARK=" "; SM_TRV_MARK=" "
case "$SM_STATE" in
    default)      : ;;
    presentation) : ;;
    download)     : ;;
    travel)       : ;;
esac
echo "Sleep Mode — ${SM_TITLE} | size=14 color=#007AFF"
echo "-- Normal | bash=$DISPATCH param1=sleep_mode_default terminal=false refresh=true checked=$([ "$SM_STATE" = "default" ] && echo true || echo false) size=12"
echo "-- macOS handles sleep | size=9 color=#909090 disabled=true"
echo "-- Presentation | bash=$DISPATCH param1=sleep_mode_presentation terminal=false refresh=true checked=$([ "$SM_STATE" = "presentation" ] && echo true || echo false) size=12"
echo "-- Never sleeps on AC | size=9 color=#909090 disabled=true"
echo "-- Long Tasks | bash=$DISPATCH param1=sleep_mode_download terminal=false refresh=true checked=$([ "$SM_STATE" = "download" ] && echo true || echo false) size=12"
echo "-- Lid closed · AC required | size=9 color=#909090 disabled=true"
echo "-- Travel | bash=$DISPATCH param1=sleep_mode_travel terminal=false refresh=true checked=$([ "$SM_STATE" = "travel" ] && echo true || echo false) size=12"
echo "-- Battery holds longer (4h) | size=9 color=#909090 disabled=true"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
echo "-- Prepare for Sleep | bash=$DISPATCH param1=arm_sleep terminal=false refresh=true size=12 color=#007AFF"
echo "-- Close audio apps · arm sleep | size=9 color=#909090 disabled=true"

if [ "$ACTIVE_MODE" = "hold" ]; then
    echo "✓ Stop Charging Now (hold at ${PCT}%) | bash=$DISPATCH param1=stop_now terminal=false refresh=true"
else
    echo "Stop Charging Now (hold at ${PCT}%) | bash=$DISPATCH param1=stop_now terminal=false refresh=true"
fi
if [ "$ACTIVE_MODE" = "charge_full" ] || [ -f "$DASH/.charge_full_active" ]; then
    echo "✓ Charge to 100% & Hold | bash=$DISPATCH param1=charge_full terminal=false refresh=true"
else
    echo "Charge to 100% & Hold | bash=$DISPATCH param1=charge_full terminal=false refresh=true"
fi

if [ "$ACTIVE_MODE" = "discharge" ]; then
    echo "★ ✓ Smart Discharge to ${SD_TARGET:-${LAST_UPPER:-?}}% | bash=$DISPATCH param1=smart_discharge terminal=false refresh=true checked=true $ORANGE"
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
DISP_UPPER="${LAST_UPPER:-${UPPER:-80}}"
DISP_LOWER="${LAST_LOWER:-${LOWER:-75}}"
if [ "$ACTIVE_MODE" = "idle" ] || [ "$ACTIVE_MODE" = "hold" ]; then
    echo "✓ Custom Limit — ${DISP_UPPER}% / ${DISP_LOWER}% | bash=$DISPATCH param1=limit_custom terminal=false refresh=true"
else
    echo "Custom Limit — ${DISP_UPPER}% / ${DISP_LOWER}% | bash=$DISPATCH param1=limit_custom terminal=false refresh=true"
fi

echo "Remove Limit (hold at current) | bash=$DISPATCH param1=remove_limit_hold terminal=false refresh=true"
echo "Disable All Limits (charge to 100%) | bash=$DISPATCH param1=disable_limit terminal=false refresh=true color=#909090"
echo "---"

echo "Battery Care | size=11 color=#007AFF disabled=true"
CAL_RUNNING=$([ "$ACTIVE_MODE" = "calibration" ] && echo " · running" || echo "")
echo "Calibration${CAL_RUNNING} | size=14 color=#FFFFFF"
echo "-- Full cycle (15% → 100%) to fix inaccurate % | size=10 color=#909090 disabled=true"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
echo "-- Start Calibration | bash=$DISPATCH param1=calibrate terminal=false refresh=true size=12"
echo "-- Runs a full discharge then charge cycle. | size=9 color=#909090 disabled=true"
echo "-- Takes several hours. | size=9 color=#909090 disabled=true"
echo "-- Stop Calibration (API) | bash=$DISPATCH param1=cal_stop terminal=false refresh=true size=12"
echo "-- Gracefully stops an active calibration. | size=9 color=#909090 disabled=true"
if [ "$ACTIVE_MODE" = "calibration" ]; then
    echo "-- Force Stop Calibration | bash=$DISPATCH param1=kill_calibrate terminal=false refresh=true size=12"
    echo "-- Immediate stop if calibration is stuck. | size=9 color=#909090 disabled=true"
fi
echo "Clamshell Mode | size=14 color=#FFFFFF"
echo "-- What Mac does when the lid is closed: | size=10 color=#909090 disabled=true"
echo "-- Sleep / Stay awake (AC) / Stay awake + screen | size=10 color=#909090 disabled=true"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
echo "-- Off - sleep when lid closes | bash=$DISPATCH param1=clam0 terminal=false refresh=true checked=$([ "$CLAM" = "0" ] && echo true || echo false) size=12"
echo "-- Mac sleeps → saves battery. | size=9 color=#909090 disabled=true"
echo "-- On - keep running (AC only) | bash=$DISPATCH param1=clam1 terminal=false refresh=true checked=$([ "$CLAM" = "1" ] && echo true || echo false) size=12"
echo "-- Mac keeps running → needs charger. | size=9 color=#909090 disabled=true"
echo "-- On + screen - always visible | bash=$DISPATCH param1=clam2 terminal=false refresh=true checked=$([ "$CLAM" = "2" ] && echo true || echo false) size=12"
echo "-- Both Mac and screen stay on → highest drain. | size=9 color=#909090 disabled=true"
echo "Schedule | size=14 color=#FFFFFF"
echo "-- Auto-run calibration every few weeks | size=10 color=#909090 disabled=true"
echo "-- Keeps battery % accurate without manual work | size=10 color=#909090 disabled=true"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
echo "-- Enable | bash=$DISPATCH param1=sched_on terminal=false refresh=true checked=$([ "$SCHED" = "1" ] && echo true || echo false) size=12"
echo "-- Turn on. App recalibrates on its own. | size=9 color=#909090 disabled=true"
echo "-- Disable | bash=$DISPATCH param1=sched_off terminal=false refresh=true size=12"
echo "-- Stop all automatic calibration. | size=9 color=#909090 disabled=true"
echo "---"

echo "Refresh Now | refresh=true"
echo "Show Full Status... | bash=$DISPATCH param1=details terminal=false"
echo "Sleep & Battery Report | bash=$DISPATCH param1=sleep_report terminal=false"
echo "Save Report (silent) | bash=$DISPATCH param1=sleep_report_save terminal=false"
echo "Open Reports Folder | bash=$DISPATCH param1=open_reports terminal=false"
echo "Open BattOpt Logs | bash=/usr/bin/open param1=/Library/Logs/battopt/ terminal=false"
echo "Open Actions Log | bash=$DISPATCH param1=open_actions_log terminal=false"
LOGIN_STATE=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -c "BattOpt" || true)
if [ "$LOGIN_STATE" -gt 0 ]; then
    echo "✓ Launch at Login | bash=$DISPATCH param1=login_toggle terminal=false refresh=true"
else
    echo "Launch at Login | bash=$DISPATCH param1=login_toggle terminal=false refresh=true"
fi
echo "Open BattOpt.app | bash=$DISPATCH param1=open_app terminal=false"

# === 7-DAY TEST COUNTDOWN ===
if [ -f "$DASH/.7day_test_start" ]; then
    start_ts=$(cat "$DASH/.7day_test_start")
    now_ts=$(date +%s)
    elapsed=$(( (now_ts - start_ts) / 86400 ))
    days_left=$(( 7 - elapsed ))

    if [ "$days_left" -ge 0 ]; then
        echo "🧪 7-Day Test: $days_left days left | color=#FF9500"
    else
        echo "🧪 7-Day Test: COMPLETE | color=#30D158"
        if [ ! -f "$DASH/.report_sent" ]; then
            bash "$DASH/verify-install.sh" > "$DASH/final_report.txt" 2>&1
            bash "$DASH/self_maintenance.sh" >> "$DASH/final_report.txt" 2>&1
            /Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier \
                -title "BattOpt Alert" \
                -message "7-Day Test Complete! Report saved to $DASH/final_report.txt"
            touch "$DASH/.report_sent"
            rm -f "$DASH/.7day_test_start"
        fi
    fi
fi
# === END 7-DAY TEST ===

echo "About BattOpt... | bash=$DISPATCH param1=about terminal=false"
echo "Renew Trial Now | bash=/usr/local/bin/battopt-trial-renew terminal=false refresh=true"
echo "---"

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

USB_CACHE="$HOME/.battopt-swiftbar/.usb_cache"
USB_TTL=300
if [ -f "$USB_CACHE" ]; then
    USB_AGE=$(($NOW_TS - $(stat -f %m "$USB_CACHE" 2>/dev/null || echo 0)))
else
    USB_AGE=9999
fi
if [ "$USB_AGE" -lt "$USB_TTL" ]; then
    USB_EXT=$(cat "$USB_CACHE")
else
    USB_EXT=$(system_profiler SPUSBDataType 2>/dev/null | grep -c "Wireless Device" | head -1 | tr -d ' \n')
    [ -z "$USB_EXT" ] && USB_EXT=0
    echo "$USB_EXT" > "$USB_CACHE"
fi
[ -z "$USB_EXT" ] && USB_EXT=0
case "$USB_EXT" in
    ''|*[!0-9]*) USB_EXT=0 ;;
esac

WAKE_CACHE="$HOME/.battopt-swiftbar/.wake_cache"
WAKE_TTL=600
if [ -f "$WAKE_CACHE" ]; then
    WAKE_AGE=$(($NOW_TS - $(stat -f %m "$WAKE_CACHE" 2>/dev/null || echo 0)))
else
    WAKE_AGE=9999
fi
if [ "$WAKE_AGE" -lt "$WAKE_TTL" ]; then
    WAKE_COUNT=$(cat "$WAKE_CACHE")
else
    WAKE_COUNT=$(pmset -g log 2>/dev/null | grep -cE "Wake from|DarkWake")
    echo "$WAKE_COUNT" > "$WAKE_CACHE"
fi
[ -z "$WAKE_COUNT" ] && WAKE_COUNT=0

if [ "$PSAVER_STATE" = "ON" ]; then
    echo "💤 Sleep Report: OPTIMIZED | color=#909090"
else
    echo "💤 Sleep Report: STANDARD | color=#909090"
fi
echo "-- 🔋 Battery: ${PCT}% | size=11"
echo "-- 💚 Health: ${HEALTH}% · ${CYCLES} cycles | size=11 $GRAY"
if [ -n "$TEMP" ]; then
    echo "-- 🌡️ Temperature: ${TEMP}°C | size=11 $TEMP_COLOR"
else
    echo "-- 🌡️ Temperature: N/A | size=11 color=red"
fi
if [ -n "$STATE" ]; then
    echo "-- ⚡ State: ${STATE} | size=11"
else
    echo "-- ⚡ State: Unknown | size=11 color=red"
fi

SAIL_STATE="$HOME/.battopt-swiftbar/.sailing_state"
if [ -f "$SAIL_STATE" ]; then
    if [ -z "$UPPER" ] && [ -z "$LOWER" ]; then
        source "$SAIL_STATE" 2>/dev/null
    fi
    if [ -n "$UPPER" ] && [ -n "$LOWER" ]; then
        RANGE_DIFF=$((UPPER - LOWER))
        if [ "$PCT" -ge "$UPPER" ]; then
            POS="at upper (${UPPER}%)"
            POS_COLOR="color=#FF9500"
        elif [ "$PCT" -le "$LOWER" ]; then
            POS="at lower (${LOWER}%)"
            POS_COLOR="color=#FF9500"
        else
            POS="mid (${PCT}%)"
            POS_COLOR="color=#30D158"
        fi
        echo "-- ─────"
        echo "-- 🔄 Sailing Range: ${LOWER}% ↔ ${UPPER}% (${RANGE_DIFF}% gap) | size=11 color=#007AFF"
        echo "-- 📍 Position: ${POS} | size=11 $POS_COLOR"
        if [ -n "$LAST_TIME" ]; then
            echo "-- 🕐 Last change: ${LAST_TIME} | size=10 $GRAY"
        fi
        echo "-- 📊 Transitions: ${TRANSITIONS:-0} | size=11 $GRAY"
        if [ "$TRANSITIONS" = "0" ] || [ "${TRANSITIONS:-0}" -lt 2 ]; then
            echo "-- ℹ️ Intel Mac: static hold (normal) | size=10 $GRAY"
        fi
    fi
fi
echo "-- ─────"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
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
if [ "$HIBERNATE" = "25" ]; then
    echo "-- ✅ Deep Hibernate (RAM→Disk) | size=11 color=#30D158"
elif [ "$HIBERNATE" = "3" ]; then
    echo "-- ⚠️ Safe Sleep (RAM powered) | size=11 color=#FF9500"
else
    echo "-- ℹ️ Hibernatemode: ${HIBERNATE} | size=11 $GRAY"
fi
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
echo "-- 📊 Wake events: ${WAKE_COUNT} | size=11 $GRAY"
echo "-- 🔌 External USB: ${USB_EXT} | size=11 $GRAY"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
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
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
if [ "$PSAVER_STATE" = "ON" ]; then
    echo "-- Disable Power Saver | bash=$DISPATCH param1=power_saver_off terminal=false refresh=true size=12"
else
    echo "-- Enable Power Saver | bash=$DISPATCH param1=power_saver_on terminal=false refresh=true color=#30D158 size=12"
fi
echo "-- Show Full Report | bash=$DISPATCH param1=power_saver_report terminal=false size=12"
echo "-- Save Report to File | bash=$DISPATCH param1=sleep_report_save terminal=false refresh=true size=12"
echo "-- Open Reports Folder | bash=$DISPATCH param1=open_reports terminal=false size=12"

AUTO_STATE=$([ -f "$HOME/.battopt-swiftbar/.auto_cleanup" ] && echo "ON" || echo "OFF")
IDLE=$(ioreg -c IOHIDSystem 2>/dev/null | grep -E "HIDIdleTime" | awk '{print $NF}' | head -1)
IDLE_MIN=$((IDLE / 1000000000 / 60))
[ -z "$IDLE_MIN" ] && IDLE_MIN=0
CLEANUP_DONE=$([ -f "$HOME/.battopt-swiftbar/.pre_sleep_done" ] && echo "YES" || echo "NO")

if [ "$AUTO_STATE" = "ON" ]; then
    echo "Auto Cleanup: ON ▶ | color=#909090"
else
    echo "Auto Cleanup: OFF ▶ | color=#909090"
fi
echo "--    Auto-pauses background services when idle | size=10 $GRAY"
echo "--    (Spotlight, Photos, Time Machine, VLC) | size=10 $GRAY"
echo "-- ℹ️ Trigger: after 15 min idle | size=10 $GRAY"
echo "-- ⏱️ Current idle: ${IDLE_MIN} min | size=11 $GRAY"
echo "-- 📌 Last cleanup: ${CLEANUP_DONE} | size=11 $GRAY"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
echo "-- Run Cleanup Now | bash=$DISPATCH param1=pre_sleep_now terminal=false refresh=true size=12"
echo "--    Pause Spotlight, Photos, Time Machine, VLC now | size=10 $GRAY"
echo "-- Restore Services | bash=$DISPATCH param1=post_wake_now terminal=false refresh=true size=12"
echo "--    Resume all paused services | size=10 $GRAY"
if [ "$AUTO_STATE" = "ON" ]; then
    echo "-- Disable Auto Cleanup | bash=$DISPATCH param1=auto_cleanup_toggle terminal=false refresh=true size=12"
    echo "--    Stop auto-cleanup only (other features keep working) | size=10 $GRAY"
else
    echo "-- Enable Auto Cleanup | bash=$DISPATCH param1=auto_cleanup_toggle terminal=false refresh=true color=#30D158 size=12"
    echo "--    Auto-pause services after 15 min idle | size=10 $GRAY"
fi

echo "Developer Tools ▶ | size=11 color=#007AFF"
echo "-- Project Health Check | bash=$DISPATCH param1=project_health terminal=false refresh=true size=12"
echo "--    Verify all components | size=10 color=#909090 disabled=true"
echo "-- Conflict Detection | bash=$DISPATCH param1=conflict_check terminal=false size=12"
echo "--    Find tools that clash | size=10 color=#909090 disabled=true"
echo "-- Predictive Analysis | bash=$DISPATCH param1=predictive terminal=false size=12"
echo "--    Detect trends before problems | size=10 color=#909090 disabled=true"
echo "-- Process Monitor | bash=$DISPATCH param1=process_monitor terminal=false size=12"
echo "--    Auto-fix process loops | size=10 color=#909090 disabled=true"

echo "Logs ▶ | size=11 color=#007AFF"
echo "-- AI Diagnostic Bundle | bash=$DISPATCH param1=logs_ai_bundle terminal=false refresh=true color=#30D158 size=12"
echo "--    Collects everything for AI analysis | size=10 $GRAY"
echo "-- ─────"
echo "-- Actions Log | bash=$DISPATCH param1=logs_actions terminal=false"
echo "--    Battery control operations | size=10 $GRAY"
echo "-- Sailing History | bash=$DISPATCH param1=logs_sailing terminal=false"
echo "--    Battery transitions | size=10 $GRAY"
echo "-- Arm Log | bash=$DISPATCH param1=logs_arm terminal=false"
echo "--    Pre-sleep preparations | size=10 $GRAY"
echo "-- Daemon Logs | bash=$DISPATCH param1=logs_daemon terminal=false"
echo "--    battopt daemon activity | size=10 $GRAY"
echo "-- Reports Folder | bash=$DISPATCH param1=logs_reports terminal=false"
echo "--    All saved reports | size=10 $GRAY"

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
