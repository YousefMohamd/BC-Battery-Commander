#!/bin/bash
if [ -z "$HOME" ]; then echo "ERROR: HOME is unset, refusing to guess user" >&2; exit 1; fi
# Post-Wake Restore — Minimal
# Spotlight, Photos, TM auto-restore when RAM is on

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
log() { echo "[$(date '+%H:%M:%S')] post_wake: $1" >> "$LOG"; }

# Only restore audio apps if they were paused
# (In simplified version, we killed them, so nothing to restore)

# M1: Respect shutdown - do not run post-wake restore after intentional shutdown
if [ -f "$DASH/.user_shutdown" ]; then
    log "shutdown flag present - skipping post_wake"
    exit 0
fi
log "Wake complete"
rm -f "$DASH/.armed_for_sleep" "$DASH/.pre_sleep_done"
exit 0
