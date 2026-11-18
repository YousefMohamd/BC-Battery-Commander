#!/bin/bash
# BC state dir: ~/.battery-commander/ is the ONLY live state dir
# (consolidation 2026-11-13, M2: the old-dir fallback is retired — the
# pre-migration dir is a kept, inert backup and must never be read or
# written as a live target). BC_DASH overrides (tests / dry-runs).
if [ -n "${BC_DASH:-}" ]; then
    DASH="$BC_DASH"
elif [ -d "$HOME/.battery-commander" ]; then
    DASH="$HOME/.battery-commander"
else
    echo "ERROR: Battery Commander state dir missing - ~/.battery-commander not found; refusing to run (old-dir fallback retired)" >&2
    exit 1
fi

LOG="$DASH/actions.log"
log() { echo "[$(date '+%H:%M:%S')] launch_swiftbar: $1" >> "$LOG"; }

if [ -f "$DASH/.user_shutdown" ]; then
    exit 0
fi

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
