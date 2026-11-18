#!/bin/bash
# self_maintenance.sh - Battery Commander self-maintenance (BC v2.0.0).
# Runs every 300 s via com.batterycommander.selfmaintenance. Read-only checks + log.
#
# W2.4 fixes (W0-extension §3.6 — this script was false-alarming hourly):
#   check 1: `sudo -n battopt status` (dead source) is replaced by a
#     bc-status run. bc-status is the BC status binary (read-only).
#   check 2: the hold check uses BCLM (10 = holding) instead of the
#     NCR=14 magic number; the UPPER fallback is the canonical 86 (not 85);
#     the config is parsed as KEY=value, never sourced.
#   NCR=14 is kept only as a secondary hint when BCLM is unavailable.
# Checks 3–4 are unchanged. Check 5 (W3) now counts bc-watchdog.sh
# (the BC watchdog replaced guardian.sh).
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
BC_BUILD_DIR="${BC_BUILD_DIR:-$HOME/Projects/BattOpt-CC-Release/battopt-project/bc-build}"
BC_STATUS="$BC_BUILD_DIR/bc-status"
LOG="$DASH/maintenance.log"; exec >> "$LOG" 2>&1
FAIL_REASON=""
# Guard: respect shutdown
if [ -f "$DASH/.user_shutdown" ]; then
    echo "shutdown flag present - skipping selfmaintenance"
    exit 0
fi


# 1. Status source responsive (bc-status, read-only)
_status_out=""
if [ -x "$BC_STATUS" ]; then
    _status_out="$("$BC_STATUS" 2>/dev/null)"
fi
if [ -z "$_status_out" ] || ! printf '%s\n' "$_status_out" | grep -q '^Capacity:'; then
    FAIL_REASON="bc-status is not responding"
fi

# 2. SMC Hold Check (Smart Logic) — BCLM is the hold-state indicator
# (10 = holding, 100 = not holding). The limit % lives in config.
if [ -z "$FAIL_REASON" ]; then
    UPPER=86
    if [ -f "$DASH/config" ]; then
        while IFS='=' read -r _k _v; do
            case "$_k" in
                LAST_UPPER) UPPER="$_v" ;;
            esac
        done < "$DASH/config"
    fi
    case "$UPPER" in ''|*[!0-9]*) UPPER=86 ;; esac

    BATT_DATA=$(ioreg -rn AppleSmartBattery 2>/dev/null)
    CUR=$(echo "$BATT_DATA" | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
    MAX=$(echo "$BATT_DATA" | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')
    EXT=$(echo "$BATT_DATA" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
    NCR=$(echo "$BATT_DATA" | grep -oE '"NotChargingReason"=[0-9]+' | cut -d= -f2)
    BCLM=$(printf '%s\n' "$_status_out" | grep '^BCLM:' | head -1)
    BCLM=${BCLM#*: }; BCLM=$(printf '%s' "$BCLM" | tr -d '[:space:]')

    case "$CUR" in ''|*[!0-9]*) CUR="" ;; esac
    case "$MAX" in ''|*[!0-9]*) MAX="" ;; esac
    if [ -n "$CUR" ] && [ -n "$MAX" ] && [ "$MAX" -gt 0 ] 2>/dev/null; then
        PCT=$(( (CUR * 100 + MAX / 2) / MAX ))
    else
        PCT=""
    fi

    # Holding = BCLM 10. If BCLM is unreadable, fall back to the NCR=14
    # hint (secondary only — see the hold rule in display_state.sh).
    _holding=0
    if [ "$BCLM" = "10" ]; then
        _holding=1
    elif [ -z "$BCLM" ] && [ "$NCR" = "14" ]; then
        _holding=1
    fi
    if [ "$EXT" = "Yes" ] && [ -n "$PCT" ] && [ "$PCT" -ge "$UPPER" ] && [ "$_holding" != "1" ]; then
        # Single-tick false-FAIL: a transient read (or a limit change the
        # enforcer has not picked up yet) fails the check once. Only FAIL
        # if the condition is still true on a later run (>300 s after the
        # first sighting) — audit 2026-11-11, W19.
        _hold_first_file="$DASH/.maint_hold_first"
        _now2=$(date +%s)
        _first2=0
        [ -f "$_hold_first_file" ] && _first2=$(cat "$_hold_first_file" 2>/dev/null || echo 0)
        case "$_first2" in ''|*[!0-9]*) _first2=0 ;; esac
        if [ "$_first2" -eq 0 ]; then
            echo "$_now2" > "$_hold_first_file"
        elif [ $(( _now2 - _first2 )) -ge 300 ]; then
            FAIL_REASON="SMC not holding at $UPPER% (Current: $PCT%, BCLM: ${BCLM:-?})"
        fi
    else
        rm -f "$DASH/.maint_hold_first" 2>/dev/null || true
    fi
fi

# 3. Hung Shutdown
if [ -z "$FAIL_REASON" ]; then
    if pgrep -f "dispatch.sh shutdown" >/dev/null 2>&1; then
        FAIL_REASON="Hung dispatch.sh shutdown process detected"
    fi
fi

# 4. Disk Space (20GB)
if [ -z "$FAIL_REASON" ]; then
    FREE_GB=$(df -g /var/vm | tail -1 | awk '{print $4}')
    case "$FREE_GB" in ''|*[!0-9]*) FREE_GB=999 ;; esac
    if [ "$FREE_GB" -lt 20 ]; then
        FAIL_REASON="Low disk space in /var/vm ($FREE_GB GB, need 20 GB)"
    fi
fi

# 5. Process Storm
if [ -z "$FAIL_REASON" ]; then
    WATCHDOG_CNT=$(pgrep -f "bc-watchdog.sh" | wc -l | tr -d ' ')
    if [ "$WATCHDOG_CNT" -gt 5 ]; then
        FAIL_REASON="Watchdog process storm ($WATCHDOG_CNT instances)"
    fi
fi

if [ -z "$FAIL_REASON" ]; then
    echo "[PASS] all self-maintenance checks"
else
    echo "[FAIL] $FAIL_REASON"

    ALERT_FLAG="$DASH/.maint_alerted"
    ALERT_COOLDOWN=3600
    NOW=$(date +%s)
    LAST_ALERT=$(cat "$ALERT_FLAG" 2>/dev/null || echo 0)
    case "$LAST_ALERT" in ''|*[!0-9]*) LAST_ALERT=0 ;; esac
    # Strip double quotes (defensive: the text is shown in dialogs
    # and logs downstream, where a stray quote corrupts parsing).
    FAIL_REASON=${FAIL_REASON//\"/}

    if [ $((NOW - LAST_ALERT)) -gt "$ALERT_COOLDOWN" ]; then
        # App-native transport (final cleanup 2026-11-18): queue
        # one title<TAB>body line; the app posts it natively.
        _mb=$(printf '%s' "$FAIL_REASON" | tr '\n\t' '  ')
        printf '%s\t%s\n' "Battery Commander Alert" "$_mb" >> "$DASH/.notify_queue" 2>/dev/null || true
        echo "$NOW" > "$ALERT_FLAG"
    fi
fi
