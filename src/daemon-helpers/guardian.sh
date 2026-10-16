#!/bin/bash

# Layer 15: battery-mode throttle
source "/Users/Yousef/.battopt-swiftbar/.throttle_helper.sh" 2>/dev/null && ac_throttle "guardian" 300

# State Guardian — monitors and corrects state drift
# Runs every 2 minutes via LaunchAgent

LOG="$HOME/.battopt-swiftbar/actions.log"
GUARD_LOG="$HOME/.battopt-swiftbar/.guardian.log"
CFG="$HOME/.battopt-swiftbar/config"
SESSION_FILE="$HOME/.battopt-swiftbar/.sd_session"
SHUTDOWN_FLAG="$HOME/.battopt-swiftbar/.user_shutdown"
BAT="/usr/local/bin/battopt"

if [ -e "$SHUTDOWN_FLAG" ]; then
    exit 0
fi

log() {
    echo "[$(date '+%H:%M:%S')] guardian: $1" >> "$LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$GUARD_LOG"
}

source "$HOME/.battopt-swiftbar/state_guard.sh" || exit 1

guarded() {
    guard_session_active && { log "L18: skipping mutation (active session)"; return 1; }
    return 0
}

heartbeat() {
        local _ncr
    _ncr=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -oE '"NotChargingReason"=[0-9]+' | grep -oE '[0-9]+' | head -1)
    [ -z "$_ncr" ] && _ncr="?"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] heartbeat: PCT=$PCT SMC=$SMC_UPPER/$SMC_LOWER cfg=$UPPER/$LOWER NCR=$_ncr" >> "$GUARD_LOG"
}

# ─── Read config ───
[ ! -f "$CFG" ] && exit 0
source "$CFG"

UPPER="${LAST_UPPER:-85}"
LOWER="${LAST_LOWER:-80}"
SAILING="${SAILING:-true}"

# ─── Read current state ───
STATUS=$(sudo -n "$BAT" status 2>/dev/null)
[ -z "$STATUS" ] && exit 0

PCT=$(echo "$STATUS" | grep -oE 'Capacity [0-9]+' | grep -oE '[0-9]+' | head -1)
SMC_UPPER=$(echo "$STATUS" | grep -oE 'upper limit [0-9]+' | grep -oE '[0-9]+' | head -1)
SMC_LOWER=$(echo "$STATUS" | grep -oE 'lower limit [0-9]+' | grep -oE '[0-9]+' | head -1)

[ -z "$PCT" ] && exit 0

# ═══════════════════════════════════════════════════════
# LAYER 1: Session Guard — clean stale sessions
# ═══════════════════════════════════════════════════════
if [ -f "$SESSION_FILE" ]; then
    AGE=$(( $(date +%s) - $(stat -f %m "$SESSION_FILE" 2>/dev/null || echo 0) ))
    # Session older than 2 hours → stale
    if [ "$AGE" -gt 7200 ]; then
        TOKEN=$(guard_token)
        [ -z "$TOKEN" ] || exit 0
        log "LAYER1: stale session (${AGE}s) — cleaning"
        rm -f "$SESSION_FILE"
        pkill -9 -f "sd_watcher" 2>/dev/null
        sudo pkill -9 -f "battopt discharge" 2>/dev/null
        sudo -n "$BAT" discharge stop >/dev/null 2>&1
    fi
fi

# ═══════════════════════════════════════════════════════
# LAYER 2: Overshoot Guard — PCT > UPPER + 2%
# ═══════════════════════════════════════════════════════

# Layer 18: skip if charge_full or discharge is active
ACTIVE_MODE=$(cat "$HOME/.battopt-swiftbar/.active_mode" 2>/dev/null || echo "idle")
if [ "$ACTIVE_MODE" = "charge_full" ] || [ "$ACTIVE_MODE" = "discharge" ] || [ "$ACTIVE_MODE" = "calibration" ]; then
    log "L18: skipping LAYER2 (active_mode=$ACTIVE_MODE)"
    # Skip overshoot logic
else
OVERSHOOT=$UPPER
# Only trigger if on AC (discharge to upper makes sense with charger)
AC_NOW=$(pmset -g batt 2>/dev/null | grep -q "AC Power" && echo "yes" || echo "no")
if [ "$PCT" -gt "$OVERSHOOT" ] && [ "$AC_NOW" = "yes" ]; then
    # Check if discharge already running
    if ! pgrep -f "battopt discharge" >/dev/null 2>&1; then
        log "LAYER2: overshoot detected (PCT=$PCT > UPPER=$UPPER)"
        
        # Create fresh session
        SD_ID=$(guard_session_begin discharge)
        [ -n "$SD_ID" ] || exit 0
        echo "$SD_ID" > "$SESSION_FILE"
        
        # Start watcher
        nohup "$HOME/.battopt-swiftbar/sd_watcher.sh" \
            "$SD_ID" "$UPPER" "$LOWER" "$SESSION_FILE" "$LOG" "$BAT" \
            >/dev/null 2>&1 &
        disown
        
        # Start discharge
        guarded || exit 0
        nohup sudo -n "$BAT" discharge "$UPPER" >/dev/null 2>&1 &
        disown
        
        sleep 2
        
        if pgrep -f "battopt discharge" >/dev/null; then
            log "LAYER2: discharge started ($PCT% → $UPPER%)"
        else
            # Layer 12 (enforce_watchdog) handles repeated failures — reduce log noise
if [ -f "$HOME/.battopt-swiftbar/.enforce_state" ]; then
    : # silent — Layer 12 is on it
else
    log "LAYER2: discharge failed — applying limit only"
fi
            sudo -n "$BAT" limit "$UPPER" "$LOWER" >/dev/null 2>&1
        fi
    fi
fi

# ═══════════════════════════════════════════════════════

# === STOP DISCHARGE AT UPPER (Stage 22) ===
# If discharging and battery <= UPPER, stop discharge and reapply limit
if pgrep -f "battopt discharge" >/dev/null 2>&1; then
    if [ -n "$PCT" ] && [ "$PCT" -le "$UPPER" ]; then
        log "L2b: discharge complete (PCT=$PCT <= UPPER=$UPPER) — stopping"
        guarded || exit 0
        sudo pkill -9 -f "battopt discharge" 2>/dev/null
        guarded || exit 0
        sudo -n "$BAT" discharge stop >/dev/null 2>&1
        guarded || exit 0
        source "$HOME/.battopt-swiftbar/config" 2>/dev/null
        sudo -n "$BAT" limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
    fi
fi
# === END STOP DISCHARGE ===

fi

# LAYER 3: Config is source of truth
HOLD_SINCE="$HOME/.battopt-swiftbar/.hold_since"
AM_L3=$(cat "$HOME/.battopt-swiftbar/.active_mode" 2>/dev/null | tr -d '[:space:]')
[ -z "$AM_L3" ] && AM_L3=idle

if [ "$AM_L3" = "hold" ]; then
    [ -f "$HOLD_SINCE" ] || date +%s > "$HOLD_SINCE"
else
    rm -f "$HOLD_SINCE"
fi

if [ -n "$SMC_UPPER" ] && [ "$SMC_UPPER" != "$UPPER" ]; then
    case "$AM_L3" in
        discharge|charge_full|calibration)
            log "LAYER3: drift SMC=$SMC_UPPER config=$UPPER but active=$AM_L3 — skip"
            ;;
        hold)
            NOW=$(date +%s)
            SINCE=$(cat "$HOLD_SINCE" 2>/dev/null || echo "$NOW")
            AGE=$((NOW - SINCE))
            if [ "$AGE" -gt 300 ]; then
                log "LAYER3: hold ${AGE}s drift SMC=$SMC_UPPER config=$UPPER — force reapply"
                sudo -n "$BAT" limit "$UPPER" "$LOWER" >/dev/null 2>&1
                date +%s > "$HOLD_SINCE"
            else
                log "LAYER3: hold ${AGE}s — defer"
            fi
            ;;
        *)
            log "LAYER3: drift SMC=$SMC_UPPER config=$UPPER — reapply (mode=$AM_L3)"
            sudo -n "$BAT" limit "$UPPER" "$LOWER" >/dev/null 2>&1
            ;;
    esac
fi

# ═══════════════════════════════════════════════════════
# LAYER 4: Process Guard — orphan discharge
# ═══════════════════════════════════════════════════════
if [ ! -f "$SESSION_FILE" ]; then
    # No session but discharge running → orphan
    # Layer 18e: only kill if not in active discharge mode
    AM_L4=$(cat "$HOME/.battopt-swiftbar/.active_mode" 2>/dev/null || echo "idle")
    if [ "$AM_L4" = "discharge" ]; then
        # Check process age — grace period of 90 seconds
        DIS_PID=$(pgrep -f "battopt discharge" | head -1)
        if [ -n "$DIS_PID" ]; then
            ET=$(ps -o etime= -p "$DIS_PID" 2>/dev/null | tr -d ' ')
            SEC=$(echo "$ET" | awk -F: '{if (NF==2) print $1*60+$2; else if (NF==3) print $1*3600+$2*60+$3; else print 9999}')
            if [ "${SEC:-9999}" -lt 90 ]; then
                : # young process; grace period
            else
                log "LAYER4: orphan discharge ${SEC}s old — stopping"
                sudo pkill -9 -f "battopt discharge" 2>/dev/null
                sudo -n "$BAT" discharge stop >/dev/null 2>&1
                [ -z "$(cat "$HOME/.battopt-swiftbar/.active_token" 2>/dev/null)" ] && echo idle > "$HOME/.battopt-swiftbar/.active_mode"
            fi
        fi
    elif pgrep -f "battopt discharge" >/dev/null 2>&1; then
        log "LAYER4: orphan discharge (no session, mode=$AM_L4) — stopping"
        sudo pkill -9 -f "battopt discharge" 2>/dev/null
        sudo -n "$BAT" discharge stop >/dev/null 2>&1
    fi
fi

heartbeat

# ─── Trim guardian log ───
if [ -f "$GUARD_LOG" ]; then
    SIZE=$(wc -c < "$GUARD_LOG" | tr -d ' ')
    [ "$SIZE" -gt 102400 ] && tail -200 "$GUARD_LOG" > "$GUARD_LOG.tmp" && mv "$GUARD_LOG.tmp" "$GUARD_LOG"
fi


# === LAYER 8: Daemon Watchdog ===
# Ensures exactly one battopt daemon is running under launchd.
daemon_watchdog() {
    local count
    count=$(pgrep -f "Application Support/battopt/battopt daemon" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$count" = "1" ]; then
        return 0  # healthy
    fi

    log "L8: daemon count = $count (expected 1) — recovering"

    # Kill any stray daemons
    sudo -n pkill -9 -f "Application Support/battopt/battopt daemon" 2>/dev/null
    sudo -n launchctl unload /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist 2>/dev/null
    sleep 1

    # Reload cleanly under launchd
    sudo -n launchctl load -w /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist 2>/dev/null

    # Poll until daemon socket responds (up to 15s)
    local after="" i=0
    while [ "$i" -lt 15 ]; do
        sleep 1
        i=$((i+1))
        after=$(pgrep -f "Application Support/battopt/battopt daemon" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$after" = "1" ] && sudo -n /usr/local/bin/battopt status >/dev/null 2>&1; then
            break
        fi
    done
    log "L8: after recovery daemon count = $after (polled ${i}s)"

    # Reapply limit
    guarded || return 0
    source "$HOME/.battopt-swiftbar/config" 2>/dev/null
    sudo -n /usr/local/bin/battopt limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
}
# === END LAYER 8 ===

# === LAYER 9: NCR Monitor — detect abnormal NotChargingReason ===
# Acceptable values when on AC: 0 (no reason), 14 (at limit).
# Any other sustained value (> 5 min) means SMC internal pause or fault.
ncr_monitor() {
    local state_file="$HOME/.battopt-swiftbar/.ncr_state"
    local ioreg
    ioreg=$(ioreg -rn AppleSmartBattery 2>/dev/null)
    [ -z "$ioreg" ] && return 0

    local ncr ischg ext
    ncr=$(echo "$ioreg" | grep -oE '"NotChargingReason"=[0-9]+' | grep -oE '[0-9]+' | head -1)
    ischg=$(echo "$ioreg" | grep -oE '"IsCharging" = [A-Za-z]+' | awk '{print $3}')
    ext=$(echo "$ioreg" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
    [ -z "$ncr" ] && return 0

    # Only monitor when on AC and not charging (this is where NCR matters)
    [ "$ext" != "Yes" ] && { rm -f "$state_file"; return 0; }
    [ "$ischg" = "Yes" ] && { rm -f "$state_file"; return 0; }

    # NCR 0 or 14 are normal
    if [ "$ncr" = "0" ] || [ "$ncr" = "14" ]; then
        rm -f "$state_file"
        return 0
    fi

    # Abnormal NCR — track first sighting
    if [ ! -f "$state_file" ]; then
        echo "$(date +%s)|$ncr" > "$state_file"
        return 0
    fi

    local first_ts first_ncr now elapsed
    first_ts=$(cut -d'|' -f1 "$state_file")
    first_ncr=$(cut -d'|' -f2 "$state_file")
    now=$(date +%s)
    elapsed=$((now - first_ts))

    # If same NCR persisted > 5 minutes, alert once
    if [ "$elapsed" -gt 300 ] && [ "$first_ncr" = "$ncr" ]; then
        log "L9: NCR=$ncr persisted ${elapsed}s — investigating"
        # Attempt soft reset: reapply limit
        guarded || return 0
        source "$HOME/.battopt-swiftbar/config" 2>/dev/null
        sudo -n /usr/local/bin/battopt limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
        rm -f "$state_file"
    fi
}
# === END LAYER 9 ===

# === LAYER 10: SMC ↔ Config Drift Check ===
# If the SMC limit does not match config, reapply and log.
smc_drift_check() {
    source "$HOME/.battopt-swiftbar/config" 2>/dev/null
    local want_upper="${LAST_UPPER:-85}"
    local want_lower="${LAST_LOWER:-80}"

    local status
    status=$(sudo -n /usr/local/bin/battopt status 2>/dev/null)
    [ -z "$status" ] && return 0

    local smc_upper smc_lower
    smc_upper=$(echo "$status" | grep -oE 'upper limit [0-9]+' | grep -oE '[0-9]+' | head -1)
    smc_lower=$(echo "$status" | grep -oE 'lower limit [0-9]+' | grep -oE '[0-9]+' | head -1)

    if [ -n "$smc_upper" ] && [ "$smc_upper" != "$want_upper" ]; then
        log "L10: drift detected SMC=$smc_upper/$smc_lower config=$want_upper/$want_lower"
        guarded || return 0
        sudo -n /usr/local/bin/battopt limit "$want_upper" "$want_lower" >> "$LOG" 2>&1
    fi
}
# === END LAYER 10 ===


daemon_watchdog
ncr_monitor
smc_drift_check

exit 0
