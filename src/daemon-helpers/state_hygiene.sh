#!/bin/bash
# state_hygiene.sh — Layer 17
# Detects and cleans polluted/orphaned state files.
# Runs every 5 minutes.

DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/.hygiene.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

CLEANED=0

# ─── Lock probe ───
# .state_guard.lock is a directory with a `pid` file (see state_guard.sh).
# .op.lock is a file written by dispatch.sh `acquire` during intent_apply.
# If either is held by a live PID we must NOT mutate session / mode state:
# dispatch.sh may be mid-transition (write .sd_session, spawn discharge,
# clear token) and cleaning here would orphan the operation (H2/H3).
guard_is_locked() {
    local pid
    if [ -d "$DASH/.state_guard.lock" ]; then
        pid=$(cat "$DASH/.state_guard.lock/pid" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    if [ -f "$DASH/.op.lock" ]; then
        pid=$(cat "$DASH/.op.lock" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# ─── 1. Hold state consistency ───
HAS_OVERRIDE=0
HAS_TOKEN=0
HAS_PREHOLD=0

[ -f "$DASH/.hold_override" ] && HAS_OVERRIDE=1
[ -f "$DASH/.hold_token" ] && HAS_TOKEN=1
[ -f "$DASH/.pre_hold_config" ] && HAS_PREHOLD=1

# If override is present but token is missing → orphaned hold
if [ "$HAS_OVERRIDE" = "1" ] && [ "$HAS_TOKEN" = "0" ]; then
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
# H2: skip when dispatch.sh holds a lock. intent_apply writes .sd_session
# and then spawns the discharge process; if we tick between those two
# steps without this check, we orphan the discharge from its watcher.
if [ -f "$DASH/.sd_session" ]; then
    if guard_is_locked; then
        log "hygiene: lock held — deferring .sd_session cleanup"
    elif ! pgrep -f "battopt discharge" >/dev/null 2>&1; then
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


# ─── 8. Active mode — reset if underlying state is genuinely stale ───
# H1: A hold is legitimate whenever the SMC upper limit matches the saved
# config. guardian.sh LAYER3a creates 'hold' without .hold_override, so
# the old "no override → idle" rule fought LAYER3a on every tick and
# produced the hold↔idle↔discharge oscillation. Compare SMC to config
# instead. When the daemon is unreachable, preserve hold so guardian
# LAYER3 (drift) and LAYER8 (watchdog) can resolve it.
# H3: when a session ends and no discharge/charge/calibration process is
# running, drop the orphan .active_token. Without this, the token is
# stuck until the next dispatch.sh intent_apply.
if [ -f "$DASH/.active_mode" ]; then
    if guard_is_locked; then
        log "hygiene: lock held — deferring .active_mode cleanup"
    else
        AM=$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')
        case "$AM" in
            hold)
                if [ -f "$DASH/.hold_override" ]; then
                    : # explicit hold — keep
                else
                    SMC_UP=$(sudo -n /usr/local/bin/battopt status 2>/dev/null \
                        | grep -oE 'upper limit [0-9]+' \
                        | grep -oE '[0-9]+' | head -1)
                    WANT_UP=85
                    [ -f "$DASH/config" ] && source "$DASH/config" 2>/dev/null
                    WANT_UP="${LAST_UPPER:-85}"
                    if [ -z "$SMC_UP" ]; then
                        : # daemon down — leave hold; guardian LAYER8/LAYER3 resolves
                    elif [ "$SMC_UP" = "$WANT_UP" ]; then
                        : # SMC matches config — legitimate hold, keep
                    else
                        log "hygiene: stale active_mode=hold (SMC=$SMC_UP cfg=$WANT_UP) → idle"
                        echo "idle" > "$DASH/.active_mode"
                        CLEANED=$((CLEANED + 1))
                    fi
                fi
                ;;
            charge_full|discharge|calibration)
                PROC_PAT="battopt $AM"
                [ "$AM" = "charge_full" ] && PROC_PAT="battopt charge"
                if ! pgrep -f "$PROC_PAT" >/dev/null 2>&1; then
                    log "hygiene: stale active_mode=$AM (no process) → idle"
                    echo "idle" > "$DASH/.active_mode"
                    # H3: no process, no session owner — token is orphaned.
                    if [ ! -f "$DASH/.sd_session" ] && [ -s "$DASH/.active_token" ]; then
                        log "hygiene: orphan .active_token (mode=$AM, no process) → cleaned"
                        rm -f "$DASH/.active_token"
                        CLEANED=$((CLEANED + 1))
                    fi
                    CLEANED=$((CLEANED + 1))
                fi
                ;;
            *)
                # Idle or unknown — defensively clear a leftover token.
                if [ -s "$DASH/.active_token" ]; then
                    if ! pgrep -f "battopt discharge" >/dev/null 2>&1 \
                       && ! pgrep -f "battopt charge"    >/dev/null 2>&1 \
                       && ! pgrep -f "battopt calibrate" >/dev/null 2>&1; then
                        log "hygiene: orphan .active_token (mode=${AM:-idle}) → cleaned"
                        rm -f "$DASH/.active_token"
                        CLEANED=$((CLEANED + 1))
                    fi
                fi
                ;;
        esac
    fi
fi

log "hygiene: run complete, cleaned=$CLEANED"
exit 0
