#!/bin/bash
# Background Process Monitor
# Checks for problematic processes

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
log() { echo "[$(date '+%H:%M:%S')] monitor: $1" >> "$LOG"; }

# App-native notification transport (final cleanup 2026-11-18):
# queue one title<TAB>body line; BatteryCommander.app posts it
# natively under its own identity.
notify() {
    local _t _b
    _t=$(printf '%s' "$1" | tr '\n\t' '  ')
    _b=$(printf '%s' "$2" | tr '\n\t' '  ')
    printf '%s\t%s\n' "$_t" "$_b" >> "$DASH/.notify_queue" 2>/dev/null || true
}

# S1: Respect shutdown - do not restart anything after intentional shutdown
if [ -f "$DASH/.user_shutdown" ]; then
    log "shutdown flag present - skipping monitor"
    exit 0
fi

# 1. Check duplicate SwiftBar
COUNT=$(pgrep -x SwiftBar | wc -l | tr -d ' ')
if [ "$COUNT" -gt 1 ]; then
    log "DUPLICATE SwiftBar: $COUNT instances"
    notify "Battery Commander Monitor" "SwiftBar duplicated — restarting"
    pkill -9 -x SwiftBar
    sleep 2
    $DASH/launch_swiftbar.sh
fi

# 2. Check lsd loop — SIGKILLing a system daemon on every run while it is
# busy is heavy-handed: TERM first, KILL only if it stays hot, and at
# most once an hour (audit 2026-11-11, M6).
LSD_CPU=$(ps -axo %cpu,command | grep '/usr/libexec/lsd$' | grep -v grep | awk '{print $1}' | head -1)
if [ -n "$LSD_CPU" ] && [ "${LSD_CPU%.*}" -gt 50 ]; then
    _lsd_last=0
    [ -f "$DASH/.lsd_reset_last" ] && _lsd_last=$(cat "$DASH/.lsd_reset_last" 2>/dev/null || echo 0)
    case "$_lsd_last" in ''|*[!0-9]*) _lsd_last=0 ;; esac
    if [ $(( $(date +%s) - _lsd_last )) -ge 3600 ]; then
        log "lsd CPU high: ${LSD_CPU}% — TERM, KILL only if still hot"
        killall lsd 2>/dev/null
        sleep 2
        _lsd_now=$(ps -axo %cpu,command | grep '/usr/libexec/lsd$' | grep -v grep | awk '{print $1}' | head -1)
        if [ -n "$_lsd_now" ] && [ "${_lsd_now%.*}" -gt 50 ]; then
            killall -9 lsd 2>/dev/null
            log "lsd still hot after TERM — SIGKILLed"
        fi
        echo "$(date +%s)" > "$DASH/.lsd_reset_last"
        log "lsd reset"
    else
        log "lsd CPU high: ${LSD_CPU}% — reset on cooldown, skipping"
    fi
fi

# 3. Check amfid loop
AMFID_CPU=$(ps -axo %cpu,command | grep '/usr/libexec/amfid$' | grep -v grep | awk '{print $1}' | head -1)
if [ -n "$AMFID_CPU" ] && [ "${AMFID_CPU%.*}" -gt 80 ]; then
    log "amfid CPU high: ${AMFID_CPU}%"
    notify "Battery Commander Monitor" "amfid stuck — restart needed"
fi

# 4. Check PowerWatch (BC user agent com.batterycommander.powerwatch).
# Never auto-load an agent (that is the launcher/deploy job): if the
# agent is loaded but its process is missing, kickstart it; if it is
# not loaded at all, log + notify and leave it to the launcher.
if ! pgrep -f "$DASH/powerwatch" >/dev/null 2>&1; then
    if launchctl list com.batterycommander.powerwatch >/dev/null 2>&1; then
        log "PowerWatch agent loaded but no process — kickstarting"
        launchctl kickstart "gui/$(id -u)/com.batterycommander.powerwatch" 2>/dev/null
    else
        log "PowerWatch agent not loaded — run the launcher to start it"
        # Notify at most once an hour (audit 2026-11-11, M6): without a
        # cooldown this fires on every monitor run while PowerWatch is down.
        _pw_last=0
        [ -f "$DASH/.notify_pw_not_loaded" ] && _pw_last=$(cat "$DASH/.notify_pw_not_loaded" 2>/dev/null || echo 0)
        case "$_pw_last" in ''|*[!0-9]*) _pw_last=0 ;; esac
        if [ $(( $(date +%s) - _pw_last )) -ge 3600 ]; then
            notify "Battery Commander Monitor" "PowerWatch not loaded — run Battery Commander to start it"
            echo "$(date +%s)" > "$DASH/.notify_pw_not_loaded"
        fi
    fi
fi

# 5. (deleted in BC) There is no battopt daemon. The enforcer
# (bc-limit LaunchDaemon) is checked by the watchdog (L8) and the
# launcher — this monitor must not restart it.

exit 0
