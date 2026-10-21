#!/bin/bash
# System Guard — prevents resource loops
LOG="$HOME/.battopt-swiftbar/actions.log"
ALERT="$HOME/.battopt-swiftbar/.guard_alerts"
mkdir -p "$ALERT"

log() { echo "[$(date '+%H:%M:%S')] guard: $1" >> "$LOG"; }

# 1. Check lsd
lsd_cpu=$(ps -axo %cpu,command | grep '/usr/libexec/lsd' | grep -v grep | awk '{print $1}' | head -1)
if [ -n "$lsd_cpu" ] && [ "${lsd_cpu%.*}" -gt 60 ]; then
    # Only alert once per hour
    if [ ! -f "$ALERT/lsd_$(date +%H)" ]; then
        touch "$ALERT/lsd_$(date +%H)"
        log "ALERT: lsd at ${lsd_cpu}% — possible loop"
        # Don't kill automatically — just notify
        osascript -e 'display notification "lsd CPU high — Spotlight may be reindexing" with title "BattOpt Guard"'
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
        osascript -e 'display notification "amfid stuck — restart may be needed" with title "BattOpt Guard"'
    fi
fi

# 4. Auto-clean old alerts (> 24h)
find "$ALERT" -type f -mmin +1440 -delete 2>/dev/null

exit 0
