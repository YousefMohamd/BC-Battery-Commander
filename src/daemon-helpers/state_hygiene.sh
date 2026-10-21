#!/bin/bash
# state_hygiene.sh — Layer 17
# Detects and cleans polluted/orphaned state files.
# Runs every 5 minutes.

DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/.hygiene.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

CLEANED=0

# ─── 1. Hold state consistency ───
HAS_OVERRIDE=0
HAS_TOKEN=0
HAS_PREHOLD=0

[ -f "$DASH/.hold_override" ] && HAS_OVERRIDE=1
[ -f "$DASH/.hold_token" ] && HAS_TOKEN=1
[ -f "$DASH/.pre_hold_config" ] && HAS_PREHOLD=1

# If override is present but token is missing → orphaned hold
if [ "$HAS_OVERRIDE" = "1" ] && [ "$HAS_TOKEN" = "0" ]; then
    # Could be old hold that finished; but if no discharge and
    # config already reflects the hold → safe to clear override
    log "hygiene: orphaned .hold_override (no token) → cleaning"
    rm -f "$DASH/.hold_override"
    CLEANED=$((CLEANED + 1))
fi

# If token is present but override is gone → orphaned token
if [ "$HAS_TOKEN" = "1" ] && [ "$HAS_OVERRIDE" = "0" ]; then
    log "hygiene: orphaned .hold_token (no override) → cleaning"
    rm -f "$DASH/.hold_token"
    CLEANED=$((CLEANED + 1))
fi

# If pre_hold_config is present but no active hold → stale backup
if [ "$HAS_PREHOLD" = "1" ] && [ "$HAS_OVERRIDE" = "0" ]; then
    log "hygiene: stale .pre_hold_config (no hold) → cleaning"
    rm -f "$DASH/.pre_hold_config"
    CLEANED=$((CLEANED + 1))
fi

# ─── 2. Session file — should match a running discharge ───
if [ -f "$DASH/.sd_session" ]; then
    if ! pgrep -f "battopt discharge" >/dev/null 2>&1; then
        # No discharge running
        SES=$(cat "$DASH/.sd_session" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$SES" ]; then
            log "hygiene: stale .sd_session ($SES) — no discharge process"
            rm -f "$DASH/.sd_session"
            CLEANED=$((CLEANED + 1))
        fi
    fi
fi

# ─── 3. Caches — clear if too old ───
NOW=$(date +%s)

clear_if_old() {
    local file="$1"
    local max_age="$2"
    local label="$3"
    [ -f "$file" ] || return 0
    local mtime=$(stat -f %m "$file" 2>/dev/null || echo 0)
    local age=$((NOW - mtime))
    if [ "$age" -gt "$max_age" ]; then
        log "hygiene: $label age ${age}s > ${max_age}s → cleared"
        rm -f "$file"
        CLEANED=$((CLEANED + 1))
    fi
}

clear_if_old "$DASH/.status_cache" 60 "status_cache"
clear_if_old "$DASH/.wake_cache"   600 "wake_cache"
clear_if_old "$DASH/.usb_cache"    600 "usb_cache"
clear_if_old "$DASH/.ac_cache"     300 "ac_cache"

# ─── 4. Throttle state files (older than 1 hour) ───
for f in "$DASH"/.throttle_*; do
    [ -f "$f" ] || continue
    NAME=$(basename "$f")
    clear_if_old "$f" 3600 "$NAME"
done

# ─── 5. Locks — clean if PID dead ───
for lockfile in "$DASH/.op.lock" "$DASH/.launch.lock"; do
    [ -f "$lockfile" ] || continue
    PID=$(cat "$lockfile" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
        log "hygiene: dead lock $(basename $lockfile) (pid=$PID) → cleaned"
        rm -f "$lockfile"
        CLEANED=$((CLEANED + 1))
    fi
done

# ─── 6. Notify state files — clear based on cooldown TTL ───
# Files under .notify/ have embedded timestamps. If older than cooldown,
# they can be safely removed (they only prevent duplicate notifications).
if [ -d "$DASH/.notify" ]; then
    for f in "$DASH/.notify"/*; do
        [ -f "$f" ] || continue
        NAME=$(basename "$f")
        case "$NAME" in
            temp_critical|temp_high) MAX=1800 ;;
            low_batt|battery_low_warning) MAX=1800 ;;
            battery_critical) MAX=900 ;;
            daemon_recovery) MAX=600 ;;
            sd_complete) MAX=60 ;;
            hold_reached_*) MAX=3600 ;;
            *) MAX=86400 ;;
        esac
        clear_if_old "$f" "$MAX" "notify/$NAME"
    done
fi

# ─── 7. Trim hygiene log itself ───
if [ -f "$LOG" ]; then
    SIZE=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
    if [ "${SIZE:-0}" -gt 51200 ]; then
        tail -200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
        log "hygiene: log trimmed (was ${SIZE}B)"
    fi
fi


# ─── 8. Active mode — reset if underlying process is gone ───
if [ -f "$DASH/.active_mode" ]; then
    AM=$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')
    case "$AM" in
        hold)
            # Hold without override → stale
            if [ ! -f "$DASH/.hold_override" ]; then
                log "hygiene: stale active_mode=hold → idle"
                echo "idle" > "$DASH/.active_mode"
                CLEANED=$((CLEANED + 1))
            fi
            ;;
        charge_full|discharge|calibration)
            # Process should be running
            if ! pgrep -f "battopt $AM" >/dev/null 2>&1 && \
               ! pgrep -f "battopt $([ "$AM" = "charge_full" ] && echo charge || echo $AM)" >/dev/null 2>&1; then
                log "hygiene: stale active_mode=$AM (no process) → idle"
                echo "idle" > "$DASH/.active_mode"
                CLEANED=$((CLEANED + 1))
            fi
            ;;
    esac
fi

log "hygiene: run complete, cleaned=$CLEANED"
exit 0
