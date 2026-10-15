#!/bin/bash
# <xbar.title>BattOpt Control Center</xbar.title>
# <xbar.version>1.3.0</xbar.version>
# <xbar.author>Yousef</xbar.author>
# <xbar.desc>Sailing mode, smart discharge, calibration, clamshell, schedule, proactive notifications.</xbar.desc>
# <xbar.abouturl>https://battopt.buddha-path.top</xbar.abouturl>
# <xbar.dependencies>bash,battopt</xbar.dependencies>

# Exit silently if disabled

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

# ============ PROACTIVE NOTIFICATIONS ============


# === notify_proactive_v2 (v1.5.2) ===
# Rules:
#   1. Max 3 notifications per day (any type)
#   2. Min 30 min between same-type (unless critical)
#   3. Quiet hours 23:00-08:00 (except CRITICAL types)
# CRITICAL = battery_critical, temp_critical, enforce_critical, daemon_recovery
notify_proactive_v2() {
    local key="$1" cooldown="$2" title="$3" msg="$4"
    local NOTIFY_DIR="$HOME/.battopt-swiftbar/.notify"
    mkdir -p "$NOTIFY_DIR"

    local now=$(date +%s)
    local today=$(date +%Y%m%d)
    local hour=$(date +%H)

    local daily_file="$NOTIFY_DIR/.daily_$today"
    local type_file="$NOTIFY_DIR/$key"

    # Classify: CRITICAL bypasses quiet hours + daily cap? NO — max 3/day applies to ALL
    local is_critical=0
    case "$key" in
        battery_critical|temp_critical|enforce_critical|daemon_recovery|hold_reached_*)
            is_critical=1 ;;
    esac

    # Quiet hours check (23:00-08:00) — non-critical silenced
    if [ "$is_critical" = "0" ]; then
        if [ "$hour" -ge 23 ] || [ "$hour" -lt 8 ]; then
            return 0
        fi
    fi

    # Daily cap: max 3 per day (ALL types)
    if [ -f "$daily_file" ]; then
        local count=$(wc -l < "$daily_file" | tr -d ' ')
        if [ "$count" -ge 3 ]; then
            return 0
        fi
    fi

    # Same-type cooldown (non-critical can have 30min minimum)
    if [ "$is_critical" = "0" ] && [ -f "$type_file" ]; then
        local last=$(cat "$type_file" 2>/dev/null || echo 0)
        local diff=$((now - last))
        [ "$diff" -lt 1800 ] && return 0
    fi

    # Critical types still have a 30-min floor (avoid spam)
    if [ "$is_critical" = "1" ] && [ -f "$type_file" ]; then
        local last=$(cat "$type_file" 2>/dev/null || echo 0)
        local diff=$((now - last))
        [ "$diff" -lt 1800 ] && return 0
    fi

    # v1 cooldown check (custom cooldown per type)
    if [ -f "$type_file" ]; then
        local last=$(cat "$type_file" 2>/dev/null || echo 0)
        local diff=$((now - last))
        [ "$diff" -lt "$cooldown" ] && return 0
    fi

    # Record + send
    echo "$now" > "$type_file"
    echo "$key" >> "$daily_file"

    local NOTIFIER="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
    if [ -x "$NOTIFIER" ]; then
        "$NOTIFIER" -title "BattOpt" -subtitle "$title" -message "$msg" -appIcon "$BATTOPT_ICON" -contentImage "$BATTOPT_ICON" -group "battopt-$key" -sound default 2>/dev/null
    else
        osascript -e "display notification \"$msg\" with title \"$title\"" 2>/dev/null
    fi
}

# End v1.5.2

# ============ AUTO RECOVERY ============
if [ -z "$SNAP" ] || echo "$SNAP" | grep -q "Timeout\|not running"; then
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
# Robust temperature extraction (multi-pattern)
TEMP=$(echo "$SNAP" | grep -oE '[0-9]+\.[0-9]+°C' | head -1 | sed 's/°C//')
[ -z "$TEMP" ] && TEMP=$(echo "$SNAP" | grep 'Capacity' | head -1 | grep -oE '[0-9]+\.[0-9]+°C' | head -1 | sed 's/°C//')
[ -z "$TEMP" ] && TEMP=$(echo "$SNAP" | grep 'Capacity' | head -1 | awk -F',' '{print $3}' | grep -oE '[0-9]+\.[0-9]+' | head -1)
[ -z "$TEMP" ] && TEMP=""
TRIAL=$(echo "$SNAP" | grep -oE "expire in [0-9]+ days" | grep -oE "[0-9]+")

TEMP_INT=${TEMP%.*}
HEALTH_INT=${HEALTH%.*}
# Temperature color driven by APG state (temp + load combined)
APG_STATE=$(cat "$HOME/.battopt-swiftbar/.apg_state" 2>/dev/null || echo "green")
case "$APG_STATE" in
    red)    TEMP_COLOR="color=#FF3B30" ;;
    yellow) TEMP_COLOR="color=#FF9500" ;;
    *)      TEMP_COLOR="color=#34C759" ;;
esac
[ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 40 ] && TEMP_COLOR="color=orange"
[ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 45 ] && TEMP_COLOR="color=red"

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

# Smart Discharge completion detection
SD_STATE="$HOME/.battopt-swiftbar/.sd_watch"
if [ -f "$SD_STATE" ]; then
    SD_TARGET=$(cat "$SD_STATE" 2>/dev/null)
    if [ -n "$PCT" ] && [ -n "$SD_TARGET" ] && [ "$PCT" -le "$SD_TARGET" ]; then
        notify_proactive_v2 "sd_complete" 1800 "Smart Discharge" "Reached target ${SD_TARGET}%"
        rm -f "$SD_STATE"
    fi
fi

# ============ LOW BATTERY ON BATTERY POWER ============
if echo "$SNAP" | grep -q ", discharging"; then
    if [ -n "$PCT" ] && [ "$PCT" -le 61 ] && [ "$PCT" -gt 20 ]; then
        : # REMOVED v1.5.2 (noise) battery_low_warning
    fi
    if [ -n "$PCT" ] && [ "$PCT" -le 20 ]; then
        notify_proactive_v2 "battery_critical" 900 "🔴 Battery Critical" "Battery at ${PCT}% - plug in charger immediately"
    fi
fi

# ============ TEMP_LOAD_CHECK ============
# Warn if temperature is high AND battery exceeds limit
if [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 40 ]; then
    if [ -n "$PCT" ] && [ -n "$UPPER" ] && [ "$PCT" -gt "$UPPER" ]; then
        notify_proactive_v2 "load_heat_override" 600 "⚠️ Load + Heat" "Battery ${PCT}% > limit ${UPPER}% with temp ${TEMP}C — check for macOS override"
    fi
fi

# ============ TEMPERATURE GUARD ============
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

# ============ PROCESS DETECTION ============
PROC_D=$(pgrep -f "/usr/local/bin/battopt discharge" 2>/dev/null | wc -l | tr -d ' ')
PROC_C=$(pgrep -f "/usr/local/bin/battopt calibrate" 2>/dev/null | wc -l | tr -d ' ')
PROC_CH=$(pgrep -f "battopt charge " 2>/dev/null | wc -l | tr -d ' ')

# === ICON: Direct signal from SMC (no cache dependency) ===
# Get fresh charging state from SMC directly
# === SINGLE ioreg call — SMC truth (Stage 11) ===
IOREG_DATA=$(ioreg -rn AppleSmartBattery 2>/dev/null)
ICON_ISCHG=$(echo "$IOREG_DATA" | grep -oE '"IsCharging" = [A-Za-z]+' | awk '{print $3}')
ICON_EXT=$(echo "$IOREG_DATA" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
ICON_CHCUR=$(echo "$IOREG_DATA" | grep -oE '"ChargingCurrent"=[0-9]+' | grep -oE '[0-9]+' | head -1)
ICON_NCR=$(echo "$IOREG_DATA" | grep -oE '"NotChargingReason"=[0-9]+' | grep -oE '[0-9]+' | head -1)
ICON_CURCAP=$(echo "$IOREG_DATA" | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
ICON_MAXCAP=$(echo "$IOREG_DATA" | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')
[ -z "$ICON_CHCUR" ] && ICON_CHCUR=0
[ -z "$ICON_NCR" ] && ICON_NCR=0

# === Icon priority (Layer 18c — active_mode aware) ===
# Read active_mode directly (before it's read at line ~424)
ICON_ACTIVE=$(cat "$HOME/.battopt-swiftbar/.active_mode" 2>/dev/null || echo "idle")

PROC_D_NOW=$(pgrep -f "battopt discharge" 2>/dev/null | wc -l | tr -d ' ')
PROC_CH_NOW=$(pgrep -f "battopt charge " 2>/dev/null | wc -l | tr -d ' ')
PROC_CAL_NOW=$(pgrep -f "battopt calibrate" 2>/dev/null | wc -l | tr -d ' ')

if [ "$PROC_D_NOW" -gt 0 ] || [ "$ICON_ACTIVE" = "discharge" ]; then
    ICON="🔋"
elif [ "$PROC_CAL_NOW" -gt 0 ] || [ "$ICON_ACTIVE" = "calibration" ]; then
    ICON="⚡"
elif [ "$PROC_CH_NOW" -gt 0 ] || [ "$ICON_ACTIVE" = "charge_full" ]; then
    ICON="⚡"
elif [ "$ICON_ISCHG" = "Yes" ] && [ "$ICON_CHCUR" -gt 50 ] 2>/dev/null; then
    ICON="⚡"
elif [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
    ICON="🔌"
else
    ICON="🔴"
fi
# SMC-true percentage (raw, not from cache)
if [ -n "$ICON_CURCAP" ] && [ -n "$ICON_MAXCAP" ] && [ "$ICON_MAXCAP" -gt 0 ] 2>/dev/null; then
    SMC_PCT=$(( (ICON_CURCAP * 100 + ICON_MAXCAP / 2) / ICON_MAXCAP ))
else
    SMC_PCT="?"
fi


# === MODE text ===
if [ "$PROC_C" -gt 0 ]; then
    MODE="Calibrating"
elif [ "$PROC_D" -gt 0 ]; then
    MODE="Discharging to ${LAST_UPPER}%"
elif [ "$PROC_CH" -gt 0 ]; then
    MODE="Charging to 100%"
elif echo "$SNAP" | grep -q ", charging"; then
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

STATE=$(echo "$SNAP" | grep -oE ', (charging|discharging|no charging)' | head -1 | sed 's/^, //')

# === HOLD REACHED NOTIFICATION (Layer 18d — precise) ===
PROC_D_NOTIF=$(pgrep -f "battopt discharge" 2>/dev/null | wc -l | tr -d ' ')
if [ "$PROC_D_NOTIF" = "0" ] && echo "$MODE" | grep -qE "^Holding at [0-9]+%$"; then
    HOLD_PCT=$(echo "$MODE" | grep -oE '[0-9]+' | head -1)
    if [ -n "$PCT" ] && [ -n "$HOLD_PCT" ]; then
        DIFF=$((PCT - HOLD_PCT))
        [ "$DIFF" -lt 0 ] && DIFF=$((-DIFF))
        if [ "$DIFF" -le 1 ]; then
            notify_proactive_v2 "hold_reached" 3600 \
                "Battery at Limit" \
                "Holding at ${HOLD_PCT}% — charge limit enforced"
        fi
    fi
fi
# === END HOLD NOTIFICATION ===

STUCK=""
echo "$SNAP" | grep -qE "Error:.*ongoing" && STUCK="yes"

CLAM=$(cat "$CFG" 2>/dev/null | grep "^clamshell" | grep -oE "[0-9]+" | head -1)
[ -z "$CLAM" ] && CLAM=0
SCHED=$(cat "$CFG" 2>/dev/null | grep "^schedule.enable" | grep -oE "[0-9]+" | head -1)
[ -z "$SCHED" ] && SCHED=0

# ============ MENU ============
# === TEMPERATURE COLOR (Stage 21) ===
TEMP_COLOR=""
if [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 42 ] 2>/dev/null; then
    TEMP_COLOR="color=#FF3B30"
elif [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 38 ] 2>/dev/null; then
    TEMP_COLOR="color=#FF9500"
fi
# === UNIFIED ALERT COLOR (Stage 26) ===
if [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 42 ] 2>/dev/null; then
    ALERT_COLOR="color=#FF3B30"
elif [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 38 ] 2>/dev/null; then
    ALERT_COLOR="color=#FF9500"
else
    ALERT_COLOR=""
fi

# === STATE-BASED COLOR v3 (Stage 27c) ===
# Charging:    very dim gray (almost invisible)
# Holding:     full white (clear, complete)
# On battery:  washed-out pink-red (soft, non-alarming)
#
# Temperature ALWAYS overrides.
#
# Palette:
#   Charging   = #707070  (dim gray)
#   Holding    = #FFFFFF  (full white)
#   Battery    = #E8A0A0  (washed red — soft)
#   Temp warn  = #FF9500  (orange, 38-41°C)
#   Temp hot   = #FF3B30  (bright red, >=42°C)

# Base state color
if [ "$ICON_ISCHG" = "Yes" ] && [ "$ICON_CHCUR" -gt 50 ] 2>/dev/null; then
    STATE_COLOR="color=#707070"
elif [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
    STATE_COLOR="color=#FFFFFF"
else
    STATE_COLOR="color=#E8A0A0"
fi

# Temperature overrides state color
if [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 42 ] 2>/dev/null; then
    FINAL_COLOR="color=#FF3B30"
elif [ -n "$TEMP_INT" ] && [ "$TEMP_INT" -ge 38 ] 2>/dev/null; then
    FINAL_COLOR="color=#FF9500"
else
    FINAL_COLOR="$STATE_COLOR"
fi

echo "${ICON} ${SMC_PCT}% | size=14 ${FINAL_COLOR}"
# === END TEMPERATURE COLOR ===
echo "---"

echo "Charge: ${PCT}% | size=11"
echo "Mode: ${MODE} | size=11"
if [ "$SAILING" = "true" ] && [ -n "$UPPER" ] && [ -n "$LOWER" ]; then
    echo "Sailing · ${LOWER}-${UPPER}% | size=10 color=#909090"
fi
echo "Health: ${HEALTH}% - ${CYCLES} cycles | size=11 $GRAY"
if [ -n "$UPPER" ] && [ -n "$LOWER" ]; then
    echo "Active Limit: ${UPPER}% / ${LOWER}% | size=11 $GRAY"
else
    echo "Active Limit: disabled | size=11 $GRAY"
fi
[ -n "$TEMP" ] && echo "Temperature: ${TEMP}°C | size=11 ${ALERT_COLOR:-color=#909090}"
[ -n "$TRIAL" ] && echo "Trial: ${TRIAL} days | size=11 color=orange"
echo "---"

# === POWER MODE: قراءة القيم من Battery Power ===
# Layer 15: single pmset call + bash parsing (no forks)
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
    # Parse key value
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
[ -z "$AC_SLEEP" ] && AC_SLEEP="?"
[ -z "$SLEEP_VAL" ] && SLEEP_VAL="?"
[ -z "$DISPLAY_VAL" ] && DISPLAY_VAL="?"
[ -z "$DISK_VAL" ] && DISK_VAL="?"
[ -z "$AC_SLEEP" ] && AC_SLEEP="?"

# === تحديد الوضع الحالي (POWER_MODE منفصل عن MODE العلوي) ===
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

# === علامات الاختيار ===
M_FAST=" "; M_BAL=" "; M_AWK=" "; M_DP=" "; M_CUS=" "
case "$MODE_KEY" in
    fast)     M_FAST="✓" ;;
    balanced) M_BAL="✓" ;;
    awake)    M_AWK="✓" ;;
    deep)     M_DP="✓" ;;
    custom)   M_CUS="✓" ;;
esac

# === حالة Stay Awake ===

echo "Quick Actions | size=11 color=#007AFF disabled=true"
echo "Power Mode — ${POWER_MODE} | size=14 color=#FFFFFF"
echo "-- ${M_FAST}Fast Sleep · 5/5/15 · office | bash=$DISPATCH param1=power_mode_fast terminal=false refresh=true size=12"
echo "-- ${M_BAL}Balanced · 18/10/15 · daily | bash=$DISPATCH param1=power_mode_balanced terminal=false refresh=true size=12"
echo "-- ${M_AWK}Always Awake · AC only · presentations | bash=$DISPATCH param1=power_mode_awake terminal=false refresh=true size=12"
echo "-- ${M_DP}Deep Only · immediate · travel | bash=$DISPATCH param1=power_mode_deep terminal=false refresh=true size=12"
echo "-- ${M_CUS}Set Custom Values… | bash=$DISPATCH param1=power_mode_custom terminal=false refresh=true size=12"
echo "-- Active: Bat ${SLEEP_VAL}/${DISPLAY_VAL}/${DISK_VAL}m · AC ${AC_SLEEP}m | size=10 color=#505050 disabled=true"
echo "-- Usage: ${USE_WHEN} | size=10 color=#505050 disabled=true"
# === SLEEP MODE SUBMENU ===
SM_STATE=$(cat "$HOME/.battopt-swiftbar/.sleep_mode" 2>/dev/null || echo "default")
case "$SM_STATE" in
    presentation) SM_TITLE="Presentation" ;;
    download)     SM_TITLE="Long Tasks" ;;
    travel)       SM_TITLE="Travel" ;;
    *)            SM_TITLE="Normal" ;;
esac

SM_DEF_MARK=" "; SM_PRE_MARK=" "; SM_LT_MARK=" "; SM_TRV_MARK=" "
SM_DEF_COLOR="color=#A8A8A8"
SM_PRE_COLOR="color=#A8A8A8"
SM_LT_COLOR="color=#A8A8A8"
SM_TRV_COLOR="color=#A8A8A8"

case "$SM_STATE" in
    default)      SM_DEF_MARK="✓"; SM_DEF_COLOR="color=#34C759" ;;
    presentation) SM_PRE_MARK="✓"; SM_PRE_COLOR="color=#34C759" ;;
    download)     SM_LT_MARK="✓";  SM_LT_COLOR="color=#34C759" ;;
    travel)       SM_TRV_MARK="✓"; SM_TRV_COLOR="color=#34C759" ;;
esac

echo "Sleep Mode — ${SM_TITLE} | size=14 color=#007AFF"
echo "-- ${SM_DEF_MARK} Normal · macOS handles sleep | bash=$DISPATCH param1=sleep_mode_default terminal=false refresh=true size=12 ${SM_DEF_COLOR}"
echo "-- ${SM_PRE_MARK} Presentation · never sleeps on AC | bash=$DISPATCH param1=sleep_mode_presentation terminal=false refresh=true size=12 ${SM_PRE_COLOR}"
echo "-- ${SM_LT_MARK} Long Tasks · lid closed, AC required | bash=$DISPATCH param1=sleep_mode_download terminal=false refresh=true size=12 ${SM_LT_COLOR}"
echo "-- ${SM_TRV_MARK} Travel · battery holds longer (4h) | bash=$DISPATCH param1=sleep_mode_travel terminal=false refresh=true size=12 ${SM_TRV_COLOR}"
echo "-- Prepare for Sleep · closes audio apps | bash=$DISPATCH param1=arm_sleep terminal=false refresh=true size=12 color=#007AFF"
# === SLEEP OVERRIDES ===
ACTIVE_MODE=$(cat "$HOME/.battopt-swiftbar/.active_mode" 2>/dev/null || echo "idle")
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
    echo "★ ✓ Smart Discharge... | bash=$DISPATCH param1=force_reset terminal=false refresh=true $ORANGE"
    echo "↳ Kill Discharge (only) | bash=$DISPATCH param1=kill_discharge terminal=false refresh=true $GRAY"
elif [ "$PROC_D" -gt 0 ]; then
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
echo "Reset to Defaults | bash=$DISPATCH param1=reset_defaults terminal=false refresh=true $GRAY"
echo "---"

echo "Charge Limits | size=11 color=#007AFF disabled=true"

# Custom Limit — saved values (no arrow)
if [ "$ACTIVE_MODE" = "idle" ]; then
    echo "✓ Custom Limit — ${UPPER}% / ${LOWER}% | bash=$DISPATCH param1=limit_custom terminal=false refresh=true"
else
    echo "Custom Limit — ${UPPER}% / ${LOWER}% | bash=$DISPATCH param1=limit_custom terminal=false refresh=true"
fi

# Determine current hold mode
if [ "$SAILING" = "true" ]; then
    HMODE_TITLE="Sailing ${LOWER}-${UPPER}%"
    RADIO_SAIL="true"
    RADIO_STATIC="false"
else
    HMODE_TITLE="Static at ${UPPER}%"
    RADIO_SAIL="false"
    RADIO_STATIC="true"
fi

# Hold Mode — header with submenu
echo "Hold Mode — ${HMODE_TITLE} | size=13 color=#FFFFFF"
echo "-- How battery is held: | size=10 color=#505050 disabled=true"
echo "-- With Sailing — battery oscillates ${LOWER}-${UPPER}% | bash=$DISPATCH param1=sail_on terminal=false refresh=true checked=${RADIO_SAIL} size=12"
echo "-- Static Hold — battery frozen at ${UPPER}% | bash=$DISPATCH param1=sail_off terminal=false refresh=true checked=${RADIO_STATIC} size=12"
echo "-- ---"
echo "-- Gap: 5% | bash=$DISPATCH param1=sail_gap_set param2=5 terminal=false refresh=true checked=$([ "$SAIL_GAP" = "5" ] && echo true || echo false) size=12"
echo "-- Gap: 10% | bash=$DISPATCH param1=sail_gap_set param2=10 terminal=false refresh=true checked=$([ "$SAIL_GAP" = "10" ] && echo true || echo false) size=12"
echo "-- Gap: 15% | bash=$DISPATCH param1=sail_gap_set param2=15 terminal=false refresh=true checked=$([ "$SAIL_GAP" = "15" ] && echo true || echo false) size=12"
echo "-- Gap: 30% | bash=$DISPATCH param1=sail_gap_set param2=30 terminal=false refresh=true checked=$([ "$SAIL_GAP" = "30" ] && echo true || echo false) size=12"
case "$SAIL_GAP" in
    5|10|15|30)
        echo "-- Gap: Custom... | bash=$DISPATCH param1=sail_gap_set param2=custom terminal=false refresh=true checked=false size=12"
        ;;
    *)
        echo "-- Gap: Custom (${SAIL_GAP}%)... | bash=$DISPATCH param1=sail_gap_set param2=custom terminal=false refresh=true checked=true size=12"
        ;;
esac

# Main-level actions
echo "Remove Limit (hold at current) | bash=$DISPATCH param1=remove_limit_hold terminal=false refresh=true"
echo "Disable All Limits (charge to 100%) | bash=$DISPATCH param1=disable_limit terminal=false refresh=true color=#909090"

echo "---"
echo "Battery Care | size=11 color=#007AFF disabled=true"
CAL_RUNNING=$([ "$PROC_C" -gt 0 ] && echo " · running" || echo "")
echo "Calibration${CAL_RUNNING} | size=14 color=#FFFFFF"
echo "-- Full cycle (15% → 100%) to fix inaccurate % | size=10 color=#909090 disabled=true"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
echo "-- Start Calibration | bash=$DISPATCH param1=calibrate terminal=false refresh=true size=12"
echo "-- Runs a full discharge then charge cycle. | size=9 color=#909090 disabled=true"
echo "-- Takes several hours. | size=9 color=#909090 disabled=true"
echo "-- Stop Calibration (API) | bash=$DISPATCH param1=cal_stop terminal=false refresh=true size=12"
echo "-- Gracefully stops an active calibration. | size=9 color=#909090 disabled=true"
if [ "$PROC_C" -gt 0 ]; then
    echo "-- Force Stop Calibration | bash=$DISPATCH param1=kill_calibrate terminal=false refresh=true size=12"
    echo "-- Immediately kills calibration if it is stuck. | size=9 color=#909090 disabled=true"
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

# === USB COUNT CACHE (5 min TTL) ===
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

# === WAKE_COUNT CACHE (10 min TTL) ===
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
    echo "💤 Sleep Report: OPTIMIZED | color=#30D158"
else
    echo "💤 Sleep Report: STANDARD | color=#FF9500"
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

# ============ SAILING TRACKER ============
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
        
        # Intel reality check
        if [ "$TRANSITIONS" = "0" ] || [ "${TRANSITIONS:-0}" -lt 2 ]; then
            echo "-- ℹ️ Intel Mac: static hold (normal) | size=10 $GRAY"
        fi
    fi
fi
echo "-- ─────"
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
if [ "$HIBERNATE" = "25" ]; then
    echo "-- ✅ Deep Hibernate (RAM→Disk) | size=11 color=#30D158"
elif [ "$HIBERNATE" = "3" ]; then
    echo "-- ⚠️ Safe Sleep (RAM powered) | size=11 color=#FF9500"
else
    echo "-- ℹ️ Hibernatemode: ${HIBERNATE} | size=11 $GRAY"
fi
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

# ============ AUTO CLEANUP SECTION ============
AUTO_STATE=$([ -f "$HOME/.battopt-swiftbar/.auto_cleanup" ] && echo "ON" || echo "OFF")
IDLE=$(ioreg -c IOHIDSystem 2>/dev/null | grep -E "HIDIdleTime" | awk '{print $NF}' | head -1)
IDLE_MIN=$((IDLE / 1000000000 / 60))
[ -z "$IDLE_MIN" ] && IDLE_MIN=0
CLEANUP_DONE=$([ -f "$HOME/.battopt-swiftbar/.pre_sleep_done" ] && echo "YES" || echo "NO")

if [ "$AUTO_STATE" = "ON" ]; then
    echo "🧹 Auto Cleanup: ON ▶ | color=#30D158"
else
    echo "🧹 Auto Cleanup: OFF ▶ | color=#909090"
fi
echo "--    Auto-pauses background services when idle | size=10 $GRAY"
echo "--    (Spotlight, Photos, Time Machine, VLC) | size=10 $GRAY"

echo "-- ⚙️ Services paused: Spotlight, Photos, TM, VLC | size=10 $GRAY"
echo "-- ℹ️ Trigger: after 15 min idle | size=10 $GRAY"
echo "-- ⏱️ Current idle: ${IDLE_MIN} min | size=11 $GRAY"
echo "-- 📌 Last cleanup: ${CLEANUP_DONE} | size=11 $GRAY"
echo "-- ---"
echo "-- 🧹 Run Cleanup Now | bash=$DISPATCH param1=pre_sleep_now terminal=false refresh=true"
echo "--    Pause Spotlight, Photos, Time Machine, VLC now | size=10 $GRAY"
echo "-- 🔄 Restore Services | bash=$DISPATCH param1=post_wake_now terminal=false refresh=true"
echo "--    Resume all paused services | size=10 $GRAY"
if [ "$AUTO_STATE" = "ON" ]; then
    echo "-- ⏸️ Disable Auto Cleanup | bash=$DISPATCH param1=auto_cleanup_toggle terminal=false refresh=true"
    echo "--    Stop auto-cleanup only (other features keep working) | size=10 $GRAY"
else
    echo "-- ▶️ Enable Auto Cleanup | bash=$DISPATCH param1=auto_cleanup_toggle terminal=false refresh=true color=#30D158"
    echo "--    Auto-pause services after 15 min idle | size=10 $GRAY"
fi

# ============ SYSTEM RESOURCES ============
# ============ DEVELOPER TOOLS SECTION ============
echo "🔧 Developer Tools ▶ | size=11 color=#007AFF"
echo "-- 🩺 Project Health Check | bash=$DISPATCH param1=project_health terminal=false refresh=true"
echo "--    Verify all components | size=10 color=#909090 disabled=true"
echo "-- 🔀 Conflict Detection | bash=$DISPATCH param1=conflict_check terminal=false"
echo "--    Find tools that clash | size=10 color=#909090 disabled=true"
echo "-- 🔮 Predictive Analysis | bash=$DISPATCH param1=predictive terminal=false"
echo "--    Detect trends before problems | size=10 color=#909090 disabled=true"
echo "-- 🔍 Process Monitor | bash=$DISPATCH param1=process_monitor terminal=false"
echo "--    Auto-fix process loops | size=10 color=#909090 disabled=true"

# ============ LOGS SECTION ============
echo "📋 Logs ▶ | size=11 color=#007AFF"
echo "-- 📄 AI Diagnostic Bundle | bash=$DISPATCH param1=logs_ai_bundle terminal=false refresh=true color=#30D158"
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
echo "Shut Down BattOpt... | bash=$DISPATCH param1=shutdown terminal=false refresh=true color=red"
