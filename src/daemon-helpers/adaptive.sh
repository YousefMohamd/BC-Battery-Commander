#!/bin/bash
# ARCH_DETECTION — Intel vs Apple Silicon
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    # Apple Silicon: hibernatemode 25 not supported
    # Exit silently (no adaptation needed)
    exit 0
fi

# Battery-Aware Hibernate Switcher
# Runs every 5 minutes via LaunchAgent
# Protects against Hibernate File corruption (risk 1.2)
# and Battery Below 20% (risk 1.10)

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
FLAG="$DASH/.power_saver"

log() { echo "[$(date '+%H:%M:%S')] adaptive: $1" >> "$LOG"; }

# Only active if Power Saver is on
[ ! -f "$FLAG" ] && exit 0

# Get battery level
PCT=$(pmset -g batt 2>/dev/null | grep -oE '[0-9]+%' | head -1 | tr -d '%')
[ -z "$PCT" ] && exit 0

# Get current hibernatemode
CURRENT=$(pmset -g 2>/dev/null | grep "hibernatemode" | awk '{print $2}')

# Decision logic
# The pmset writes are failure-checked: a failed write must not be
# logged/notified as a success (audit 2026-11-11, W6).
if [ "$PCT" -lt 25 ] && [ "$CURRENT" = "25" ]; then
    # Battery getting low - switch to Safe Sleep
    if sudo -n /usr/bin/pmset -a hibernatemode 3 2>/dev/null; then
        log "SAFE MODE (battery ${PCT}%)"
        osascript -e "display notification \"Battery at ${PCT}% — switched to Safe Sleep to protect data\" with title \"Battery Commander Safety\"" 2>/dev/null
    else
        log "SAFE MODE FAILED (battery ${PCT}%) — pmset write failed"
    fi
elif [ "$PCT" -ge 30 ] && [ "$CURRENT" = "3" ]; then
    # Battery recovered - switch back to Deep Hibernate
    if sudo -n /usr/bin/pmset -a hibernatemode 25 2>/dev/null; then
        log "DEEP MODE (battery ${PCT}%)"
    else
        log "DEEP MODE FAILED (battery ${PCT}%) — pmset write failed"
    fi
fi

exit 0
