#!/bin/bash
HOME="${HOME:-/Users/Yousef}"
# Post-Wake Restore — Minimal
# Spotlight, Photos, TM auto-restore when RAM is on

LOG="$HOME/.battopt-swiftbar/actions.log"
log() { echo "[$(date '+%H:%M:%S')] post_wake: $1" >> "$LOG"; }

# Only restore audio apps if they were paused
# (In simplified version, we killed them, so nothing to restore)

log "Wake complete"
rm -f "$HOME/.battopt-swiftbar/.armed_for_sleep" "$HOME/.battopt-swiftbar/.pre_sleep_done"
# Cancel RTC maintenance wakes (they drain battery overnight)
sudo -n /usr/bin/pmset schedule cancelall 2>/dev/null || true

exit 0
