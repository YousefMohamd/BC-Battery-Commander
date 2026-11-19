#!/bin/bash
# Arm Sleep — one-button preparation for sleep (Battery Commander)
# Gracefully quiets audio apps, runs cleanup, arms PowerWatch.
# W4.1: graceful quit (kill only as a fallback); Firefox mute dropped
# (focus-stealing); .arm_log capped; pre_sleep_cleanup existence-checked;
# Prepare warning reworded to the charging-through-sleep case.
# No battopt, no sudo, no SMC write. No pmset changes by this script
# (it calls power_saver.sh, whose pmset changes are covered by W4.3).

if [ -z "$HOME" ]; then echo "ERROR: HOME is unset, refusing to guess user" >&2; exit 1; fi
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

[ -f "$DASH/.user_shutdown" ] && exit 0

BC_BUILD_DIR="${BC_BUILD_DIR:-}"
BC_CANDIDATES="$BC_BUILD_DIR/bc-candidates"

# Local notify — fallback if running standalone.
# App-native transport (final cleanup 2026-11-18): queue one
# title<TAB>body line; BatteryCommander.app posts it natively.
if ! command -v notify >/dev/null 2>&1; then
    notify() {
        local _t _b
        _t=$(printf '%s' "$1" | tr '\n\t' '  ')
        _b=$(printf '%s' "$2" | tr '\n\t' '  ')
        printf '%s\t%s\n' "$_t" "$_b" >> "$DASH/.notify_queue" 2>/dev/null || true
    }
fi

LOG="$DASH/actions.log"
log() { echo "[$(date '+%H:%M:%S')] arm_sleep: $1" >> "$LOG"; }

# bc_read_bclm — print the BCLM value (10 = hold, 100 = charging allowed),
# or nothing if it cannot be read. Read-only; never writes.
# (Same helper as dispatch.sh W1; bc-candidates prints
# "BCLM: size=1 type=ui8 bytes=0a value=10".)
bc_read_bclm() {
    local _bin="$BC_CANDIDATES" _out _v
    if [ -x "$_bin" ]; then
        _out=$("$_bin" 2>/dev/null) || _out=""
        _v=$(printf '%s\n' "$_out" | grep '^BCLM:' | grep -oE 'value=[0-9]+' | grep -oE '[0-9]+' | head -1)
        [ -n "$_v" ] && printf '%s' "$_v" && return 0
    fi
    # Fallback (2026-11-19 status-path fix): bc-candidates is a build-tree
    # binary with no installed location; bc-status (state dir) reports
    # the same BCLM read-only.
    _v=$("$DASH/bc-status" 2>/dev/null | grep '^BCLM:' | grep -oE '[0-9]+' | head -1)
    [ -n "$_v" ] && printf '%s' "$_v" && return 0
    return 1
}

log "=== ARM SLEEP START ==="
# Prepare warning: charging through sleep past UPPER (enforcement pauses
# during sleep). If BCLM=10 is already holding, the risk is lower (the hold
# persists in the SMC); if BCLM=100 (or unreadable), the battery charges
# through sleep past UPPER — warn, don't block.
if [ -f "$DASH/config" ]; then
    WARN_UPPER=$(grep -E '^LAST_UPPER=' "$DASH/config" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
fi
WARN_UPPER="${WARN_UPPER:-86}"
case "$WARN_UPPER" in ''|*[!0-9]*) WARN_UPPER=86 ;; esac
WARN_PCT=$(pmset -g batt 2>/dev/null | grep -oE '[0-9]+%' | head -1 | tr -d '%')
if [ -n "$WARN_PCT" ] && [ "$WARN_PCT" -lt "$WARN_UPPER" ] 2>/dev/null && pmset -g batt 2>/dev/null | grep -q "AC Power"; then
    _bclm=$(bc_read_bclm 2>/dev/null) || _bclm=""
    if [ "$_bclm" = "10" ]; then
        log "Sleep on charger: battery ${WARN_PCT}% < limit ${WARN_UPPER}%, but BCLM=10 (holding) — lower risk, the hold persists through sleep"
    else
        log "WARNING: charging through sleep — Battery ${WARN_PCT}% < limit ${WARN_UPPER}%, charger attached, BCLM=${_bclm:-?} (charging), enforcement pauses during sleep, battery will charge past the limit — unplug or wait for stable hold before sleeping"
        notify "Battery Commander" "⚠ Charging through sleep: ${WARN_PCT}% < ${WARN_UPPER}%, charger attached — unplug or wait for hold before sleeping"
    fi
fi

# Sleep delay profile. long/travel redefined 2026-11-11 (Yousef approved
# distinct values). The profile follows the active sleep mode: travel ->
# travel delays, long -> long delays; everything else -> default
# (presentation/download set their own pmset values in dispatch.sh).
SLEEP_PROFILE=$(cat "$DASH/.sleep_profile" 2>/dev/null)
SLEEP_MODE=$(cat "$DASH/.sleep_mode" 2>/dev/null)
case "$SLEEP_MODE" in
    travel|long) APPLY_PROFILE="$SLEEP_MODE" ;;
    *) APPLY_PROFILE=default ;;
esac
log "Sleep profile: ${SLEEP_PROFILE:-?} mode: ${SLEEP_MODE:-?} -> delays: $APPLY_PROFILE"
if [ -f "$DASH/.power_saver" ]; then
    "$DASH/power_saver.sh" on
    "$DASH/power_saver.sh" apply-delays "$APPLY_PROFILE"
    log "Applied sleep delay profile: $APPLY_PROFILE"
else
    "$DASH/power_saver.sh" off
    log "Power Saver disabled; restored standard sleep settings"
fi

# 1. Quiet audio apps — graceful quit first, kill only if still running.
# Never kill unconditionally: quit is a polite request (the app can finish
# cleanly); the kill fallback fires only after a short timeout if the app
# is still running.
for app in VLC Spotify Music; do
    if pgrep -x "$app" >/dev/null 2>&1; then
        osascript -e "tell application \"$app\" to quit" 2>/dev/null
        _t=0
        while [ "$_t" -lt 6 ] && pgrep -x "$app" >/dev/null 2>&1; do
            sleep 0.5
            _t=$((_t + 1))
        done
        if pgrep -x "$app" >/dev/null 2>&1; then
            /usr/bin/pkill -x "$app" 2>/dev/null
            log "Killed $app (did not quit gracefully)"
        else
            log "Quit $app gracefully"
        fi
    fi
done

# 2. Firefox mute DROPPED (W4.1). The old method activated Firefox and
# sent a blind Cmd-Shift-M keystroke — focus-stealing and fragile. No
# non-focus-stealing mute exists for Firefox tabs; Firefox audio (if any)
# is caught by the verify step below, which reports remaining contexts.

# 3. Run pre_sleep_cleanup (if present — log and continue if absent).
if [ -x "$DASH/pre_sleep_cleanup.sh" ]; then
    "$DASH/pre_sleep_cleanup.sh" 2>/dev/null
else
    log "pre_sleep_cleanup.sh not found — skipping"
fi

# 4. Verify audio contexts are gone
sleep 2
AUDIO=$(pmset -g assertions 2>/dev/null | grep -ci "coreaudiod.*PreventUserIdle")

if [ "$AUDIO" -eq 0 ]; then
    log "Arm complete — no audio contexts"
    notify "Battery Commander" "✅ Ready for sleep — close the lid"
else
    log "Arm incomplete — $AUDIO audio contexts remain"
    notify "Battery Commander" "⚠ $AUDIO audio contexts still active"
fi

# 5. Record baseline (cap .arm_log at 100 KB, keep the last 200 lines).
{
    echo ""
    echo "=== ARMED $(date '+%Y-%m-%d %H:%M') ==="
    echo "Battery: $(pmset -g batt | grep -oE '[0-9]+%' | head -1)"
    echo "Wakes: $(pmset -g log | grep -cE 'Wake from|DarkWake')"
    echo "Audio: $AUDIO"
} >> "$DASH/.arm_log"
_arm_log_size=$(wc -c < "$DASH/.arm_log" 2>/dev/null | tr -d ' ')
if [ -n "$_arm_log_size" ] && [ "$_arm_log_size" -gt 102400 ] 2>/dev/null; then
    tail -n 200 "$DASH/.arm_log" > "$DASH/.arm_log.tmp.$$" && mv "$DASH/.arm_log.tmp.$$" "$DASH/.arm_log"
fi

touch "$DASH/.armed_for_sleep"
# Flag cleanup is owned by post_wake_restore.sh (single owner, W4.1) —
# arm_sleep only sets .armed_for_sleep; it never removes flags.
log "=== ARM SLEEP END ==="
