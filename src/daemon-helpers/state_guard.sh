#!/bin/bash
# Shared active-session state; callers must hold the guard lock for mutations.
SG_DIR="${SG_DIR:-$HOME/.battopt-swiftbar}"
SG_LOCK="$SG_DIR/.state_guard.lock"
SG_TOKEN="$SG_DIR/.active_token"
SG_MODE="$SG_DIR/.active_mode"

guard_lock() {
    local owner tries=0
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
}

guard_unlock() {
    [ "$(cat "$SG_LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$SG_LOCK"
}

guard_session_active() {
    case "$(cat "$SG_MODE" 2>/dev/null | tr -d '[:space:]')" in
        charge_full|discharge|hold|calibrating|calibration) return 0 ;;
        *) return 1 ;;
    esac
}

guard_token() { cat "$SG_TOKEN" 2>/dev/null; }

guard_new_token() { printf '%s_%s_%s' "$$" "$(date +%s)" "$1"; }

guard_token_matches() { [ -n "$1" ] && [ "$(guard_token)" = "$1" ]; }

guard_session_begin() {
    local mode="$1" token
    guard_lock || return 1
    token=$(guard_new_token "$mode")
    printf '%s\n' "$token" > "$SG_TOKEN.tmp.$$" &&
        mv "$SG_TOKEN.tmp.$$" "$SG_TOKEN" || { guard_unlock; return 1; }
    printf '%s\n' "$mode" > "$SG_MODE.tmp.$$" &&
        mv "$SG_MODE.tmp.$$" "$SG_MODE" || { guard_unlock; return 1; }
    guard_unlock
    printf '%s\n' "$token"
}

guard_session_end() {
    guard_lock || return 1
    guard_token_matches "$1" || { guard_unlock; return 1; }
    rm -f "$SG_TOKEN"
    printf 'idle\n' > "$SG_MODE.tmp.$$" && mv "$SG_MODE.tmp.$$" "$SG_MODE"
    guard_unlock
}
