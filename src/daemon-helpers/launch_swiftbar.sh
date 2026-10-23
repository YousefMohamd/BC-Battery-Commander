#!/bin/bash
LOG="$HOME/.battopt-swiftbar/actions.log"
log() { echo "[$(date '+%H:%M:%S')] launch_swiftbar: $1" >> "$LOG"; }

if pgrep -x SwiftBar >/dev/null 2>&1; then
    log "already running"
    exit 0
fi

# Clear any disabled plugin cache (SwiftBar bug workaround)
defaults delete com.ameba.SwiftBar DisabledPlugins 2>/dev/null

# Use LaunchServices (open -a) — the only reliable method on Catalina from background
if open -a SwiftBar 2>/dev/null; then
    sleep 3
    if pgrep -x SwiftBar >/dev/null 2>&1; then
        log "launched via open -a"
        exit 0
    fi
fi

log "FAILED to launch SwiftBar"
exit 1
