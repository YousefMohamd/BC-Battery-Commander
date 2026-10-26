#!/bin/bash

# Layer 15: throttle on battery (30s — but detect AC return fast)
source "/Users/Yousef/.battopt-swiftbar/.throttle_helper.sh" 2>/dev/null

# ac_watcher.sh — detect AC state transitions and reapply intent
# Runs every 10 seconds via LaunchAgent

DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
STATE_FILE="$DASH/.ac_state"
DISPATCH="$DASH/dispatch.sh"
CONFIG="$DASH/config"

source "$DASH/state_guard.sh" || exit 1

if [ -e "$DASH/.user_shutdown" ]; then
    exit 0
fi

log() { echo "[$(date '+%H:%M:%S')] ac_watcher: $1" >> "$LOG"; }

# Read current AC state
IOREG=$(ioreg -rn AppleSmartBattery 2>/dev/null)
EXT=$(echo "$IOREG" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
[ -z "$EXT" ] && exit 0

# Read previous state
PREV=""
[ -f "$STATE_FILE" ] && PREV=$(cat "$STATE_FILE" 2>/dev/null | tr -d '[:space:]')

# Save new state
echo "$EXT" > "$STATE_FILE"

# Detect transitions
if [ "$PREV" = "No" ] && [ "$EXT" = "Yes" ]; then
    # Respect active session — do NOT override charge_full / discharge / calibration
    ACTIVE_MODE=$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')
    [ -z "$ACTIVE_MODE" ] && ACTIVE_MODE="idle"
    if guard_session_active; then
        log "AC CONNECTED — skipping (active_mode=$ACTIVE_MODE)"
        exit 0
    fi
    if [ -f "$DASH/.apg_paused" ]; then
        log "AC CONNECTED - skipping (APG thermal pause)"
        exit 0
    fi
    log "AC CONNECTED — reapplying intent"
    # Read current config
    [ -f "$CONFIG" ] && source "$CONFIG"
    UPPER="${LAST_UPPER:-85}"
    LOWER="${LAST_LOWER:-80}"
    # Reapply limit
    sudo -n /usr/local/bin/battopt limit "$UPPER" "$LOWER" >> "$LOG" 2>&1
    log "applied limit $UPPER/$LOWER after AC connect"
elif [ "$PREV" = "Yes" ] && [ "$EXT" = "No" ]; then
    log "AC DISCONNECTED — sailing continues on battery"
fi
