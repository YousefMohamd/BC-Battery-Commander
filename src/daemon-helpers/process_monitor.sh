#!/bin/bash
# Background Process Monitor
# Checks for problematic processes

LOG="$HOME/.battopt-swiftbar/actions.log"
log() { echo "[$(date '+%H:%M:%S')] monitor: $1" >> "$LOG"; }

# S1: Respect shutdown - do not restart anything after intentional shutdown
if [ -f "$HOME/.battopt-swiftbar/.user_shutdown" ]; then
    log "shutdown flag present - skipping monitor"
    exit 0
fi

# 1. Check duplicate SwiftBar
COUNT=$(pgrep -x SwiftBar | wc -l | tr -d ' ')
if [ "$COUNT" -gt 1 ]; then
    log "DUPLICATE SwiftBar: $COUNT instances"
    osascript -e 'display notification "SwiftBar duplicated — restarting" with title "BattOpt Monitor"'
    pkill -9 -x SwiftBar
    sleep 2
    ~/.battopt-swiftbar/launch_swiftbar.sh
fi

# 2. Check lsd loop
LSD_CPU=$(ps -axo %cpu,command | grep '/usr/libexec/lsd$' | grep -v grep | awk '{print $1}' | head -1)
if [ -n "$LSD_CPU" ] && [ "${LSD_CPU%.*}" -gt 50 ]; then
    log "lsd CPU high: ${LSD_CPU}%"
    # Auto-reset
    killall -9 lsd
    log "lsd reset"
fi

# 3. Check amfid loop
AMFID_CPU=$(ps -axo %cpu,command | grep '/usr/libexec/amfid$' | grep -v grep | awk '{print $1}' | head -1)
if [ -n "$AMFID_CPU" ] && [ "${AMFID_CPU%.*}" -gt 80 ]; then
    log "amfid CPU high: ${AMFID_CPU}%"
    osascript -e 'display notification "amfid stuck — restart needed" with title "BattOpt Monitor"'
fi

# 4. Check PowerWatch
if ! pgrep -f 'battopt-swiftbar/powerwatch' >/dev/null 2>&1; then
    log "PowerWatch stopped — restarting"
    sudo launchctl kickstart -k system/com.battopt.powerwatch 2>/dev/null
fi

# 5. Check battopt daemon
if ! pgrep -f 'battopt daemon' >/dev/null 2>&1; then
    log "battopt daemon stopped — restarting"
    sudo -n /usr/local/bin/battopt-daemon-start 2>/dev/null
fi

exit 0
