#!/bin/bash
if [ -z "$HOME" ]; then echo "ERROR: HOME is unset, refusing to guess user" >&2; exit 1; fi
# Post-Wake Restore — Minimal
# Spotlight, Photos, TM auto-restore when RAM is on

LOG="$HOME/.battopt-swiftbar/actions.log"
log() { echo "[$(date '+%H:%M:%S')] post_wake: $1" >> "$LOG"; }

# Only restore audio apps if they were paused
# (In simplified version, we killed them, so nothing to restore)

# M1: Respect shutdown - do not run post-wake restore after intentional shutdown
if [ -f "$HOME/.battopt-swiftbar/.user_shutdown" ]; then
    log "shutdown flag present - skipping post_wake"
    exit 0
fi
log "Wake complete"
rm -f "$HOME/.battopt-swiftbar/.armed_for_sleep" "$HOME/.battopt-swiftbar/.pre_sleep_done"
exit 0
