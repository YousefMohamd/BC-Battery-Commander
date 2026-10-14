#!/bin/bash
# Auto Cleanup — idle-triggered service pause/restore (v1.3.0)
HOME="${HOME:-/Users/Yousef}"
DASH="$HOME/.battopt-swiftbar"
FLAG="$DASH/.auto_cleanup"
DONE="$DASH/.pre_sleep_done"
LOG="$DASH/.cleanup.log"

# Only when feature enabled AND Power Saver ON
[ ! -f "$FLAG" ] && exit 0
[ ! -f "$DASH/.power_saver" ] && exit 0
[ -f "$DASH/.user_shutdown" ] && exit 0

IDLE_NS=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/{print $NF; exit}')
[ -z "$IDLE_NS" ] && exit 0
IDLE_MIN=$((IDLE_NS / 1000000000 / 60))

if [ "$IDLE_MIN" -ge 15 ] && [ ! -f "$DONE" ]; then
    echo "[$(date '+%H:%M:%S')] idle ${IDLE_MIN}m → cleanup" >> "$LOG"
    "$DASH/pre_sleep_cleanup.sh" >> "$LOG" 2>&1
    touch "$DONE"
elif [ "$IDLE_MIN" -lt 1 ] && [ -f "$DONE" ]; then
    echo "[$(date '+%H:%M:%S')] user back → restore" >> "$LOG"
    "$DASH/post_wake_restore.sh" >> "$LOG" 2>&1
    rm -f "$DONE"
fi
