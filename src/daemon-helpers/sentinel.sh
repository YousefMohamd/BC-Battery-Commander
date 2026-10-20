#!/bin/bash
# Sentinel Executor — The Single Owner of Hardware Mutations
HOME="${HOME:-/Users/Yousef}"
DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
BAT="/usr/local/bin/battopt"
source "$DASH/state_guard.sh" || exit 1

log() { echo "[$(date '+%H:%M:%S')] sentinel: $1" >> "$LOG"; }

# 1. Lifetime Ownership
LIFETIME_TOKEN=""
LIFETIME_CONTEXT=""

acquire_lifetime() {
    local SG_LOCK="$DASH/.sentinel.lock"
    local SG_ACQUIRED_TOKEN=""
    local SG_ACQUIRED_CONTEXT=""
    local SG_NONBLOCKING=1

    if guard_lock; then
        LIFETIME_TOKEN="$SG_ACQUIRED_TOKEN"
        LIFETIME_CONTEXT="$SG_ACQUIRED_CONTEXT"
        if ! atomic_write "$DASH/.sentinel.lock/pid" "$$"$'\n'; then
            release_lifetime
            return 1
        fi
        return 0
    fi
    return 1
}

release_lifetime() {
    local SG_LOCK="$DASH/.sentinel.lock"
    local SG_ACQUIRED_TOKEN="$LIFETIME_TOKEN"
    local SG_ACQUIRED_CONTEXT="$LIFETIME_CONTEXT"
    local SG_NONBLOCKING=1
    
    if _guard_owned; then
        rm -f "$DASH/.sentinel.lock/pid"
        guard_unlock
    fi
}

if ! acquire_lifetime; then
    log "Sentinel already running or lock failed."
    exit 1
fi

OWNER_ID="${LIFETIME_TOKEN}"

# 2. State Variables
STOP_REQUESTED=0
CURRENT_MODE="idle"
CURRENT_TOKEN="-"
CURRENT_PHASE="running"
CURRENT_ORIGIN="idle"
CURRENT_TARGET="-"

# Command tracking
COMMAND_PID=""
COMMAND_KIND=""
COMMAND_DEADLINE=0
COMMAND_OUTPUT=""
COMMAND_STATUS=0

DIS_PID=""
DIS_TARGET=""
DIS_CANCEL_REQUESTED=0

LAST_HB=0

# 3. Traps
trap 'STOP_REQUESTED=1' INT TERM
trap 'release_lifetime; [ -n "$COMMAND_OUTPUT" ] && rm -f "$COMMAND_OUTPUT"' EXIT

# 4. Async Command Runner
start_command() {
    local kind="$1" timeout="$2"; shift 2
    COMMAND_KIND="$kind"
    COMMAND_DEADLINE=$(( $(date +%s) + timeout ))
    COMMAND_OUTPUT=$(mktemp "$DASH/.cmd_out.XXXXXX")
    "$@" > "$COMMAND_OUTPUT" 2>&1 < /dev/null &
    COMMAND_PID=$!
}

poll_command() {
    [ -z "$COMMAND_PID" ] && return 0
    if kill -0 "$COMMAND_PID" 2>/dev/null; then
        if [ "$(date +%s)" -gt "$COMMAND_DEADLINE" ]; then
            log "Command $COMMAND_KIND timed out."
            kill -9 "$COMMAND_PID" 2>/dev/null
            COMMAND_PID=""
            return 1
        fi
        return 0
    else
        wait "$COMMAND_PID" 2>/dev/null
        COMMAND_STATUS=$?
        log "Command $COMMAND_KIND finished with status $COMMAND_STATUS."
        COMMAND_PID=""
        return 1
    fi
}

# 5. Action Handlers
handle_set_limit() {
    local u="$1" l="$2" s="$3" g="$4"
    log "Setting limit $u/$l (Sailing: $s, Gap: $g)"
    # Mock apply for now
    sudo -n "$BAT" limit "$u" "$l" > /dev/null 2>&1
    atomic_write "$DASH/config" "LAST_UPPER=$u\nLAST_LOWER=$l\nSAILING=$s\nSAIL_GAP=$g\n"
    CURRENT_MODE="idle"
    guard_publish_session "$OWNER_ID" "-" "idle" "running" "user" "-" "$u" "$l" "$(date +%s)" "0"
}

handle_hold_current() {
    local cur=$(sudo -n "$BAT" status 2>/dev/null | grep -oE 'Capacity [0-9]+' | grep -oE '[0-9]+' | head -1)
    if [ -n "$cur" ]; then
        local l=$((cur - 1))
        [ "$l" -lt 20 ] && l=20
        log "Holding at $cur/$l"
        sudo -n "$BAT" limit "$cur" "$l" > /dev/null 2>&1
        atomic_write "$DASH/config" "LAST_UPPER=$cur\nLAST_LOWER=$l\nSAILING=false\nSAIL_GAP=1\n"
        CURRENT_MODE="hold"
        CURRENT_TOKEN="tok_${OWNER_ID}_${cur}"
        guard_publish_session "$OWNER_ID" "$CURRENT_TOKEN" "hold" "running" "user" "-" "$cur" "$l" "$(date +%s)" "0"
    fi
}

handle_sailing_discharge() {
    local u="$1" l="$2"
    log "Starting sailing discharge to $l"
    sudo -n "$BAT" discharge "$l" > /dev/null 2>&1 &
    DIS_PID=$!
    CURRENT_MODE="discharge"
    CURRENT_TOKEN="tok_${OWNER_ID}_dis"
    guard_publish_session "$OWNER_ID" "$CURRENT_TOKEN" "discharge" "running" "guardian" "$l" "$u" "$l" "$(date +%s)" "0"
}

# 6. Main Loop
log "Sentinel initialized. OWNER=$OWNER_ID"

while [ "$STOP_REQUESTED" -eq 0 ]; do
    now=$(date +%s)

    # Poll commands
    poll_command

    # Monitor discharge
    if [ -n "$DIS_PID" ]; then
        if ! kill -0 "$DIS_PID" 2>/dev/null; then
            log "Discharge client exited. Restoring limits."
            sudo -n "$BAT" discharge stop > /dev/null 2>&1
            source "$DASH/config" 2>/dev/null || true
            handle_set_limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" "${SAILING:-true}" "${SAIL_GAP:-5}"
            DIS_PID=""
        fi
    fi

    # Heartbeat
    if [ $((now - LAST_HB)) -ge 5 ]; then
        touch_heartbeat "$OWNER_ID" "$CURRENT_TOKEN" "$CURRENT_MODE"
        LAST_HB=$now
    fi

    # Consume Request (Non-blocking)
    if [ -z "$COMMAND_PID" ] && [ -z "$DIS_PID" ]; then
        local SG_NONBLOCKING=1
        if guard_lock; then
            if [ -f "$SG_DESIRED" ]; then
                if _guard_read_record "$SG_DESIRED" && guard_parse_request "$SG_RECORD"; then
                    req_id="$SG_R_ID"
                    action="$SG_R_ACTION"
                    a1="$SG_R_ARG1"
                    a2="$SG_R_ARG2"
                    a3="$SG_R_ARG3"
                    a4="$SG_R_ARG4"
                    
                    rm -f "$SG_DESIRED"
                    guard_unlock
                    
                    case "$action" in
                        set_limit) handle_set_limit "$a1" "$a2" "$a3" "$a4" ;;
                        hold_current) handle_hold_current ;;
                        sailing_discharge) handle_sailing_discharge "$a1" "$a2" ;;
                        *) log "Unknown action: $action" ;;
                    esac
                else
                    rm -f "$SG_DESIRED"
                    guard_unlock
                    log "Malformed request discarded."
                fi
            else
                guard_unlock
            fi
        fi
    fi

    sleep 1
done

log "Sentinel shutting down."
