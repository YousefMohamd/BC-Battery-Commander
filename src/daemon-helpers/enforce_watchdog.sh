#!/bin/bash

# Layer 15: battery-mode throttle (60s on battery)
source "$HOME/.battopt-swiftbar/.throttle_helper.sh" 2>/dev/null && ac_throttle "enforce" 60

# enforce_watchdog.sh — Layer 12: OS-level enforcement
# Trusts SMC, not battopt exit code.

DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
LOG_FILE="$DASH/.enforce.log"
CONFIG="$DASH/config"
STATE_FILE="$DASH/.enforce_state"
DISC_COOLDOWN_FILE="$DASH/.enforce_last_discharge"
CRIT_COOLDOWN_FILE="$DASH/.enforce_last_critical"
CRIT_COUNT_FILE="$DASH/.enforce_crit_count"
BAT="/usr/local/bin/battopt"

if [ -e "$DASH/.user_shutdown" ]; then
    exit 0
fi

log() {
    echo "[$(date '+%H:%M:%S')] enforce: $1" >> "$LOG_FILE"
}

source "$DASH/state_guard.sh" || exit 1
if guard_session_active; then
    log "skipping: active session ($(cat "$DASH/.active_mode" 2>/dev/null))"
    exit 0
fi


# Read config
[ -f "$CONFIG" ] && source "$CONFIG"
UPPER="${LAST_UPPER:-85}"
LOWER="${LAST_LOWER:-80}"

# Read SMC directly
IOREG=$(ioreg -rn AppleSmartBattery 2>/dev/null)
[ -z "$IOREG" ] && exit 0

CUR=$(echo "$IOREG" | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
MAX=$(echo "$IOREG" | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')
ISCHG=$(echo "$IOREG" | grep -oE '"IsCharging" = [A-Za-z]+' | awk '{print $3}')
EXT=$(echo "$IOREG" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')

[ -z "$CUR" ] || [ -z "$MAX" ] && exit 0

PCT=$(( (CUR * 100 + MAX / 2) / MAX ))

# Only act when on AC + charging + above limit
# Heartbeat (after vars are set)
HB_FILE="$DASH/.enforce_hb"
HB_LAST=0
[ -f "$HB_FILE" ] && HB_LAST=$(cat "$HB_FILE" 2>/dev/null || echo 0)
HB_NOW=$(date +%s)
if [ $((HB_NOW - HB_LAST)) -ge 60 ]; then
    echo "$HB_NOW" > "$HB_FILE"
    echo "[$(date '+%H:%M:%S')] heartbeat: alive (PCT=${PCT} UPPER=${UPPER})" >> "$LOG_FILE"
fi

if [ "$EXT" != "Yes" ] || [ "$ISCHG" != "Yes" ] || [ "$PCT" -le "$UPPER" ]; then
    # Healthy — reset escalation counter, both cooldowns, and the notifier cap
    rm -f "$STATE_FILE" "$DISC_COOLDOWN_FILE" "$CRIT_COOLDOWN_FILE" "$CRIT_COUNT_FILE"
    exit 0
fi

# ═══ VIOLATION DETECTED ═══
# Charging on AC while above UPPER

# Read escalation counter
COUNT=0
LAST_TS=$(date +%s)
[ -f "$STATE_FILE" ] && {
    COUNT=$(cut -d'|' -f1 "$STATE_FILE" 2>/dev/null || echo 0)
    LAST_TS=$(cut -d'|' -f2 "$STATE_FILE" 2>/dev/null || echo 0)
}
NOW=$(date +%s)
ELAPSED=$((NOW - LAST_TS))

# Increment
COUNT=$((COUNT + 1))

log "VIOLATION #$COUNT: PCT=${PCT}% IsChg=Yes UPPER=${UPPER}% (elapsed ${ELAPSED}s)"

# ═══ ESCALATION LADDER ═══

if [ "$COUNT" -eq 1 ]; then
    # First detection: reapply limit (may unstick daemon)
    log "action: reapplying limit ${UPPER}/${LOWER}"
    if ! sudo -n "$BAT" limit "$UPPER" "$LOWER" >> "$LOG_FILE" 2>&1; then log "sudo fail limit $UPPER/$LOWER"; exit 1; fi
fi

if [ "$COUNT" -eq 4 ]; then
    # 60s elapsed: restart daemon
    log "action: restarting daemon (4 violations)"
    sudo pkill -9 -f "Application Support/battopt/battopt daemon" 2>/dev/null
    sleep 2
    sudo launchctl unload /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist 2>/dev/null
    sleep 1
    sudo launchctl load -w /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist 2>/dev/null
    sleep 3
    if ! sudo -n "$BAT" limit "$UPPER" "$LOWER" >> "$LOG_FILE" 2>&1; then log "sudo fail limit $UPPER/$LOWER"; exit 1; fi
fi

# Standalone tracked discharge retry. Fires on every tick while COUNT >= 8,
# but the 300s cooldown gates the actual spawn so a persistent violation does
# not respawn the discharge every enforcement interval.
if [ "$COUNT" -ge 8 ]; then
    LAST_DISCH=0
    [ -f "$DISC_COOLDOWN_FILE" ] && LAST_DISCH=$(cat "$DISC_COOLDOWN_FILE" 2>/dev/null || echo 0)
    if [ $((NOW - LAST_DISCH)) -ge 300 ]; then
        log "action: force tracked discharge to ${UPPER}% (COUNT=$COUNT)"
        # Acquire a guard session first so the rest of the system sees the
        # same state a user-initiated discharge would create, and roll back
        # to `limit` if it fails.
        SD_ID=$(guard_session_begin discharge 2>/dev/null)
        if [ -n "$SD_ID" ]; then
            SD_SESSION="$DASH/.sd_session"
            echo "$SD_ID" > "$SD_SESSION"
            if [ -x "$DASH/sd_watcher.sh" ]; then
                nohup "$DASH/sd_watcher.sh" \
                    "$SD_ID" "$UPPER" "$LOWER" "$SD_SESSION" "$LOG" "$BAT" \
                    >/dev/null 2>&1 &
                disown
            fi
            nohup sudo -n "$BAT" discharge "$UPPER" >/dev/null 2>&1 &
            disown
            sleep 2
            if ! pgrep -f "battopt discharge" >/dev/null 2>&1; then
                log "action: tracked discharge failed — clearing session and reapplying limit"
                if [ "$(cat "$SD_SESSION" 2>/dev/null)" = "$SD_ID" ]; then
                    rm -f "$SD_SESSION" "$DASH/.active_token"
                    echo "idle" > "$DASH/.active_mode"
                fi
                sudo -n "$BAT" limit "$UPPER" "$LOWER" >> "$LOG_FILE" 2>&1
            fi
        else
            log "action: could not acquire guard session — reapplying limit"
            sudo -n "$BAT" limit "$UPPER" "$LOWER" >> "$LOG_FILE" 2>&1
        fi
        echo "$NOW" > "$DISC_COOLDOWN_FILE"
    fi
fi

# Standalone CRITICAL escalation. Fires on every tick while COUNT >= 16, gated
# by a 300s cooldown. The notifier is capped at 3 per violation episode; the
# count file is cleared by the healthy path so a fresh episode restarts at 0.
# COUNT is never reset here — the ladder is monotonic for the episode.
if [ "$COUNT" -ge 16 ]; then
    LAST_CRIT=0
    [ -f "$CRIT_COOLDOWN_FILE" ] && LAST_CRIT=$(cat "$CRIT_COOLDOWN_FILE" 2>/dev/null || echo 0)
    if [ $((NOW - LAST_CRIT)) -ge 300 ]; then
        log "CRITICAL: enforcement failed — possible SMC/binary fault (COUNT=$COUNT)"
        NOTIFY_COUNT=0
        [ -f "$CRIT_COUNT_FILE" ] && NOTIFY_COUNT=$(cat "$CRIT_COUNT_FILE" 2>/dev/null || echo 0)
        case "$NOTIFY_COUNT" in ''|*[!0-9]*) NOTIFY_COUNT=0 ;; esac
        if [ "$NOTIFY_COUNT" -lt 3 ]; then
            NOTIFIER="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
            if [ -x "$NOTIFIER" ]; then
                "$NOTIFIER" -title "BattOpt — CRITICAL" \
                    -message "Charge limit not enforced. Battery at ${PCT}% > ${UPPER}%. Check daemon." \
                    -sound Basso -group battopt >/dev/null 2>&1
            fi
            NOTIFY_COUNT=$((NOTIFY_COUNT + 1))
            echo "$NOTIFY_COUNT" > "$CRIT_COUNT_FILE"
        else
            log "CRITICAL: notification suppressed by cap (${NOTIFY_COUNT}/3)"
        fi
        echo "$NOW" > "$CRIT_COOLDOWN_FILE"
    fi
fi

# Save state
echo "${COUNT}|${NOW}" > "$STATE_FILE"
