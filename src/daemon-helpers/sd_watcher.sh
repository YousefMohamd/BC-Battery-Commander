#!/bin/bash
# Args: SD_ID TARGET LOW SESSION_FILE LOG BAT [RESTORE_UPPER]
SD_ID="$1"
T="$2"
LOW="$3"
SESSION_FILE="$4"
LOG="$5"
BAT="$6"
RESTORE_UPPER="${7:-$T}"
DASH="$HOME/.battopt-swiftbar"
STATE_GUARD="$DASH/state_guard.sh"
source "$STATE_GUARD" 2>/dev/null || exit 1
trap 'exit 0' TERM INT
# Do not use set -e — sudo -n failures must be handled explicitly
# SD_ID is the guarded ownership token stored in .sd_session.

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

    guard_lock || return 1

    # Recheck after acquiring the lock because another writer may have won it.
    [ "$(cat "$SESSION_FILE" 2>/dev/null)" = "$SD_ID" ] || {
        guard_unlock
        return 0
    }
    [ "$(cat "$DASH/.active_mode" 2>/dev/null)" = "discharge" ] || {
        guard_unlock
        return 0
    }
    guard_token_matches "$SD_ID" || {
        guard_unlock
        return 0
    }

    # Stop first so the discharge worker cannot overwrite the restored limit.
    if ! sudo -n "$BAT" discharge stop >> "$LOG" 2>&1; then
        echo "[$(date +%H:%M:%S)] sd_watcher: discharge stop failed" >> "$LOG"
        guard_unlock
        return 1
    fi
    sudo -n pkill -9 -f '/usr/local/bin/battopt discharge ' 2>/dev/null || true
    if ! sudo -n "$BAT" limit "$RESTORE_UPPER" "$LOW" >> "$LOG" 2>&1; then
        echo "[$(date +%H:%M:%S)] sd_watcher: limit $RESTORE_UPPER/$LOW failed" >> "$LOG"
        guard_unlock
        return 1
    fi
    echo "[$(date +%H:%M:%S)] sd_watcher: $message" >> "$LOG"
    # Clear only this session, using the shared atomic mode write.
    guard_token_clear_locked
    local result=$?
    [ "$result" -eq 0 ] && rm -f "$SESSION_FILE"

    guard_unlock
    return "$result"
}

for i in $(seq 1 720); do
    sleep 10
    CURRENT=$(cat "$SESSION_FILE" 2>/dev/null || echo "none")
    if [ "$CURRENT" != "$SD_ID" ]; then
        # A replacement session owns the hardware. Never stop or clear it.
        guard_session_end "$SD_ID" >/dev/null 2>&1 || true
        echo "[$(date +%H:%M:%S)] sd_watcher: session invalidated" >> "$LOG"
        exit 0
    fi
    guard_token_matches "$SD_ID" 2>/dev/null || exit 0
    CUR=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
    MAX=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')
    if [ -n "$CUR" ] && [ -n "$MAX" ] && [ "$MAX" -gt 0 ]; then
        P=$(( (CUR*100+MAX/2)/MAX ))
    else
        P=$(sudo -n "$BAT" status 2>/dev/null | grep -oE 'Capacity [0-9]+' | grep -oE '[0-9]+' | head -1)
    fi
    if [ -n "$P" ] && [ "$P" -le "$T" ]; then
        finish_discharge "reached ${P}% — limit ${RESTORE_UPPER}/${LOW}" && exit 0
    fi
done
finish_discharge "timeout (2h) — killed"
