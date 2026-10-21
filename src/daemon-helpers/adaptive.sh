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

LOG="$HOME/.battopt-swiftbar/actions.log"
FLAG="$HOME/.battopt-swiftbar/.power_saver"

log() { echo "[$(date '+%H:%M:%S')] adaptive: $1" >> "$LOG"; }

# Only active if Power Saver is on
[ ! -f "$FLAG" ] && exit 0

# Get battery level
PCT=$(pmset -g batt 2>/dev/null | grep -oE '[0-9]+%' | head -1 | tr -d '%')
[ -z "$PCT" ] && exit 0

# Get current hibernatemode
CURRENT=$(pmset -g 2>/dev/null | grep "hibernatemode" | awk '{print $2}')

# Decision logic
if [ "$PCT" -lt 25 ] && [ "$CURRENT" = "25" ]; then
    # Battery getting low - switch to Safe Sleep
    sudo -n /usr/bin/pmset -a hibernatemode 3 2>/dev/null
    log "SAFE MODE (battery ${PCT}%)"
    osascript -e "display notification \"Battery at ${PCT}% — switched to Safe Sleep to protect data\" with title \"BattOpt Safety\"" 2>/dev/null
elif [ "$PCT" -ge 30 ] && [ "$CURRENT" = "3" ]; then
    # Battery recovered - switch back to Deep Hibernate
    sudo -n /usr/bin/pmset -a hibernatemode 25 2>/dev/null
    log "DEEP MODE (battery ${PCT}%)"
fi

exit 0
