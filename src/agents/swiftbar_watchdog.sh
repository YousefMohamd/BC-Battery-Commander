#!/bin/bash
# BattOpt SwiftBar Watchdog — professional version
# Guarantees SwiftBar runs as PPID=1 (launchd-owned) via launchctl submit
HOME="${HOME:-/Users/Yousef}"
DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
BIN="/Applications/SwiftBar.app/Contents/MacOS/SwiftBar"
COOLDOWN="$DASH/.watchdog_cooldown"
JOB_LABEL="com.battopt.swiftbar"

log() { echo "[$(date '+%H:%M:%S')] watchdog: $1" >> "$LOG"; }

# Respect user shutdown
[ -f "$DASH/.user_shutdown" ] && exit 0

# Cooldown after failed launch
if [ -f "$COOLDOWN" ]; then
    AGE=$(( $(date +%s) - $(stat -f %m "$COOLDOWN" 2>/dev/null || echo 0) ))
    [ "$AGE" -lt 300 ] && exit 0
    rm -f "$COOLDOWN"
fi

# Already running AND PPID=1? nothing to do
if pgrep -x SwiftBar >/dev/null 2>&1; then
    PID=$(pgrep -x SwiftBar | head -1)
    PPID_VAL=$(ps -o ppid= -p "$PID" | tr -d ' ')
    if [ "$PPID_VAL" = "1" ]; then
        exit 0
    fi
    log "SwiftBar running but PPID=$PPID_VAL — restarting detached"
    pkill -x SwiftBar 2>/dev/null
    sleep 2
fi

log "launching SwiftBar via launchctl submit"

# Remove stale job if any
launchctl remove "$JOB_LABEL" 2>/dev/null
sleep 1

# The professional way — launchd owns the process (PPID=1 guaranteed)
launchctl submit -l "$JOB_LABEL" -o /tmp/swiftbar.out -e /tmp/swiftbar.err -- "$BIN"

sleep 3

if pgrep -x SwiftBar >/dev/null 2>&1; then
    NEW_PID=$(pgrep -x SwiftBar | head -1)
    NEW_PPID=$(ps -o ppid= -p "$NEW_PID" | tr -d ' ')
    log "SwiftBar launched pid=$NEW_PID ppid=$NEW_PPID"
else
    log "SwiftBar launch FAILED — cooldown 5min"
    touch "$COOLDOWN"
fi
