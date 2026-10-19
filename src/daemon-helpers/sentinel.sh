#!/bin/bash
# Sentinel Executor
HOME="${HOME:-/Users/Yousef}"
DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
BAT="/usr/local/bin/battopt"
source "$DASH/state_guard.sh" || exit 1

log() { echo "[$(date '+%H:%M:%S')] sentinel: $1" >> "$LOG"; }

# Acquire lifetime lock
LOCK="$DASH/.sentinel.lock"
mkdir -p "$DASH"
if ! mkdir "$LOCK" 2>/dev/null; then
    OLD_PID=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Sentinel already running (PID $OLD_PID)"
        exit 0
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
OWNER_ID="$$-$(date +%s)"

cleanup() {
    rm -rf "$LOCK"
    touch_heartbeat "$OWNER_ID" "-" "idle"
    exit 0
}
trap cleanup EXIT TERM INT

log "Sentinel started (OWNER=$OWNER_ID)"

# State machine variables
CURRENT_MODE="idle"
CURRENT_TOKEN="-"
LAST_HB=0

# Loop
while true; do
    now=$(date +%s)
    
    # 1. Heartbeat (every 5s)
    if [ $((now - LAST_HB)) -ge 5 ]; then
        touch_heartbeat "$OWNER_ID" "$CURRENT_TOKEN" "$CURRENT_MODE"
        LAST_HB=$now
    fi
    
    # 2. Check desired state
    if [ -f "$SG_DESIRED" ]; then
        guard_lock || continue
        # Re-read under lock
        if [ -f "$SG_DESIRED" ]; then
            REQ=$(cat "$SG_DESIRED")
            rm -f "$SG_DESIRED"
            guard_unlock
            
            # Parse Request
            R_ACTION=$(echo "$REQ" | cut -d'|' -f5)
            R_A1=$(echo "$REQ" | cut -d'|' -f6)
            R_A2=$(echo "$REQ" | cut -d'|' -f7)
            R_A3=$(echo "$REQ" | cut -d'|' -f8)
            R_A4=$(echo "$REQ" | cut -d'|' -f9)
            
            log "Executing request: $R_ACTION ($R_A1 $R_A2)"
            
            case "$R_ACTION" in
                set_limit)
                    sudo -n "$BAT" limit "$R_A1" "$R_A2" >> "$LOG" 2>&1
                    # Save config
                    echo "LAST_UPPER=$R_A1" > "$DASH/config"
                    echo "LAST_LOWER=$R_A2" >> "$DASH/config"
                    echo "SAILING=$R_A3" >> "$DASH/config"
                    echo "SAIL_GAP=$R_A4" >> "$DASH/config"
                    CURRENT_MODE="idle"; CURRENT_TOKEN="-"
                    echo "1|$OWNER_ID|-|idle|running|-|-|-|-|$(date +%s)|0" > "$SG_SESSION"
                    ;;
                hold_current)
                    CUR=$(sudo -n "$BAT" status 2>/dev/null | grep -oE 'Capacity [0-9]+' | grep -oE '[0-9]+' | head -1)
                    if [ -n "$CUR" ]; then
                        L=$((CUR - 1))
                        [ "$L" -lt 20 ] && L=20
                        sudo -n "$BAT" limit "$CUR" "$L" >> "$LOG" 2>&1
                        echo "LAST_UPPER=$CUR" > "$DASH/config"
                        echo "LAST_LOWER=$L" >> "$DASH/config"
                        echo "SAILING=false" >> "$DASH/config"
                        echo "SAIL_GAP=1" >> "$DASH/config"
                        CURRENT_MODE="hold"
                        CURRENT_TOKEN="tok_${OWNER_ID}_${now}"
                        echo "1|$OWNER_ID|$CURRENT_TOKEN|hold|running|user|-|-|-|$now|0" > "$SG_SESSION"
                        echo "hold" > "$SG_ACTIVE_MODE"
                        echo "$CURRENT_TOKEN" > "$SG_TOKEN"
                    fi
                    ;;
                sailing_discharge)
                    # Simulated discharge
                    TARGET="$R_A2"
                    log "Starting sailing discharge to $TARGET"
                    sudo -n "$BAT" discharge "$TARGET" >> "$LOG" 2>&1 &
                    DIS_PID=$!
                    CURRENT_MODE="discharge"
                    CURRENT_TOKEN="tok_${OWNER_ID}_${now}"
                    echo "1|$OWNER_ID|$CURRENT_TOKEN|discharge|running|guardian|$TARGET|$R_A1|$R_A2|$now|0" > "$SG_SESSION"
                    echo "discharge" > "$SG_ACTIVE_MODE"
                    echo "$CURRENT_TOKEN" > "$SG_TOKEN"
                    ;;
                reconcile)
                    if [ "$CURRENT_MODE" = "idle" ]; then
                        source "$DASH/config"
                        sudo -n "$BAT" limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
                    fi
                    ;;
            esac
        else
            guard_unlock
        fi
    fi
    
    # 3. Monitor active session
    if [ "$CURRENT_MODE" = "discharge" ]; then
        if ! kill -0 "$DIS_PID" 2>/dev/null; then
            log "Discharge completed. Restoring limits."
            sudo -n "$BAT" discharge stop >> "$LOG" 2>&1
            source "$DASH/config"
            sudo -n "$BAT" limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
            CURRENT_MODE="idle"; CURRENT_TOKEN="-"
            echo "1|$OWNER_ID|-|idle|running|-|-|-|-|$now|0" > "$SG_SESSION"
            echo "idle" > "$SG_ACTIVE_MODE"
            rm -f "$SG_TOKEN"
        fi
    fi
    
    sleep 1
done
