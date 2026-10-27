#!/bin/bash
if [ -z "$HOME" ]; then echo "ERROR: HOME is unset, refusing to guess user" >&2; exit 1; fi
# Pre-Sleep Cleanup — Simplified
# Only stop audio apps (the real blocker for deep sleep)
# Spotlight, Time Machine, Photos don't need stopping if Hibernatemode 25 works

LOG="$HOME/.battopt-swiftbar/actions.log"
log() { echo "[$(date '+%H:%M:%S')] pre_sleep: $1" >> "$LOG"; }

log "Cleanup started"

# 1. Kill audio apps
for app in VLC Spotify Music; do
    if pgrep -x "$app" >/dev/null 2>&1; then
        /usr/bin/pkill -x "$app" 2>/dev/null
        log "Killed $app"
    fi
done

# 2. Mute Firefox
if pgrep -x firefox >/dev/null 2>&1; then
    osascript -e 'tell application "Firefox" to activate' 2>/dev/null
    sleep 0.3
    osascript -e 'tell application "System Events" to keystroke "m" using {command down, shift down}' 2>/dev/null
    log "Firefox muted"
fi

# 3. Verify no audio contexts
sleep 1
AUDIO=$(pmset -g assertions 2>/dev/null | grep -c "coreaudiod.*preventuseridlesleep")
if [ "$AUDIO" -eq 0 ]; then
    log "Ready for sleep (no audio contexts)"
else
    log "Warning: $AUDIO audio contexts remain"
fi

log "Cleanup complete"
exit 0
