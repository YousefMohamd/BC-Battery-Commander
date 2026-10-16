#!/bin/bash
HOME="${HOME:-/Users/Yousef}"
DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
BIN="/Applications/SwiftBar.app/Contents/MacOS/SwiftBar"
COOLDOWN="$DASH/.watchdog_cooldown"

log() { echo "[$(date '+%H:%M:%S')] watchdog: $1" >> "$LOG"; }

[ -f "$DASH/.user_shutdown" ] && exit 0

if [ -f "$COOLDOWN" ]; then
    AGE=$(( $(date +%s) - $(stat -f %m "$COOLDOWN" 2>/dev/null || echo 0) ))
    [ "$AGE" -lt 300 ] && exit 0
    rm -f "$COOLDOWN"
fi

if pgrep -x SwiftBar >/dev/null 2>&1; then
    exit 0
fi

log "SwiftBar not running — launching direct binary"
nohup "$BIN" >/dev/null 2>&1 &
disown
sleep 3

if pgrep -x SwiftBar >/dev/null 2>&1; then
    log "SwiftBar launched (pid=$(pgrep -x SwiftBar))"
else
    log "SwiftBar launch FAILED — cooldown 5min"
    touch "$COOLDOWN"
fi
