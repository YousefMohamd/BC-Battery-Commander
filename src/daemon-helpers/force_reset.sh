#!/bin/bash
BAT="/usr/local/bin/battopt"
PLIST="/Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist"
DOMAIN="system/com.buddha-path.BattOpt.daemon"
DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
[ -f "$DASH/.user_shutdown" ] && exit 0

echo "[$(date '+%H:%M:%S')] FORCE RESET start" >> "$LOG"
rm -f "$DASH/.disabled"

# Kill all clients
sudo pkill -9 -f "/usr/local/bin/battopt" 2>/dev/null
sleep 2

# Check if daemon loaded
if ! launchctl list | grep -q "com.buddha-path.BattOpt.daemon"; then
    echo "[$(date '+%H:%M:%S')] daemon not loaded, loading" >> "$LOG"
    sudo -n /usr/local/bin/battopt-daemon-start 2>/dev/null
    sleep 2
fi

# Kickstart (or fallback to unload/load if kickstart fails)
if ! sudo -n /usr/local/bin/battopt-daemon-restart 2>/dev/null; then
    echo "[$(date '+%H:%M:%S')] kickstart failed, reloading" >> "$LOG"
    sudo launchctl unload -w "$PLIST" 2>/dev/null
    sleep 1
    sudo -n /usr/local/bin/battopt-daemon-start 2>/dev/null
fi

# Wait for daemon ready
for i in $(seq 1 10); do
    sleep 0.3
    sudo -n "$BAT" status >/dev/null 2>&1 && break
done

STATE=$(sudo -n "$BAT" status 2>&1 | grep -oE "(charging|discharging|no charging)" | head -1)
echo "[$(date '+%H:%M:%S')] FORCE RESET done - ${STATE:-unknown}" >> "$LOG"
echo "State: ${STATE:-unknown}"

# Session-state cleanup — B8: only clear when no client is running and no
# concurrent writer holds the guard lock.
#
# A concurrent writer (guardian LAYER2, dispatch.sh intent_apply) can be
# mid-transition here: .active_mode / .active_token / .sd_session may have
# just been written by guard_session_begin() but the discharge client not
# yet forked (the "W window"). Unconditionally removing those files while
# that fork is in flight orphans it — the next guardian tick then re-forms
# a phantom .active_mode=discharge.
#
# Two gates:
#   1. pgrep: if a battopt client is still alive, we keep the state.
#   2. guard_lock: serialise against guard_session_begin() so the clear
#      cannot race the write. Re-check pgrep under the lock, since a
#      forked descendant may exec() between the first check and the lock.

if [ -f "$DASH/state_guard.sh" ]; then
    # shellcheck disable=SC1091
    source "$DASH/state_guard.sh" 2>/dev/null
fi

_client_alive() {
    pgrep -f "battopt discharge" >/dev/null 2>&1 && return 0
    pgrep -f "battopt charge"    >/dev/null 2>&1 && return 0
    pgrep -f "battopt calibrate" >/dev/null 2>&1 && return 0
    return 1
}

if _client_alive; then
    echo "[$(date '+%H:%M:%S')] FORCE RESET kept session state — client still running" >> "$LOG"
elif command -v guard_lock >/dev/null 2>&1; then
    if guard_lock; then
        if _client_alive; then
            echo "[$(date '+%H:%M:%S')] FORCE RESET kept session state — client exec'd during lock" >> "$LOG"
        else
            rm -f "$DASH/.active_token"
            rm -f "$DASH/.sd_session"
            echo "idle" > "$DASH/.active_mode"
        fi
        guard_unlock
    else
        # guard_lock only returns 1 when a live PID has held the lock
        # for >3s. That is abnormal (guard_session_begin holds it <100ms),
        # so decline to clear rather than risk orphaning an active writer.
        echo "[$(date '+%H:%M:%S')] FORCE RESET skipped session clear — guard lock busy" >> "$LOG"
    fi
else
    # state_guard.sh unavailable — fall back to the pgrep-only clear
    # (the alive check above already passed).
    rm -f "$DASH/.active_token"
    rm -f "$DASH/.sd_session"
    echo "idle" > "$DASH/.active_mode"
fi
