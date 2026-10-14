#!/bin/bash

# Layer 15: battery-mode throttle (60s on battery)
source "/Users/Yousef/.battopt-swiftbar/.throttle_helper.sh" 2>/dev/null && ac_throttle "enforce" 60

# enforce_watchdog.sh — Layer 12: OS-level enforcement
# Trusts SMC, not battopt exit code.

DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
LOG_FILE="$DASH/.enforce.log"
CONFIG="$DASH/config"
STATE_FILE="$DASH/.enforce_state"

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

if [ "$EXT" != "Yes" ] || [ "$ISCHG" != "Yes" ] || [ "$PCT" -lt "$UPPER" ]; then
    # Healthy — reset escalation counter
    rm -f "$STATE_FILE"
    exit 0
fi

# ═══ VIOLATION DETECTED ═══
# Charging on AC while at/above UPPER

# Read escalation counter
COUNT=0
LAST_TS=0
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
    if ! sudo -n /usr/local/bin/battopt limit "$UPPER" "$LOWER" >> "$LOG_FILE" 2>&1; then log "sudo fail limit $UPPER/$LOWER"; exit 1; fi

elif [ "$COUNT" -eq 4 ]; then
    # 60s elapsed: restart daemon
    log "action: restarting daemon (4 violations)"
    sudo pkill -9 -f "Application Support/battopt/battopt daemon" 2>/dev/null
    sleep 2
    sudo launchctl unload /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist 2>/dev/null
    sleep 1
    sudo launchctl load -w /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist 2>/dev/null
    sleep 3
    if ! sudo -n /usr/local/bin/battopt limit "$UPPER" "$LOWER" >> "$LOG_FILE" 2>&1; then log "sudo fail limit $UPPER/$LOWER"; exit 1; fi

elif [ "$COUNT" -eq 8 ]; then
    # 120s elapsed: force discharge
    log "action: force discharge to ${UPPER}% (8 violations)"
    sudo -n /usr/local/bin/battopt discharge "$UPPER" >> "$LOG_FILE" 2>&1

elif [ "$COUNT" -ge 16 ]; then
    # 240s elapsed: critical alert
    log "CRITICAL: enforcement failed for 240s — possible SMC/binary fault"
    NOTIFIER="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
    if [ -x "$NOTIFIER" ]; then
        "$NOTIFIER" -title "BattOpt — CRITICAL" \
            -message "Charge limit not enforced. Battery at ${PCT}% > ${UPPER}%. Check daemon." \
            -sound Basso -group battopt >/dev/null 2>&1
    fi
    # Reset to avoid spam, but keep escalating every 16
    COUNT=15
fi

# Save state
echo "${COUNT}|${NOW}" > "$STATE_FILE"
