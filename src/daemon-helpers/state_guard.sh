#!/bin/bash
# Shared active-session state; callers must hold the guard lock for mutations.
# BC state dir: ~/.battery-commander/ is the ONLY live state dir
# (consolidation 2026-11-13, M2: the old-dir fallback is retired — the
# pre-migration dir is a kept, inert backup, never a live target).
# A caller-set SG_DIR wins (tests / dry-runs).
if [ -n "${SG_DIR:-}" ]; then
    : # keep the caller's SG_DIR
elif [ -d "$HOME/.battery-commander" ]; then
    SG_DIR="$HOME/.battery-commander"
else
    echo "ERROR: Battery Commander state dir missing - ~/.battery-commander not found (state_guard)" >&2
    return 1 2>/dev/null || exit 1
fi
SG_LOCK="$SG_DIR/.state_guard.lock"
SG_TOKEN="$SG_DIR/.active_token"
SG_MODE="$SG_DIR/.active_mode"

guard_lock() {
    local owner tries=0
    while ! mkdir "$SG_LOCK" 2>/dev/null; do
        owner=$(cat "$SG_LOCK/pid" 2>/dev/null)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            # Re-read: another process may have acquired the lock since
            # we read the pid — only remove it if it still names the
            # dead owner (audit 2026-11-11, W29).
            if [ "$(cat "$SG_LOCK/pid" 2>/dev/null)" = "$owner" ]; then
                rm -rf "$SG_LOCK"
            fi
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
        charge_full|discharge|hold|calibration) return 0 ;;
        *) return 1 ;;
    esac
}

# read_effective_session
# Read-only accessor for the current logical session mode.
# Reads $SG_MODE (.active_mode), trims whitespace, validates against the
# known set, and returns "idle" on any unknown/empty/missing value.
# No writes, no lock, no sudo, pgrep-free by design: this is a pure read.
read_effective_session() {
    local mode
    mode=$(cat "$SG_MODE" 2>/dev/null | tr -d '[:space:]')
    case "$mode" in
        hold|discharge|charge_full|calibration|idle) printf '%s\n' "$mode" ;;
        *) printf 'idle\n' ;;
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
