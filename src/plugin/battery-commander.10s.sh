#!/bin/bash
# <xbar.title>Battery Commander (BC) Control Center</xbar.title>
# <xbar.version>2.0.0</xbar.version>
# <xbar.author>Yousef</xbar.author>
# <xbar.desc>Battery Commander (BC) — independent charge-limit control. Sailing mode, power/sleep modes, reports.</xbar.desc>
# <xbar.dependencies>bash,bc-status</xbar.dependencies>
#
# Battery Commander (BC) plugin v2.0.0 — SwiftBar menu.
# Independent replacement for the closed-source battopt tool.
#
# Status path (W2): bc-status (extended: BCLM + Backend) + ioreg + canonical
# config. No sudo, no battopt binary, no free-text parsing, no eval.
#   % / Health / Cycle / Temp / BCLM / Backend — bc-status ("Key: value").
#   IsCharging / ExternalConnected / CurrentCapacity / MaxCapacity /
#   NotChargingReason / ChargingCurrent — ioreg (AppleSmartBattery).
#   Limits (upper/lower) — canonical config ($DASH/config, KEY=value).
# Hold state is authoritative from BCLM=10 (BCLM is the hold-state indicator,
# NOT the limit % — the limit % lives only in config, never in SMC).
# NCR=14 is kept only as a secondary hint when BCLM is unavailable.
#
# State dir: $DASH is defined once at the top. It is still
# $HOME/.battery-commander (the live dir since the W6.3 migration);
# $HOME/.battery-commander/ as a single-pass migration (W1 deferred the
# rename the same way so dispatch/plugin/guardian never split).
# Menu items and param1 names are unchanged (the buttons are the same);
# only the backend changed (dispatch.sh + bc-limit instead of battopt).
# Trial/licence UI is dropped entirely — BC has no trial code.
# Clamshell + schedule are unsupported in BC (dispatch stubs them).

# BC state dir: ~/.battery-commander/ is the ONLY live state dir
# (consolidation 2026-11-13, M2: the old-dir fallback is retired — the
# pre-migration dir is a kept, inert backup, never a live target).
# BC_DASH overrides (tests / dry-runs).
if [ -n "${BC_DASH:-}" ]; then
    DASH="$BC_DASH"
elif [ -d "$HOME/.battery-commander" ]; then
    DASH="$HOME/.battery-commander"
else
    echo "⚠️ Battery Commander: state dir missing — ~/.battery-commander"
    echo "---"
    echo "State dir ~/.battery-commander not found — Battery Commander cannot run. | color=red"
    exit 0
fi
source "$DASH/state_guard.sh" 2>/dev/null
ACTIVE_MODE=$(read_effective_session 2>/dev/null)
[ -z "$ACTIVE_MODE" ] && ACTIVE_MODE="idle"

# BC binary (same resolution as dispatch.sh, W1). BC_BUILD_DIR can be
# overridden in the environment (e.g. for testing). The plugin uses only
# bc-status; the enforcer (bc-limit) and bc-candidates are dispatch's.
BC_BUILD_DIR="${BC_BUILD_DIR:-$HOME/Projects/BattOpt-CC-Release/battopt-project/bc-build}"
BC_STATUS="$BC_BUILD_DIR/bc-status"

DISPATCH="$DASH/dispatch.sh"
MYCFG="$DASH/config"
NOTIFY_DIR="$DASH/.notify"
FAIL_FILE="$DASH/.daemon_fail_count"
TERMINAL_NOTIFIER="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
BC_ICON="$DASH/icons/battery-commander.png"

mkdir -p "$NOTIFY_DIR"

# _atomic_write <file> <content> — write via tmp+mv (never a partial file).
# Used for every single-value state file this plugin writes (cache, counters,
# flags). No flock: SwiftBar runs this plugin serially (10 s cadence).
_atomic_write() {
    printf '%s\n' "$2" > "$1.tmp.$$" 2>/dev/null && mv "$1.tmp.$$" "$1" 2>/dev/null
}

# _bc_value <Key> <text> — print the value for Key from "Key: value" text
# (bc-status format, units included, e.g. "Capacity: 85.9%").
# Returns 1 if the key is absent. Allow-list is enforced by the caller
# (only the keys named below are ever read).
_bc_value() {
    local _key="$1" _text="$2" _line
    _line=$(printf '%s\n' "$_text" | grep "^${_key}:" | head -1)
    [ -n "$_line" ] || return 1
    printf '%s' "${_line#*: }" | tr -d '[:space:]'
}

# _bc_parse_config — read the canonical config as KEY=value (allow-list).
# Never `source` a data file. Canonical defaults (86/85, SAILING=false,
# SAIL_GAP=1) apply only when the file is absent; a present file wins.
# A stale 85/80 or 80/75 default must never be written here.
_bc_parse_config() {
    LAST_UPPER=86; LAST_LOWER=85; SAILING=false; SAIL_GAP=1
    [ -f "$MYCFG" ] || return 0
    local _k _v
    while IFS='=' read -r _k _v; do
        case "$_k" in
            LAST_UPPER) LAST_UPPER="$_v" ;;
            LAST_LOWER) LAST_LOWER="$_v" ;;
            SAILING) SAILING="$_v" ;;
            SAIL_GAP) SAIL_GAP="$_v" ;;
        esac
    done < "$MYCFG"
    case "$LAST_UPPER" in ''|*[!0-9]*) LAST_UPPER=86 ;; esac
    case "$LAST_LOWER" in ''|*[!0-9]*) LAST_LOWER=85 ;; esac
}
_bc_parse_config

# === notify_proactive_v2 (v1.5.2) ===
notify_proactive_v2() {
    local key="$1" cooldown="$2" title="$3" msg="$4"
    local NOTIFY_DIR="$DASH/.notify"
    mkdir -p "$NOTIFY_DIR"
    # Prune old daily counters (one file per day would accumulate forever).
    find "$NOTIFY_DIR" -name '.daily_*' -mtime +2 -delete 2>/dev/null || true
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
    if [ "$is_critical" = "1" ]; then
        local last=$(cat "$type_file" 2>/dev/null || echo 0)
        local diff=$((now - last))
        [ "$diff" -lt "$cooldown" ] && return 0
    fi
    local NOTIFIER="$TERMINAL_NOTIFIER"
    if [ -x "$NOTIFIER" ]; then
        "$NOTIFIER" -title "Battery Commander (BC)" -subtitle "$title" -message "$msg" -appIcon "$BC_ICON" -contentImage "$BC_ICON" -group "battery-commander-$key" -sound default 2>/dev/null
    else
        osascript -e "display notification \"$msg\" with title \"$title\"" 2>/dev/null
    fi
    echo "$now" >> "$daily_file" 2>/dev/null
    _atomic_write "$type_file" "$now"
}

# === STATUS CACHE (20s TTL) ===
NOW_TS=$(date +%s)
STATUS_CACHE="$DASH/.status_cache"
CACHE_TTL=20
if [ -f "$STATUS_CACHE" ]; then
    CACHE_AGE=$((NOW_TS - $(stat -f %m "$STATUS_CACHE" 2>/dev/null || echo 0)))
else
    CACHE_AGE=9999
fi

# BC_OUT is the bc-status output (one run, parsed below). The cache holds
# that output; a fresh cache avoids re-running bc-status every render.
BC_OUT=""
BC_STATUS_OK=0
if [ "$CACHE_AGE" -lt "$CACHE_TTL" ]; then
    BC_OUT=$(cat "$STATUS_CACHE" 2>/dev/null)
    [ -n "$BC_OUT" ] && BC_STATUS_OK=1
fi
if [ "$BC_STATUS_OK" != "1" ]; then
    if [ -x "$BC_STATUS" ]; then
        BC_OUT=$("$BC_STATUS" 2>/dev/null) || BC_OUT=""
    fi
    if [ -n "$BC_OUT" ]; then
        BC_STATUS_OK=1
        _atomic_write "$STATUS_CACHE" "$BC_OUT"
    fi
fi

# Parse bc-status fields (allow-list). A missing key leaves the variable
# empty — never invent a default; the display shows "?" for it.
PCT=""; HEALTH=""; CYCLES=""; TEMP=""; TEMP_CPU=""; BCLM=""; BACKEND=""
if [ "$BC_STATUS_OK" = "1" ]; then
    _v=$(_bc_value Capacity "$BC_OUT" 2>/dev/null) || _v=""
    _v=${_v%\%}; PCT=${_v%%.*}
    _v=$(_bc_value Health "$BC_OUT" 2>/dev/null) || _v=""
    _v=${_v%\%}; HEALTH=${_v%%.*}
    CYCLES=$(_bc_value Cycle "$BC_OUT" 2>/dev/null) || CYCLES=""
    _v=$(_bc_value TempBatteryPack "$BC_OUT" 2>/dev/null) || _v=""
    _v=${_v%C}; TEMP=${_v%%.*}
    _v=$(_bc_value TempCPU "$BC_OUT" 2>/dev/null) || _v=""
    _v=${_v%C}; TEMP_CPU=${_v%%.*}
    BCLM=$(_bc_value BCLM "$BC_OUT" 2>/dev/null) || BCLM=""
    BACKEND=$(_bc_value Backend "$BC_OUT" 2>/dev/null) || BACKEND=""
    # Numeric guard: a non-numeric field is treated as absent.
    case "$PCT" in ''|*[!0-9]*) PCT="" ;; esac
    case "$HEALTH" in ''|*[!0-9]*) HEALTH="" ;; esac
    case "$CYCLES" in ''|*[!0-9]*) CYCLES="" ;; esac
    case "$TEMP" in ''|*[!0-9]*) TEMP="" ;; esac
    case "$TEMP_CPU" in ''|*[!0-9]*) TEMP_CPU="" ;; esac
    case "$BCLM" in 10|100) ;; *) BCLM="" ;; esac
fi
UPPER="$LAST_UPPER"
LOWER="$LAST_LOWER"
TEMP_INT=${TEMP%.*}
HEALTH_INT=${HEALTH%.*}
GRAY="color=#909090"
ORANGE="color=#FF9500"

# ============ AUTO RECOVERY (BC) ============
# Distinguish "no data yet" (transient — wait) from "status down"
# (persistent — log + notify). Never auto-reset, never call force_reset:
# the BC enforcer is the root LaunchDaemon (loaded only in Phase C) and
# must not be restarted by the UI.
if [ -f "$DASH/.user_shutdown" ]; then
    _atomic_write "$FAIL_FILE" "0"
elif [ "$BC_STATUS_OK" != "1" ]; then
    FAILS=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
    case "$FAILS" in ''|*[!0-9]*) FAILS=0 ;; esac
    FAILS=$((FAILS + 1))
    _atomic_write "$FAIL_FILE" "$FAILS"
    if [ "$FAILS" -ge 3 ]; then
        notify_proactive_v2 "daemon_recovery" 600 "Battery Commander (BC)" "Status unavailable — bc-status not responding"
        _atomic_write "$FAIL_FILE" "0"
    fi
else
    _atomic_write "$FAIL_FILE" "0"
fi

# ============ IOREG (hardware truth) ============
IOREG_DATA=$(ioreg -rn AppleSmartBattery 2>/dev/null)
ICON_ISCHG=$(echo "$IOREG_DATA" | grep -oE '"IsCharging" = [A-Za-z]+' | awk '{print $3}')
ICON_EXT=$(echo "$IOREG_DATA" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
ICON_CHCUR=$(echo "$IOREG_DATA" | grep -oE '"ChargingCurrent"=[0-9]+' | grep -oE '[0-9]+' | head -1)
ICON_NCR=$(echo "$IOREG_DATA" | grep -oE '"NotChargingReason"=[0-9]+' | grep -oE '[0-9]+' | head -1)
ICON_CURCAP=$(echo "$IOREG_DATA" | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
ICON_MAXCAP=$(echo "$IOREG_DATA" | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')
[ -z "$ICON_CHCUR" ] && ICON_CHCUR=0
[ -z "$ICON_NCR" ] && ICON_NCR=0

if [ -n "$ICON_CURCAP" ] && [ -n "$ICON_MAXCAP" ] && [ "$ICON_MAXCAP" -gt 0 ] 2>/dev/null; then
    SMC_PCT=$(( (ICON_CURCAP * 100 + ICON_MAXCAP / 2) / ICON_MAXCAP ))
else
    SMC_PCT="?"
fi

# Cross-check: bc-status Capacity vs ioreg %. If they differ by more than
# 1%, log it (do not silently pick one) and use the ioreg value for the
# menu-bar icon (ioreg is the direct hardware read).
if [ -n "$PCT" ] && [ "$SMC_PCT" != "?" ]; then
    _diff=$((PCT - SMC_PCT))
    [ "$_diff" -lt 0 ] && _diff=$((-_diff))
    if [ "$_diff" -gt 1 ]; then
        printf '[%s] CapacityNote: bc-status %s%% vs ioreg %s%%\n' "$(date '+%H:%M:%S')" "$PCT" "$SMC_PCT" > "$DASH/.status_note" 2>/dev/null
    fi
fi
if [ -z "$PCT" ] && [ "$SMC_PCT" != "?" ]; then
    PCT="$SMC_PCT"
fi

# Charging/discharging state from ioreg (not free-text parsing).
IS_CHARGING=0; IS_DISCHARGING=0
[ "$ICON_ISCHG" = "Yes" ] && IS_CHARGING=1
if [ "$ICON_EXT" = "No" ] && [ "$ICON_ISCHG" = "No" ]; then
    IS_DISCHARGING=1
fi

# Hold state — authoritative from BCLM=10 (hold) vs BCLM=100 (not holding).
# BCLM is the hold-state indicator, NOT the limit % (the limit lives in
# config). NCR=14 is only a secondary hint when BCLM is unavailable.
IS_HOLD=0
if [ "$BCLM" = "10" ] && [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
    IS_HOLD=1
elif [ -z "$BCLM" ] && [ "$ICON_NCR" = "14" ] && [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
    # Secondary hint only (BCLM unreadable — bc-status down). Log it once
    # per render via the status note so a stale hint is visible.
    IS_HOLD=1
fi

# ============ PROACTIVE CHECKS ============
if [ -n "$TEMP_INT" ]; then
    if [ "$TEMP_INT" -ge 45 ]; then
        notify_proactive_v2 "temp_critical" 300 "Battery Critical Temperature" "${TEMP}°C - reduce load immediately"
    elif [ "$TEMP_INT" -ge 42 ]; then
        : # REMOVED v1.5.2 (noise) temp_high
    fi
fi
if [ "$IS_DISCHARGING" = "1" ] && [ -n "$PCT" ] && [ "$PCT" -le 20 ]; then
    : # REMOVED v1.5.2 (noise) low_batt
fi
if [ "$IS_CHARGING" = "1" ] && [ -n "$PCT" ] && [ "$PCT" -ge 99 ] && [ -z "$UPPER" ]; then
    : # REMOVED v1.5.2 (noise) full_charge
fi
if [ -n "$HEALTH_INT" ] && [ "$HEALTH_INT" -le 75 ]; then
    : # REMOVED v1.5.2 (noise) health_low
fi
SD_STATE="$DASH/.sd_watch"
if [ -f "$SD_STATE" ]; then
    SD_TARGET=$(cat "$SD_STATE" 2>/dev/null)
    # A corrupt .sd_watch (non-numeric) would make the -le test below
    # error on every render and the stale file would never clear.
    case "$SD_TARGET" in ''|*[!0-9]*) rm -f "$SD_STATE" 2>/dev/null; SD_TARGET="" ;; esac
    if [ -n "$PCT" ] && [ -n "$SD_TARGET" ] && [ "$PCT" -le "$SD_TARGET" ]; then
        notify_proactive_v2 "sd_complete" 1800 "Smart Discharge" "Reached target ${SD_TARGET}%"
        rm -f "$SD_STATE"
    fi
fi
if [ "$IS_DISCHARGING" = "1" ]; then
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
TEMP_FLAG="$DASH/.temp_alert_state"
if [ -n "$TEMP_INT" ]; then
    PREV_STATE=$(cat "$TEMP_FLAG" 2>/dev/null || echo "0")
    if [ "$TEMP_INT" -ge 42 ] && [ "$PREV_STATE" != "1" ]; then
        notify_proactive_v2 "temp_critical" 1800 "🌡️ Battery Hot" "Temperature: ${TEMP}°C — unplug charger, check cooling"
        _atomic_write "$TEMP_FLAG" "1"
    elif [ "$TEMP_INT" -lt 38 ] && [ "$PREV_STATE" = "1" ]; then
        _atomic_write "$TEMP_FLAG" "0"
    fi
fi

# Process inspection is gone on purpose. The Sentinel session is the only UI state.

# Display-state system (separate, read-only): the SOLE decider.
# Its output is KEY=value; parse it with an allow-list — never eval.
DISPLAY_OK=0
DISPLAY_HELPER=""
if [ -x "$DASH/display_state.sh" ]; then
    DISPLAY_HELPER="$DASH/display_state.sh"
elif [ -x "$(dirname "$0")/display_state.sh" ]; then
    DISPLAY_HELPER="$(dirname "$0")/display_state.sh"
fi
ICON=""; STATE_COLOR=""; FINAL_COLOR=""; DISCHARGE_STATUS=""; CALIBRATION_STATUS=""
if [ -n "$DISPLAY_HELPER" ]; then
    DISPLAY_OUT=$(DISPLAY_MODE="$ACTIVE_MODE" TEMP_INT="${TEMP_INT:-}" PCT_IN="$PCT" LIMIT_IN="${LAST_UPPER:-86}" BCLM_IN="${BCLM:-}" "$DISPLAY_HELPER" 2>/dev/null) || DISPLAY_OUT=""
    while IFS='=' read -r _dk _dv; do
        case "$_dk" in
            DISPLAY_MODE) ACTIVE_MODE="$_dv" ;;
            ICON) ICON="$_dv" ;;
            STATE_COLOR) STATE_COLOR="$_dv" ;;
            FINAL_COLOR) FINAL_COLOR="$_dv" ;;
            DISCHARGE_STATUS) DISCHARGE_STATUS="$_dv" ;;
            CALIBRATION_STATUS) CALIBRATION_STATUS="$_dv" ;;
        esac
    done <<EOF
$DISPLAY_OUT
EOF
    if [ -n "$ICON" ] && [ -n "$FINAL_COLOR" ]; then
        DISPLAY_OK=1
    fi
fi
if [ "$DISPLAY_OK" != "1" ]; then
    # Minimal safe default only (display_state.sh is the sole decider; this
    # does NOT duplicate its table — it only keeps the menu bar from
    # rendering blank when the decider is absent). Grey rule: grey whenever
    # IsCharging=Yes (the one documented rule; see display_state.sh).
    if [ "$ICON_ISCHG" = "Yes" ]; then
        ICON="⚡"; FINAL_COLOR="color=#707070"
    elif [ "$ICON_EXT" = "Yes" ]; then
        ICON="🔌"; FINAL_COLOR="color=#FFFFFF"
    else
        # Discharge mode (icon fix, 2026-11-16): while bc-limit
        # holds the manager discharge mode the adapter path is
        # dropped (EXT=No) — the engage marker + live session
        # classify the state as discharge (battery symbol), not
        # plain battery use (red circle). Mirrors display_state.sh.
        _FB_SESS=$(grep '^STARTED=' "$DASH/.discharge_session" 2>/dev/null | tail -1 | cut -d= -f2)
        _FB_MARK=$(grep '^STARTED=' "$DASH/.bc-limit-acengage" 2>/dev/null | tail -1 | cut -d= -f2)
        if [ -n "$_FB_SESS" ] && [ "$_FB_SESS" = "$_FB_MARK" ]; then
            ICON="🔋"; FINAL_COLOR="color=#8A9AAB"
        else
            ICON="🔴"; FINAL_COLOR="color=#E8A0A0"
        fi
    fi
fi

# MODE text — from session mode + ioreg + config (no free-text parsing).
case "$ACTIVE_MODE" in
    charge_full) MODE="Charging to 100%" ;;
    calibration) MODE="Calibrating" ;;
    discharge)   MODE="Discharging to ${LAST_UPPER}%" ;;
    hold)        MODE="Holding at ${PCT:-?}%" ;;
    *)
        if [ "$ICON_ISCHG" = "Yes" ]; then
            if [ -n "$UPPER" ] && [ -n "$PCT" ] && [ "$PCT" -lt "$UPPER" ] 2>/dev/null; then
                MODE="Topping to ${UPPER}%"
            else
                MODE="Charging"
            fi
        elif [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
            if [ -n "$UPPER" ] && [ -n "$PCT" ]; then
                if [ "$PCT" -gt "$UPPER" ] 2>/dev/null; then
                    MODE="Above limit (${PCT}% / ${UPPER}%)"
                elif [ "$PCT" -eq "$UPPER" ] 2>/dev/null; then
                    MODE="Holding at ${UPPER}%"
                else
                    MODE="Below limit (${PCT}% / ${UPPER}%)"
                fi
            elif [ -n "$UPPER" ]; then
                MODE="Holding at ${UPPER}%"
            else
                MODE="On adapter"
            fi
        elif [ "$ICON_EXT" = "No" ]; then
            MODE="On battery"
        else
            MODE="Unknown"
        fi
        ;;
esac

# STATE for the sleep report — from ioreg (not free-text parsing).
if [ "$ICON_ISCHG" = "Yes" ]; then
    STATE="charging"
elif [ "$ICON_EXT" = "Yes" ]; then
    STATE="no charging"
else
    STATE="discharging"
fi

# hold_reached — notify ONCE per hold session (notification policy 2026-11-11).
# The old 3600s cooldown re-fired every hour while the battery kept holding
# (a steady-state condition). The session file dedups by hold episode: one
# notification when a NEW hold begins; none while it keeps holding. The
# session clears when the hold ends or the limit changes, so the next hold
# notifies once. notify_proactive_v2's cooldown + daily cap remain as backstops.
HOLD_SESSION_FILE="$DASH/.notify/hold_reached_session"
if [ "$ACTIVE_MODE" = "hold" ] && [ -n "$PCT" ] && [ -n "$UPPER" ]; then
    DIFF=$((PCT - UPPER))
    [ "$DIFF" -lt 0 ] && DIFF=$((-DIFF))
    if [ "$DIFF" -le 1 ]; then
        _hold_session="$(cat "$HOLD_SESSION_FILE" 2>/dev/null || echo "")"
        if [ "$_hold_session" != "${UPPER}/${LOWER}" ]; then
            notify_proactive_v2 "hold_reached" 3600 \
                "Battery at Limit" \
                "Holding at ${UPPER}% (charge limit enforced)"
            # Record the session (the hold has been announced, or the
            # announcement was suppressed by cooldown/daily cap — either way
            # this hold episode is handled; no hourly repeat).
            mkdir -p "$DASH/.notify" 2>/dev/null
            _atomic_write "$HOLD_SESSION_FILE" "${UPPER}/${LOWER}"
        fi
    fi
    # NOTE: do NOT clear the session file when DIFF > 1 while mode is still
    # hold — the hold session is ongoing; we notify when it reaches the limit.
else
    rm -f "$HOLD_SESSION_FILE" 2>/dev/null
fi

# Clamshell + schedule were dropped (approved decision) — no menu sections
# (dispatch still stubs the actions). CLAM/SCHED kept as unused state.
CLAM=0
SCHED=0

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

# Neutral first render: ioreg missing/invalid only, SMC_PCT unknown or EXT/ISCHG empty.
# Valid ioreg cases keep their true icon, even if red for seconds before reconciler.
# Neutral ticks must not pollute audit or last_icon, so audit is guarded below.
NEUTRAL=0
if [ "$SMC_PCT" = "?" ] || [ -z "$ICON_EXT" ] || [ -z "$ICON_ISCHG" ]; then
    NEUTRAL=1
    ICON="⏳"
    FINAL_COLOR="color=#909090"
fi

# R5: icon-transition audit - log only on changes, capped rotation
AUDIT_LOG="$DASH/.audit.log"
_prev_icon=$(cat "$DASH/.last_icon" 2>/dev/null)
if [ "$NEUTRAL" != "1" ] && [ "$ICON" != "$_prev_icon" ]; then
    printf '[%s] icon %s -> %s (mode=%s ext=%s ischg=%s ncr=%s pct=%s bclm=%s)\n' "$(date '+%H:%M:%S')" "${_prev_icon:-none}" "$ICON" "$ACTIVE_MODE" "${ICON_EXT:-?}" "${ICON_ISCHG:-?}" "${ICON_NCR:-?}" "${SMC_PCT:-?}" "${BCLM:-?}" >> "$AUDIT_LOG" 2>/dev/null
    _atomic_write "$DASH/.last_icon" "$ICON"
    if [ -f "$AUDIT_LOG" ] && [ "$(wc -c < "$AUDIT_LOG" 2>/dev/null | tr -d ' ')" -gt 51200 ]; then
        tail -200 "$AUDIT_LOG" > "$AUDIT_LOG.tmp" 2>/dev/null && mv "$AUDIT_LOG.tmp" "$AUDIT_LOG" 2>/dev/null
    fi
fi
echo "${ICON} ${SMC_PCT}% | size=14 ${FINAL_COLOR}"
echo "---"
echo "Charge: ${PCT:-?}% | size=11"
echo "Mode: ${MODE} | size=11"
# Discharge session status (one line, only while a session exists;
# text decided by display_state.sh — discharge build 2026-11-13).
if [ -n "${DISCHARGE_STATUS:-}" ]; then
    echo "$DISCHARGE_STATUS | size=11 $ORANGE"
fi
# Calibration run status (one line, only while a run exists;
# text decided by display_state.sh — calibrate build 2026-11-14).
if [ -n "${CALIBRATION_STATUS:-}" ]; then
    echo "$CALIBRATION_STATUS | size=11 $ORANGE"
fi
echo "Health: ${HEALTH:-?}% - ${CYCLES:-?} cycles | size=11 $GRAY"
if [ -n "$TEMP" ]; then
    echo "Temperature: ${TEMP}°C | size=11 ${ALERT_COLOR:-color=#909090}"
fi
if [ -n "$BACKEND" ]; then
    echo "Backend: ${BACKEND} | size=11 $GRAY"
fi
# Overnight summary (one line, written by morning_report.sh at 8 AM).
if [ -r "$DASH/.overnight_summary" ]; then
    echo "Overnight: $(cat "$DASH/.overnight_summary") | size=11 $GRAY"
fi
# Verification summary (one line, written by bc-verify — verification
# deployment 2026-11-14, design §6). The stored text already carries
# its "Verified:" prefix; absence of the file renders as nothing
# (honest: no data, no line).
if [ -r "$DASH/.verification_summary" ]; then
    echo "$(cat "$DASH/.verification_summary") | size=11 $GRAY"
fi

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

SM_STATE=$(cat "$DASH/.sleep_mode" 2>/dev/null || echo "default")
case "$SM_STATE" in
    presentation) SM_TITLE="Presentation" ;;
    download)     SM_TITLE="Stay Awake (Lid Closed)" ;;
    travel)       SM_TITLE="Travel" ;;
    long)         SM_TITLE="Long Day" ;;
    *)            SM_TITLE="Normal" ;;
esac
echo "Sleep Mode — ${SM_TITLE} | size=14 color=#007AFF"
echo "-- Normal | bash=$DISPATCH param1=sleep_mode_default terminal=false refresh=true checked=$([ "$SM_STATE" = "default" ] && echo true || echo false) size=12"
echo "-- macOS handles sleep | size=9 color=#909090 disabled=true"
echo "-- Presentation | bash=$DISPATCH param1=sleep_mode_presentation terminal=false refresh=true checked=$([ "$SM_STATE" = "presentation" ] && echo true || echo false) size=12"
echo "-- Never sleeps on AC | size=9 color=#909090 disabled=true"
echo "-- Stay Awake (Lid Closed) | bash=$DISPATCH param1=sleep_mode_download terminal=false refresh=true checked=$([ \"$SM_STATE\" = \"download\" ] && echo true || echo false) size=12"
echo "-- Lid closed · AC required · never sleeps | size=9 color=#909090 disabled=true"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
echo "-- Hibernate timing — after the Mac sleeps | size=9 color=#505050 disabled=true"
echo "-- Travel | bash=$DISPATCH param1=sleep_mode_travel terminal=false refresh=true checked=$([ "$SM_STATE" = "travel" ] && echo true || echo false) size=12"
echo "-- Battery holds longer (4h) | size=9 color=#909090 disabled=true"
echo "-- Long Day | bash=$DISPATCH param1=sleep_mode_long terminal=false refresh=true checked=$([ \"$SM_STATE\" = \"long\" ] && echo true || echo false) size=12"
echo "-- Ready longer on battery + AC | size=9 color=#909090 disabled=true"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
echo "-- Prepare for Sleep | bash=$DISPATCH param1=arm_sleep terminal=false refresh=true size=12 color=#007AFF"
echo "-- Close audio apps · arm sleep | size=9 color=#909090 disabled=true"

# BCLM=10 holding counts too: after a reboot the session file is gone
# while the battery is still holding, and the tick must reflect that.
if [ "$ACTIVE_MODE" = "hold" ] || [ "$IS_HOLD" = "1" ]; then
    echo "✓ Stop Charging Now (hold at ${PCT:-?}%) | bash=$DISPATCH param1=stop_now terminal=false refresh=true"
else
    echo "Stop Charging Now (hold at ${PCT:-?}%) | bash=$DISPATCH param1=stop_now terminal=false refresh=true"
fi

CHARGE_TARGET=$(cat "$DASH/.charge_target" 2>/dev/null || echo "")
if [ "$ACTIVE_MODE" = "charge_full" ]; then
    if [ -z "$CHARGE_TARGET" ] || [ "$CHARGE_TARGET" = "100" ]; then
        echo "✓ Charge to 100% & Hold | bash=$DISPATCH param1=charge_full terminal=false refresh=true"
    else
        echo "Charge to 100% & Hold | bash=$DISPATCH param1=charge_full terminal=false refresh=true"
    fi
else
    echo "Charge to 100% & Hold | bash=$DISPATCH param1=charge_full terminal=false refresh=true"
fi

if [ -f "$DASH/.discharge_session" ]; then
    # State-aware label (2026-11-14): while a session exists this
    # item CANCELS it (dispatch's smart_discharge is a toggle) —
    # the label must say so. Live incident 2026-11-14 22:34: the
    # start-shaped label ("Smart Discharge to 86%") invited a
    # second press that silently cancelled the session the user
    # had just started via Custom Limit. Target = the live session
    # file's TARGET (the truth), falling back to the legacy watch
    # value, then the configured upper.
    # Gate fix (2026-11-15, approved): the gate is the session
    # file itself. The original gate (ACTIVE_MODE = discharge)
    # was unreachable — nothing in the architecture ever writes
    # .active_mode=discharge for a discharge session, so the
    # Cancel label never rendered while a session was armed or
    # parked (proven live 2026-11-15 20:34, session TARGET=85).
    DS_MENU_TARGET=$(grep '^TARGET=' "$DASH/.discharge_session" 2>/dev/null | tail -1 | cut -d= -f2)
    case "$DS_MENU_TARGET" in ''|*[!0-9]*) DS_MENU_TARGET="${SD_TARGET:-${LAST_UPPER:-?}}" ;; esac
    echo "■ Cancel Discharge (to ${DS_MENU_TARGET}%) | bash=$DISPATCH param1=smart_discharge terminal=false refresh=true $ORANGE"
    echo "↳ Stop Discharge (hold here) | bash=$DISPATCH param1=kill_discharge terminal=false refresh=true $GRAY"
else
    echo "★ Smart Discharge... | bash=$DISPATCH param1=smart_discharge terminal=false refresh=true $ORANGE"
fi

echo "Force Reset | bash=$DISPATCH param1=force_reset terminal=false refresh=true $GRAY"
echo "Reset to Defaults | bash=$DISPATCH param1=reset_defaults terminal=false refresh=true $GRAY"
echo "---"

echo "Charge Limits | size=11 color=#007AFF disabled=true"
DISP_UPPER="${LAST_UPPER:-86}"
DISP_LOWER="${LAST_LOWER:-85}"
if [ "$ACTIVE_MODE" = "idle" ] || [ "$ACTIVE_MODE" = "hold" ]; then
    echo "✓ Custom Limit — ${DISP_UPPER}% / ${DISP_LOWER}% | bash=$DISPATCH param1=limit_custom terminal=false refresh=true"
else
    echo "Custom Limit — ${DISP_UPPER}% / ${DISP_LOWER}% | bash=$DISPATCH param1=limit_custom terminal=false refresh=true"
fi

# remove_limit_hold: label + param1 unchanged (design §1.5 decision 6).
# Behaviour is corrected in dispatch (clear_hold): it removes the hold and
# returns to the configured limit — it no longer holds at the current %.
echo "Remove Hold (return to ${DISP_UPPER}%/${DISP_LOWER}%) | bash=$DISPATCH param1=remove_limit_hold terminal=false refresh=true"
echo "Disable All Limits (charge to 100%) | bash=$DISPATCH param1=disable_limit terminal=false refresh=true color=#909090"
echo "---"

echo "Battery Care | size=11 color=#007AFF disabled=true"
CAL_RUNNING=$([ "$ACTIVE_MODE" = "calibration" ] && echo " · running" || echo "")
echo "Calibration${CAL_RUNNING} | size=14 color=#FFFFFF"
echo "-- Full cycle: 100% → health-based floor → 100% | size=10 color=#909090 disabled=true"
echo "-- ────────────────────────── | size=9 color=#505050 disabled=true"
if [ -f "$DASH/.calibration_run" ]; then
    if grep -q '^WAITING=1' "$DASH/.calibration_run" 2>/dev/null; then
        echo "-- Resume Calibration | bash=$DISPATCH param1=calibrate_resume terminal=false refresh=true size=12"
    fi
    echo "-- Cancel Calibration | bash=$DISPATCH param1=calibrate terminal=false refresh=true size=12"
    echo "-- Restores your limit + power settings. | size=9 color=#909090 disabled=true"
    echo "-- Force Stop Calibration | bash=$DISPATCH param1=kill_calibrate terminal=false refresh=true size=12"
    echo "-- Immediate stop if calibration is stuck. | size=9 color=#909090 disabled=true"
else
    echo "-- Start Calibration | bash=$DISPATCH param1=calibrate terminal=false refresh=true size=12"
    echo "-- Floor + emergency stop are chosen automatically from battery health. | size=9 color=#909090 disabled=true"
    echo "-- Takes most of a day: charge, rest, drain while you work, rest, recharge. | size=9 color=#909090 disabled=true"
fi
echo "---"

echo "Refresh Now | refresh=true"
echo "Show Full Status... | bash=$DISPATCH param1=details terminal=false"
echo "Sleep & Battery Report | bash=$DISPATCH param1=sleep_report terminal=false"
echo "Overnight Report | bash=$DISPATCH param1=overnight_report terminal=false"
echo "Save Report (silent) | bash=$DISPATCH param1=sleep_report_save terminal=false"
echo "Open Reports Folder | bash=$DISPATCH param1=open_reports terminal=false"
echo "---"
# Verification submenu (design §6; verification deployment 2026-11-14):
# read-only rendering of .verification_state, written by bc-verify.
echo "Verification | size=14 color=#FFFFFF"
if [ -r "$DASH/.verification_state" ]; then
    _vs_get() { grep "^$1=" "$DASH/.verification_state" 2>/dev/null | head -1 | cut -d= -f2-; }
    _VS_CYCLE=$(_vs_get LAST_CYCLE); _VS_CYCLE_V=$(_vs_get LAST_CYCLE_VERDICT)
    _VS_HOLDS=$(_vs_get HOLDS_24H); _VS_HOLDS_P=$(_vs_get HOLDS_PASS)
    _VS_SN=$(_vs_get SLEEP_NIGHTS_7D); _VS_SMED=$(_vs_get SLEEP_MEDIAN_PCT_H); _VS_SBC=$(_vs_get SLEEP_BC_INVOLVED)
    _VS_LC=$(_vs_get LIMIT_CHANGES_7D); _VS_LAT=$(_vs_get LIMIT_MAX_LATENCY_S)
    _VS_PC=$(_vs_get PHASE_C); _VS_OV=$(_vs_get OVERSHOOT_MAX_7D)
    if [ -n "$_VS_CYCLE" ] && [ "$_VS_CYCLE" != "—" ]; then
        echo "-- Last full cycle: $_VS_CYCLE — $_VS_CYCLE_V | size=11 $GRAY"
    else
        echo "-- Last full cycle: — (none yet) | size=11 $GRAY"
    fi
    echo "-- Holds (24h): ${_VS_HOLDS_P:-0}/${_VS_HOLDS:-0} PASS | size=11 $GRAY"
    if [ -n "$_VS_SN" ] && [ "$_VS_SN" != "0" ]; then
        _VS_BC_TXT="never"; [ "${_VS_SBC:-0}" != "0" ] && _VS_BC_TXT="$_VS_SBC night(s)"
        echo "-- Sleep (7d): $_VS_SN nights · median ${_VS_SMED}%/h · BC involved: $_VS_BC_TXT | size=11 $GRAY"
    else
        echo "-- Sleep (7d): — (no nights yet) | size=11 $GRAY"
    fi
    echo "-- Limit changes (7d): ${_VS_LC:-0} · slowest enforcement: ${_VS_LAT:-—} | size=11 $GRAY"
    echo "-- Overshoot max (7d): ${_VS_OV:-—} | size=11 $GRAY"
    echo "-- Phase C: ${_VS_PC:-—} | size=11 $GRAY"
else
    echo "-- No verification data yet | size=11 $GRAY"
fi
echo "-- Open Verification Report | bash=$DISPATCH param1=verification_report terminal=false size=12"
echo "-- Re-run Verification | bash=$DISPATCH param1=verify_now terminal=false refresh=true size=12"
echo "Open Battery Commander (BC) Logs | bash=/usr/bin/open param1=$DASH terminal=false"
# Login-item query is slow (osascript + System Events) — cache it (1 h TTL)
# instead of running it on every 10 s render.
LOGIN_CACHE="$DASH/.login_cache"
LOGIN_TTL=3600
if [ -f "$LOGIN_CACHE" ]; then
    LOGIN_AGE=$((NOW_TS - $(stat -f %m "$LOGIN_CACHE" 2>/dev/null || echo 0)))
else
    LOGIN_AGE=9999
fi
if [ "$LOGIN_AGE" -lt "$LOGIN_TTL" ]; then
    LOGIN_STATE=$(cat "$LOGIN_CACHE" 2>/dev/null || echo 0)
else
    # Installed app is BatteryCommander.app (deploy swapped it);
    # "BattOpt" stays as a legacy fallback match.
    LOGIN_STATE=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -c "BattOpt\|BatteryCommander\|Battery Commander" || true)
    case "$LOGIN_STATE" in ''|*[!0-9]*) LOGIN_STATE=0 ;; esac
    _atomic_write "$LOGIN_CACHE" "$LOGIN_STATE"
fi
if [ "$LOGIN_STATE" -gt 0 ]; then
    echo "✓ Launch at Login | bash=$DISPATCH param1=login_toggle terminal=false refresh=true"
else
    echo "Launch at Login | bash=$DISPATCH param1=login_toggle terminal=false refresh=true"
fi
echo "Open Battery Commander.app | bash=$DISPATCH param1=open_app terminal=false"

echo "About Battery Commander (BC)... | bash=$DISPATCH param1=about terminal=false"
echo "---"

PSAVER_STATE=$([ -f "$DASH/.power_saver" ] && echo "ON" || echo "OFF")
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
case "$STANDBY_DELAY" in ''|*[!0-9]*) STANDBY_DELAY=4200 ;; esac
STANDBY_MIN=$((STANDBY_DELAY / 60))

USB_CACHE="$DASH/.usb_cache"
USB_TTL=300
if [ -f "$USB_CACHE" ]; then
    USB_AGE=$((NOW_TS - $(stat -f %m "$USB_CACHE" 2>/dev/null || echo 0)))
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

WAKE_CACHE="$DASH/.wake_cache"
WAKE_TTL=600
if [ -f "$WAKE_CACHE" ]; then
    WAKE_AGE=$((NOW_TS - $(stat -f %m "$WAKE_CACHE" 2>/dev/null || echo 0)))
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
echo "-- 🔋 Battery: ${PCT:-?}% | size=11"
echo "-- 💚 Health: ${HEALTH:-?}% · ${CYCLES:-?} cycles | size=11 $GRAY"
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

# Sailing display. The limits come from the canonical config (UPPER/LOWER
# above) — never from .sailing_state: its UPPER/LOWER were written from the
# dead `battopt status` source and are stale 85/80 (W0-extension §3.4).
# .sailing_state is parsed as KEY=value (allow-list) for its metadata only.
SAIL_STATE="$DASH/.sailing_state"
if [ -f "$SAIL_STATE" ]; then
    TRANSITIONS=""; LAST_TIME=""; LAST_PCT=""; LAST_DIR=""
    while IFS='=' read -r _sk _sv; do
        case "$_sk" in
            TRANSITIONS) TRANSITIONS="$_sv" ;;
            LAST_TIME) LAST_TIME="$_sv" ;;
            LAST_PCT) LAST_PCT="$_sv" ;;
            LAST_DIR) LAST_DIR="$_sv" ;;
        esac
    done < "$SAIL_STATE"
    if [ -n "$UPPER" ] && [ -n "$LOWER" ]; then
        RANGE_DIFF=$((UPPER - LOWER))
        if [ -n "$PCT" ] && [ "$PCT" -ge "$UPPER" ] 2>/dev/null; then
            POS="at upper (${UPPER}%)"
            POS_COLOR="color=#FF9500"
        elif [ -n "$PCT" ] && [ "$PCT" -le "$LOWER" ] 2>/dev/null; then
            POS="at lower (${LOWER}%)"
            POS_COLOR="color=#FF9500"
        else
            POS="mid (${PCT:-?}%)"
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

AUTO_STATE=$([ -f "$DASH/.auto_cleanup" ] && echo "ON" || echo "OFF")
IDLE=$(ioreg -c IOHIDSystem 2>/dev/null | grep -E "HIDIdleTime" | awk '{print $NF}' | head -1)
case "$IDLE" in ''|*[!0-9]*) IDLE=0 ;; esac
IDLE_MIN=$((IDLE / 1000000000 / 60))
CLEANUP_DONE=$([ -f "$DASH/.pre_sleep_done" ] && echo "YES" || echo "NO")

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
echo "--    BC daemon activity | size=10 $GRAY"
echo "--    All saved reports | size=10 $GRAY"

echo "System Resources | size=11 color=#007AFF disabled=true"
SWIFTBAR_PID=$(pgrep -x SwiftBar | head -1)
if [ -n "$SWIFTBAR_PID" ]; then
    SWIFTBAR_CPU=$(ps -p "$SWIFTBAR_PID" -o %cpu= | tr -d ' ')
    SWIFTBAR_RAM=$(ps -p "$SWIFTBAR_PID" -o rss= | awk '{printf "%.1f", $1/1024}')
    echo "SwiftBar: ${SWIFTBAR_CPU}% CPU - ${SWIFTBAR_RAM}MB RAM | size=11 color=#909090"
fi
# The BC enforcer is a root LaunchDaemon (invoked every 60 s, KeepAlive
# false) — there is no persistent process to show CPU/RAM for, and it lives
# in the SYSTEM launchd domain, so a user-domain `launchctl list` can never
# see it. Judge it from its own log instead: alive = newest state tick is
# fresh (< 3 min while the Mac is awake). Show real daemon statistics.
DAEMON_LOG="$DASH/bc-limit-daemon.log"
if [ -f "$DAEMON_LOG" ]; then
    D_STATE=$(grep "state:" "$DAEMON_LOG" 2>/dev/null | tail -1)
    D_TS=$(printf '%s' "$D_STATE" | sed -E 's/^\[([0-9-]+ [0-9:]+)\].*/\1/' 2>/dev/null)
    case "$D_TS" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;; *) D_TS="" ;; esac
    D_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S" "$D_TS" +%s 2>/dev/null || echo 0)
    case "$D_EPOCH" in ''|*[!0-9]*) D_EPOCH=0 ;; esac
    D_AGE=$((NOW_TS - D_EPOCH))
    D_PCT=$(printf '%s' "$D_STATE" | grep -oE "pct=[0-9]+" | head -1 | cut -d= -f2)
    D_BCLM=$(printf '%s' "$D_STATE" | grep -oE "BCLM=[0-9]+" | head -1 | cut -d= -f2)
    D_CHG=$(printf '%s' "$D_STATE" | grep -oE "charging=[0-9]+" | head -1 | cut -d= -f2)
    D_WRITES=$(grep "$(date '+%Y-%m-%d')" "$DAEMON_LOG" 2>/dev/null | grep -c "WRITE:")
    if [ "$D_CHG" = "1" ]; then D_MODE="charging"; elif [ "$D_BCLM" = "10" ]; then D_MODE="holding"; else D_MODE="idle"; fi
    if [ "$D_EPOCH" -gt 0 ] && [ "$D_AGE" -le 180 ]; then
        echo "BC limit daemon: active — last tick ${D_TS} (${D_AGE}s ago) | size=11 color=#909090"
        echo "Daemon state: ${D_PCT}% · BCLM=${D_BCLM} · ${D_MODE} · writes today: ${D_WRITES} | size=11 color=#909090"
    else
        echo "BC limit daemon: NO TICK since ${D_TS:-never} — check daemon | size=11 color=#FF9500"
    fi
else
    echo "BC limit daemon: log missing — cannot verify | size=11 color=#FF9500"
fi
echo "---"
AGENT_COUNT=$(launchctl list 2>/dev/null | grep -c "com.batterycommander")
echo "Services: ${AGENT_COUNT} agents loaded | size=11 color=#909090"
echo "Stop ALL Services (full shutdown) | bash=$DISPATCH param1=shutdown terminal=false refresh=true color=red"

