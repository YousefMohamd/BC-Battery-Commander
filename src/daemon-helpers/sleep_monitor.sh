#!/bin/bash
# Auto Cleanup — idle-triggered service pause/restore (v1.3.0)
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
FLAG="$DASH/.auto_cleanup"
DONE="$DASH/.pre_sleep_done"
LOG="$DASH/.cleanup.log"

# Only when feature enabled AND Power Saver ON
# Session guard: skip only for a TRANSIENT session (discharge /
# charge_full / calibration). Hold is NOT transient — auto-cleanup is
# safe while holding (audit 2026-11-11, W12; the old guard skipped
# cleanup for hours of normal holding).
if [ -f "$DASH/state_guard.sh" ]; then
    source "$DASH/state_guard.sh" || exit 1
    _sm_mode=$(read_effective_session 2>/dev/null || echo idle)
    case "$_sm_mode" in
        discharge|charge_full|calibration) exit 0 ;;
    esac
else
    echo "[$(date '+%H:%M:%S')] sleep_monitor: state_guard.sh missing — skipping" >> "$LOG"
    exit 1
fi
[ ! -f "$FLAG" ] && exit 0
[ ! -f "$DASH/.power_saver" ] && exit 0
[ -f "$DASH/.user_shutdown" ] && exit 0

IDLE_NS=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/{print $NF; exit}')
[ -z "$IDLE_NS" ] && exit 0
IDLE_SEC=$((IDLE_NS / 1000000000))
IDLE_MIN=$((IDLE_SEC / 60))

if [ "$IDLE_SEC" -ge 900 ] && [ ! -f "$DONE" ]; then
    echo "[$(date '+%H:%M:%S')] idle ${IDLE_MIN}m → cleanup" >> "$LOG"
    # Only mark done on SUCCESS: a failed cleanup must retry next run,
    # not sit marked-done forever (audit 2026-11-11, W12).
    if [ -x "$DASH/pre_sleep_cleanup.sh" ]; then
        if "$DASH/pre_sleep_cleanup.sh" >> "$LOG" 2>&1; then
            touch "$DONE"
        else
            echo "[$(date '+%H:%M:%S')] pre_sleep_cleanup FAILED — not marking done (retries next run)" >> "$LOG"
        fi
    else
        echo "[$(date '+%H:%M:%S')] pre_sleep_cleanup.sh missing — skipping" >> "$LOG"
    fi
elif [ "$IDLE_SEC" -lt 60 ] && [ -f "$DONE" ]; then
    echo "[$(date '+%H:%M:%S')] user back → restore" >> "$LOG"
    if [ -x "$DASH/post_wake_restore.sh" ]; then
        "$DASH/post_wake_restore.sh" >> "$LOG" 2>&1
        rm -f "$DONE"
    else
        echo "[$(date '+%H:%M:%S')] post_wake_restore.sh missing — leaving .pre_sleep_done" >> "$LOG"
    fi
fi
