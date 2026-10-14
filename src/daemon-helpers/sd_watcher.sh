#!/bin/bash
# Args: SD_ID TARGET LOW SESSION_FILE LOG BAT
SD_ID="$1"
T="$2"
LOW="$3"
SESSION_FILE="$4"
LOG="$5"
BAT="$6"
DASH="$HOME/.battopt-swiftbar"
STATE_GUARD="$DASH/state_guard.sh"
source "$STATE_GUARD" 2>/dev/null || exit 1
# SD_ID is a .sd_session ID, not the .active_token used by guard_token_matches.
# The current dispatch.sh does not create a guard token for discharge sessions.

[ -z "$SD_ID" ] && exit 1
[ -z "$T" ] || [ -z "$LOW" ] && exit 1
[ -z "$SESSION_FILE" ] && SESSION_FILE="$HOME/.battopt-swiftbar/.sd_session"

finish_discharge() {
    local message="$1"
    local current_mode

    current_mode=$(cat "$DASH/.active_mode" 2>/dev/null)
    [ "$current_mode" = "discharge" ] || return 0

    # Recheck ownership immediately before changing shared state.
    [ "$(cat "$SESSION_FILE" 2>/dev/null)" = "$SD_ID" ] || return 0

    if [ -f "$STATE_GUARD" ]; then
        source "$STATE_GUARD" || return 0
        guard_lock || return 0
    fi

    # Recheck after acquiring the lock because another writer may have won it.
    [ "$(cat "$SESSION_FILE" 2>/dev/null)" = "$SD_ID" ] || {
        [ -f "$STATE_GUARD" ] && guard_unlock
        return 0
    }
    [ "$(cat "$DASH/.active_mode" 2>/dev/null)" = "discharge" ] || {
        [ -f "$STATE_GUARD" ] && guard_unlock
        return 0
    }

    sudo -n "$BAT" limit "$T" "$LOW" >/dev/null 2>&1
    echo "[$(date +%H:%M:%S)] sd_watcher: $message" >> "$LOG"
    sudo -n "$BAT" discharge stop >/dev/null 2>&1
    # We already hold guard_lock and verified SD_ID = SESSION_FILE, so it is
    # safe to write idle directly (dispatcher doesn't create .active_token).
    rm -f "$SESSION_FILE"
    echo "idle" > "$DASH/.active_mode"

    [ -f "$STATE_GUARD" ] && guard_unlock
}

for i in $(seq 1 720); do
    sleep 10
    CURRENT=$(cat "$SESSION_FILE" 2>/dev/null || echo "none")
    if [ "$CURRENT" != "$SD_ID" ]; then
        echo "[$(date +%H:%M:%S)] sd_watcher: session invalidated" >> "$LOG"
        sudo -n "$BAT" discharge stop >/dev/null 2>&1
        exit 0
    fi
    P=$(sudo -n "$BAT" status 2>/dev/null | grep -oE 'Capacity [0-9]+' | grep -oE '[0-9]+' | head -1)
    if [ -n "$P" ] && [ "$P" -le "$T" ]; then
        finish_discharge "reached ${P}% — limit ${T}/${LOW}"
        exit 0
    fi
done
finish_discharge "timeout (2h) — killed"
