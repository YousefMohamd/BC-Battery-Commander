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
                    if ! [[ "$R_A1" =~ ^[0-9]+$ &&
                            "$R_A2" =~ ^[0-9]+$ &&
                            "$R_A4" =~ ^[0-9]+$ ]] ||
                       [ "$R_A1" -lt 50 ] || [ "$R_A1" -gt 100 ] ||
                       [ "$R_A2" -lt 20 ] || [ "$R_A2" -ge "$R_A1" ] ||
                       [ "$R_A4" -lt 1 ] || [ "$R_A4" -gt 30 ] ||
                       { [ "$R_A3" != "true" ] && [ "$R_A3" != "false" ]; }; then
                        log "Rejected invalid set_limit arguments"
                        sleep 1
                        continue
                    fi

                    if [ "$CURRENT_MODE" = "discharge" ]; then
                        if ! sudo -n "$BAT" discharge stop >> "$LOG" 2>&1; then
                            log "set_limit: discharge stop failed; config and session unchanged"
                            sleep 1
                            continue
                        fi

                        # Wait at most five seconds for the tracked client to exit.
                        DIS_WAIT=0
                        while kill -0 "$DIS_PID" 2>/dev/null &&
                              [ "$DIS_WAIT" -lt 50 ]; do
                            sleep 0.1
                            DIS_WAIT=$((DIS_WAIT + 1))
                        done
                        if kill -0 "$DIS_PID" 2>/dev/null; then
                            log "set_limit: discharge still running after five seconds; request abandoned"
                            sleep 1
                            continue
                        fi
                        wait "$DIS_PID" 2>/dev/null || true
                    fi

                    if ! sudo -n "$BAT" limit "$R_A1" "$R_A2" >> "$LOG" 2>&1; then
                        log "set_limit failed; config and session unchanged"
                        sleep 1
                        continue
                    fi

                    CONFIG_CONTENT=$(
                        if [ -f "$DASH/config" ]; then
                            grep -vE '^(LAST_UPPER|LAST_LOWER|SAILING|SAIL_GAP)=' "$DASH/config"
                        fi
                        printf 'LAST_UPPER=%s\nLAST_LOWER=%s\nSAILING=%s\nSAIL_GAP=%s\n' \
                            "$R_A1" "$R_A2" "$R_A3" "$R_A4"
                    )
                    if ! atomic_write "$DASH/config" "$CONFIG_CONTENT"$'\n'; then
                        log "set_limit: hardware applied, but config save failed"
                        sleep 1
                        continue
                    fi

                    CURRENT_MODE="idle"; CURRENT_TOKEN="-"
                    atomic_write "$SG_SESSION" \
                        "1|$OWNER_ID|-|idle|running|-|-|-|-|$(date +%s)|0"$'\n'
                    atomic_write "$SG_MODE" $'idle\n'
                    rm -f "$SG_TOKEN" "$DASH/.status_cache"
                    touch_heartbeat "$OWNER_ID" "-" "idle"
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
                        echo "hold" > "$SG_MODE"
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
                    echo "discharge" > "$SG_MODE"
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
            echo "idle" > "$SG_MODE"
            rm -f "$SG_TOKEN"
        fi
    fi
    
    sleep 1
done
