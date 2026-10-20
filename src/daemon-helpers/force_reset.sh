#!/bin/bash
BAT="/usr/local/bin/battopt"
PLIST="/Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist"
LOG="$HOME/.battopt-swiftbar/actions.log"
DASH="$HOME/.battopt-swiftbar"

source "$DASH/state_guard.sh" 2>/dev/null

[ -f "$DASH/.user_shutdown" ] && exit 0

echo "[$(date '+%H:%M:%S')] FORCE RESET start" >> "$LOG"
rm -f "$DASH/.disabled"

if command -v guard_publish_session >/dev/null 2>&1; then
    guard_publish_session "recovery" "-" "idle" "reset" "recovery" "-" "-" "-" "$(date +%s)" "0" || true
fi

rm -f "$DASH/.desired_state"

sudo pkill -9 -f "/usr/local/bin/battopt" 2>/dev/null
sleep 1

if ! launchctl list | grep -q "com.buddha-path.BattOpt.daemon"; then
    echo "[$(date '+%H:%M:%S')] daemon not loaded, loading" >> "$LOG"
    sudo -n /usr/local/bin/battopt-daemon-start 2>/dev/null
    sleep 2
fi

if ! sudo -n /usr/local/bin/battopt-daemon-restart 2>/dev/null; then
    echo "[$(date '+%H:%M:%S')] kickstart failed, reloading" >> "$LOG"
    sudo launchctl unload -w "$PLIST" 2>/dev/null
    sleep 1
    sudo -n /usr/local/bin/battopt-daemon-start 2>/dev/null
fi

for i in $(seq 1 10); do
    sleep 0.3
    sudo -n "$BAT" status >/dev/null 2>&1 && break
done

STATE=$(sudo -n "$BAT" status 2>&1 | grep -oE "(charging|discharging|no charging)" | head -1)
echo "[$(date '+%H:%M:%S')] FORCE RESET done - ${STATE:-unknown}" >> "$LOG"
echo "State: ${STATE:-unknown}"
