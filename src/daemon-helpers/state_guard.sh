#!/bin/bash
# Shared Protocol: state_guard.sh
SG_DIR="${SG_DIR:-$HOME/.battopt-swiftbar}"
SG_LOCK="$SG_DIR/.state_guard.lock"
SG_TOKEN="$SG_DIR/.active_token"
SG_MODE="$SG_DIR/.active_mode"
SG_SESSION="$SG_DIR/.session"
SG_HEARTBEAT="$SG_DIR/.sentinel_heartbeat"
SG_DESIRED="$SG_DIR/.desired_state"
SG_SEQUENCE="$SG_DIR/.sequence"

guard_lock() {
    local owner tries=0
    mkdir -p "$SG_DIR" 2>/dev/null
    while ! mkdir "$SG_LOCK" 2>/dev/null; do
        owner=$(cat "$SG_LOCK/pid" 2>/dev/null)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$SG_LOCK"
            continue
        fi
        tries=$((tries + 1))
        [ "$tries" -ge 30 ] && return 1
        sleep 0.1
    done
    echo "$$" > "$SG_LOCK/pid"
    return 0
}

guard_unlock() {
    [ "$(cat "$SG_LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$SG_LOCK"
}

next_sequence() {
    local seq=1
    [ -f "$SG_SEQUENCE" ] && seq=$(cat "$SG_SEQUENCE")
    seq=$((seq + 1))
    echo "$seq" > "$SG_SEQUENCE"
    echo "$seq"
}

submit_request() {
    local origin="$1" action="$2" arg1="$3" arg2="$4" arg3="$5" arg4="$6" exp_token="$7" conf_rev="$8"
    local priority=100
    case "$origin" in
        user) priority=300 ;;
        guardian|ac|enforce|wake|sleep|watcher|recovery) priority=200 ;;
    esac
    
    guard_lock || return 1
    
    # Check if existing request has higher priority
    if [ -f "$SG_DESIRED" ]; then
        local old_prio=$(cut -d'|' -f4 "$SG_DESIRED")
        if [ "$old_prio" -gt "$priority" ]; then
            guard_unlock
            return 2 # Rejected: higher priority exists
        fi
    fi
    
    local req_id=$(next_sequence)
    local ts=$(date +%s)
    # Format: VERSION|REQUEST_ID|ORIGIN|PRIORITY|ACTION|ARG1|ARG2|ARG3|ARG4|EXPECTED_TOKEN|CONFIG_REVISION
    echo "1|${req_id}|${origin}|${priority}|${action}|${arg1}|${arg2}|${arg3}|${arg4}|${exp_token}|${conf_rev}" > "$SG_DESIRED"
    guard_unlock
    return 0
}

touch_heartbeat() {
    local owner="$1" token="$2" mode="$3"
    guard_lock || return 1
    local ts=$(date +%s)
    echo "1|${owner}|${token}|${mode}|${ts}" > "$SG_HEARTBEAT"
    guard_unlock
}

check_heartbeat() {
    local owner="$1" token="$2" mode="$3"
    [ -f "$SG_HEARTBEAT" ] || return 1
    local hb=$(cat "$SG_HEARTBEAT")
    local hb_owner=$(echo "$hb" | cut -d'|' -f2)
    local hb_token=$(echo "$hb" | cut -d'|' -f3)
    local hb_mode=$(echo "$hb" | cut -d'|' -f4)
    local hb_ts=$(echo "$hb" | cut -d'|' -f5)
    
    [ "$hb_owner" != "$owner" ] && return 1
    [ "$hb_token" != "$token" ] && return 1
    [ "$hb_mode" != "$mode" ] && return 1
    
    local now=$(date +%s)
    local age=$((now - hb_ts))
    [ "$age" -gt 15 ] && return 1
    [ "$age" -lt 0 ] && return 1
    return 0
}

read_effective_session() {
    [ -f "$SG_SESSION" ] || echo "idle"
    local sess=$(cat "$SG_SESSION")
    local s_mode=$(echo "$sess" | cut -d'|' -f4)
    local s_token=$(echo "$sess" | cut -d'|' -f3)
    local s_owner=$(echo "$sess" | cut -d'|' -f2)
    
    if [ "$s_mode" = "idle" ]; then
        echo "idle"
    elif check_heartbeat "$s_owner" "$s_token" "$s_mode"; then
        echo "$s_mode"
    else
        echo "idle"
    fi
}

guard_session_active() {
    local mode=$(read_effective_session)
    case "$mode" in
        charge_full|discharge|hold|calibration) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Legacy Compatibility ---
atomic_write() {
    local file="$1" content="$2"
    local tmp="${file}.tmp.$$"
    printf '%s' "$content" > "$tmp" && mv "$tmp" "$file"
}
guard_new_token() { printf '%s_%s_%s' "$$" "$(date +%s)" "$1"; }
guard_token() { cat "$SG_TOKEN" 2>/dev/null; }
guard_token_matches() { [ -n "$1" ] && [ "$(guard_token)" = "$1" ]; }
guard_token_write_locked() {
    local mode="$1" token
    token=$(guard_new_token "$mode")
    printf '%s\n' "$token" > "$SG_TOKEN"
    printf '%s\n' "$mode" > "$SG_MODE"
    printf '%s\n' "$token"
}
guard_token_clear_locked() {
    rm -f "$SG_TOKEN"
    printf 'idle\n' > "$SG_MODE"
}
guard_session_begin() {
    guard_lock || return 1
    local token=$(guard_token_write_locked "$1")
    guard_unlock
    echo "$token"
}
guard_session_end() {
    guard_lock || return 1
    if guard_token_matches "$1"; then
        guard_token_clear_locked
        guard_unlock
        return 0
    fi
    guard_unlock
    return 1
}
