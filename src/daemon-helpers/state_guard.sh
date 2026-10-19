#!/bin/bash
# Shared active-session state; callers must hold the guard lock for mutations.
SG_DIR="${SG_DIR:-$HOME/.battopt-swiftbar}"
SG_LOCK="$SG_DIR/.state_guard.lock"
SG_TOKEN="$SG_DIR/.active_token"
SG_MODE="$SG_DIR/.active_mode"

guard_lock() {
    local owner age tries=0
    while ! mkdir "$SG_LOCK" 2>/dev/null; do
        owner=$(cat "$SG_LOCK/pid" 2>/dev/null)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$SG_LOCK"
            continue
        fi
        # Never expire a lock held by a live process.
        if [ -z "$owner" ]; then
            age=$(( $(date +%s) - $(stat -f %m "$SG_LOCK" 2>/dev/null || echo 0) ))
            [ "$age" -gt 30 ] && { rm -rf "$SG_LOCK"; continue; }
        fi
        tries=$((tries + 1))
        [ "$tries" -ge 30 ] && return 1
        sleep 0.1
    done
    echo "$$" > "$SG_LOCK/pid"
}

guard_unlock() {
    [ "$(cat "$SG_LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$SG_LOCK"
}


guard_reap_stale() {
    local mode token age
    mode=$(cat "$SG_MODE" 2>/dev/null | tr -d '[:space:]')
    # Persistent holds have no worker process and must not expire.
    [ "$mode" = "hold" ] && return 1
    token=$(cat "$SG_TOKEN" 2>/dev/null); [ -z "$token" ] && return 1
    if ! pgrep -f "battopt (discharge|charge|calibrate)" >/dev/null 2>&1 && ! pgrep -f "sd_watcher.sh" >/dev/null 2>&1; then
        age=$(( $(date +%s) - $(stat -f %m "$SG_TOKEN" 2>/dev/null || echo 0) ))
        [ "$age" -gt 600 ] || return 1
        guard_lock || return 1
        if guard_token_matches "$token" \
            && [ "$(cat "$SG_MODE" 2>/dev/null | tr -d '[:space:]')" = "$mode" ] \
            && ! pgrep -f "battopt (discharge|charge|calibrate)" >/dev/null 2>&1 \
            && ! pgrep -f "sd_watcher.sh" >/dev/null 2>&1; then
            guard_token_clear_locked
            if [ "$(cat "$SG_DIR/.sd_session" 2>/dev/null)" = "$token" ]; then
                rm -f "$SG_DIR/.sd_session"
            fi
            echo "[$(date +%H:%M:%S)] reaped stale $mode $token age $age" >> "$HOME/.battopt-swiftbar/actions.log" 2>&1
        fi
        guard_unlock; return 0
    fi
    return 1
}
guard_session_active() {
    guard_reap_stale >/dev/null 2>&1
    case "$(cat "$SG_MODE" 2>/dev/null | tr -d '[:space:]')" in
        charge_full|discharge|hold|calibration) return 0 ;;
        *) return 1 ;;
    esac
}

guard_token() { cat "$SG_TOKEN" 2>/dev/null; }

guard_new_token() { printf '%s_%s_%s' "$$" "$(date +%s)" "$1"; }

guard_token_matches() { [ -n "$1" ] && [ "$(guard_token)" = "$1" ]; }

guard_token_write_locked() {
    local mode="$1" token
    token=$(guard_new_token "$mode") || return 1
    printf '%s\n' "$token" > "$SG_TOKEN.tmp.$$" \
        && mv "$SG_TOKEN.tmp.$$" "$SG_TOKEN" || return 1
    printf '%s\n' "$mode" > "$SG_MODE.tmp.$$" \
        && mv "$SG_MODE.tmp.$$" "$SG_MODE" || return 1
    printf '%s\n' "$token"
}

guard_token_clear_locked() {
    rm -f "$SG_TOKEN"
    printf 'idle\n' > "$SG_MODE.tmp.$$" \
        && mv "$SG_MODE.tmp.$$" "$SG_MODE"
}

guard_session_begin() {
    local mode="$1" token
    guard_lock || return 1
    token=$(guard_token_write_locked "$mode") || {
        guard_unlock
        return 1
    }
    guard_unlock
    printf '%s\n' "$token"
}

guard_session_end() {
    guard_lock || return 1
    guard_token_matches "$1" || {
        guard_unlock
        return 1
    }
    guard_token_clear_locked
    local result=$?
    guard_unlock
    return "$result"
}
