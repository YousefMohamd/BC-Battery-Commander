#!/bin/bash
# Pre-Sleep Cleanup — Simplified (Battery Commander)
# Only stop audio apps (the real blocker for deep sleep)
# Spotlight, Time Machine, Photos don't need stopping if Hibernatemode 25 works
# W4.1 companion fix (same as arm_sleep.sh): graceful quit first, kill only
# as a fallback; Firefox mute dropped (focus-stealing); dead lowercase
# audio grep fixed (pmset assertion names are CamelCase).
# No battopt, no sudo, no SMC write.

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
LOG="$DASH/actions.log"
log() { echo "[$(date '+%H:%M:%S')] pre_sleep: $1" >> "$LOG"; }

log "Cleanup started"

# 1. Quiet audio apps — graceful quit first, kill only if still running.
# (Same policy as arm_sleep.sh W4.1; this runs after arm_sleep, so the
# apps are usually already gone and the pgrep skips them — idempotent.)
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

# 2. Firefox mute DROPPED (W4.1 — same reason as arm_sleep.sh: the old
# activate + Cmd-Shift-M keystroke steals focus and is fragile; Firefox
# audio, if any, is caught by the verify step below).

# 3. Verify no audio contexts (case-insensitive: pmset assertion names
# are CamelCase, e.g. PreventUserIdleSystemSleep — the old lowercase
# pattern could never match and always reported "Ready for sleep").
sleep 1
AUDIO=$(pmset -g assertions 2>/dev/null | grep -ci "coreaudiod.*PreventUserIdle")
if [ "$AUDIO" -eq 0 ]; then
    log "Ready for sleep (no audio contexts)"
else
    log "Warning: $AUDIO audio contexts remain"
fi

# 4. Discharge sessions NEVER survive sleep (discharge design §5.4).
#    This script runs on the powerwatch WillSleep path (powerwatch runs
#    arm_sleep + pre_sleep_cleanup with a bounded wait BEFORE allowing
#    sleep), so removing the session file here ends the session before
#    sleep completes. The watchdog monitor sees the vanished file and
#    closes the episode in discharge.log. This script also runs from the
#    Prepare path — ending a session there is the same safe direction.
for _sf in "$DASH/.discharge_session" "$DASH/.discharge_session.shadow"; do
    if [ -f "$_sf" ]; then
        # Calibrate build (2026-11-14): a calibration segment dying
        # at WillSleep leaves a run checkpoint in calibration.log;
        # the run supervisor resumes only through its gated user
        # tap after the wake (calibrate design section 5.4).
        _cal_mode=""
        if [ "$_sf" = "$DASH/.discharge_session" ]; then
            _cal_mode=$(grep '^MODE=' "$_sf" 2>/dev/null | tail -1 | cut -d= -f2)
        fi
        # Discharge intent (2026-11-14): a MODE=user session torn
        # down here leaves a resume intent BEFORE the file goes —
        # TARGET, ORIGINAL_STARTED (the session's own
        # ORIGINAL_STARTED when it was itself a resume, else its
        # STARTED, so the 12 h window anchors to the FIRST start
        # across a sleep/wake chain), EXPIRES = ORIGINAL_STARTED +
        # 12 h. The watchdog monitor recreates the session after
        # the wake under its resume gates. User sessions only:
        # never corrective (the watchdog's own inference — it
        # re-derives those itself) and never calibrate (the run
        # supervisor owns its own checkpoint, above).
        if [ "$_sf" = "$DASH/.discharge_session" ] && [ "$_cal_mode" = "user" ]; then
            _i_tgt=$(grep '^TARGET=' "$_sf" 2>/dev/null | tail -1 | cut -d= -f2)
            _i_org=$(grep '^ORIGINAL_STARTED=' "$_sf" 2>/dev/null | tail -1 | cut -d= -f2)
            case "$_i_org" in ''|*[!0-9]*)
                _i_org=$(grep '^STARTED=' "$_sf" 2>/dev/null | tail -1 | cut -d= -f2) ;;
            esac
            case "$_i_tgt" in ''|*[!0-9]*) _i_tgt="" ;; esac
            case "$_i_org" in ''|*[!0-9]*) _i_org="" ;; esac
            if [ -n "$_i_tgt" ] && [ -n "$_i_org" ] \
                && [ "$_i_tgt" -ge 20 ] && [ "$_i_tgt" -le 99 ]; then
                _i_exp=$(( _i_org + 43200 ))
                printf 'TARGET=%s\nORIGINAL_STARTED=%s\nEXPIRES=%s\n' \
                    "$_i_tgt" "$_i_org" "$_i_exp" > "$DASH/.discharge_intent.tmp" \
                    && mv "$DASH/.discharge_intent.tmp" "$DASH/.discharge_intent"
                printf '[%s] [REAL] INTENT_SAVED target=%s original_started=%s expires=%s by=pre_sleep_cleanup\n' \
                    "$(date '+%Y-%m-%d %H:%M:%S')" "$_i_tgt" "$_i_org" "$_i_exp" \
                    >> "$DASH/discharge.log" 2>/dev/null
                log "Discharge intent saved (target=$_i_tgt, expires=$_i_exp)"
            fi
        fi
        rm -f "$_sf"
        if [ "$_sf" = "$DASH/.discharge_session" ]; then _tag="REAL"; else _tag="SHADOW"; fi
        printf '[%s] [%s] SESSION_ENDED reason=sleep by=pre_sleep_cleanup file=%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$_tag" "$(basename "$_sf")" \
            >> "$DASH/discharge.log" 2>/dev/null
        log "Discharge session ended before sleep ($(basename "$_sf"))"
        if [ "$_cal_mode" = "calibrate" ] && [ -f "$DASH/.calibration_run" ]; then
            _cal_run=$(grep '^RUN_ID=' "$DASH/.calibration_run" 2>/dev/null | tail -1 | cut -d= -f2)
            _cal_leg=$(grep '^LEG=' "$DASH/.calibration_run" 2>/dev/null | tail -1 | cut -d= -f2)
            printf '[%s] RUN_CHECKPOINT reason=sleep run=%s leg=%s by=pre_sleep_cleanup\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "${_cal_run:-?}" "${_cal_leg:-?}" \
                >> "$DASH/calibration.log" 2>/dev/null
            log "Calibration checkpoint written (segment ended before sleep)"
        fi
    fi
done

log "Cleanup complete"
exit 0

