#!/bin/bash
# System Guard — prevents resource loops
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
ALERT="$DASH/.guard_alerts"
mkdir -p "$ALERT"

log() { echo "[$(date '+%H:%M:%S')] guard: $1" >> "$LOG"; }

# App-native notification transport (final cleanup 2026-11-18):
# queue one title<TAB>body line; BatteryCommander.app posts it
# natively under its own identity.
notify() {
    local _t _b
    _t=$(printf '%s' "$1" | tr '\n\t' '  ')
    _b=$(printf '%s' "$2" | tr '\n\t' '  ')
    printf '%s\t%s\n' "$_t" "$_b" >> "$DASH/.notify_queue" 2>/dev/null || true
}

# 1. Check lsd
lsd_cpu=$(ps -axo %cpu,command | grep '/usr/libexec/lsd' | grep -v grep | awk '{print $1}' | head -1)
if [ -n "$lsd_cpu" ] && [ "${lsd_cpu%.*}" -gt 60 ]; then
    # Only alert once per hour
    if [ ! -f "$ALERT/lsd_$(date +%H)" ]; then
        touch "$ALERT/lsd_$(date +%H)"
        log "ALERT: lsd at ${lsd_cpu}% — possible loop"
        # Don't kill automatically — just notify
        notify "Battery Commander Guard" "lsd CPU high — Spotlight may be reindexing"
    fi
fi

# 2. Check mdsync
mdsync_cpu=$(ps -axo %cpu,command | grep 'mdsync' | grep -v grep | awk '{print $1}' | head -1)
if [ -n "$mdsync_cpu" ] && [ "${mdsync_cpu%.*}" -gt 80 ]; then
    if [ ! -f "$ALERT/mdsync_$(date +%H)" ]; then
        touch "$ALERT/mdsync_$(date +%H)"
        log "ALERT: mdsync at ${mdsync_cpu}% — full reindex in progress"
    fi
fi

# 3. Check amfid
amfid_cpu=$(ps -axo %cpu,command | grep '/usr/libexec/amfid' | grep -v grep | awk '{print $1}' | head -1)
if [ -n "$amfid_cpu" ] && [ "${amfid_cpu%.*}" -gt 80 ]; then
    if [ ! -f "$ALERT/amfid_$(date +%H)" ]; then
        touch "$ALERT/amfid_$(date +%H)"
        log "ALERT: amfid at ${amfid_cpu}%"
        notify "Battery Commander Guard" "amfid stuck — restart may be needed"
    fi
fi

# 4. Auto-clean old alerts (> 24h)
find "$ALERT" -type f -mmin +1440 -delete 2>/dev/null

exit 0
