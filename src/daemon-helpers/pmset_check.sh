#!/bin/bash
# Post-Update Recovery
# Runs daily at 10 AM
# Restores pmset values after macOS updates (risk 1.7)

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
FLAG="$DASH/.power_saver"

log() { echo "[$(date '+%H:%M:%S')] pmset_check: $1" >> "$LOG"; }

# Only if Power Saver intended to be on
[ ! -f "$FLAG" ] && exit 0

# Respect shutdown — never restore pmset settings after an intentional
# shutdown (audit 2026-11-11; every other helper has this guard).
[ -f "$DASH/.user_shutdown" ] && exit 0

# Read current values
HIB=$(pmset -g 2>/dev/null | grep "hibernatemode" | awk '{print $2}')
PN=$(pmset -g 2>/dev/null | grep "powernap" | awk '{print $2}')
[ -z "$PN" ] && PN="0"
WOMP=$(pmset -g 2>/dev/null | grep "^ womp" | awk '{print $2}')
[ -z "$WOMP" ] && WOMP="0"

# Check for drift
DRIFT=""
[ "$HIB" != "25" ] && DRIFT="${DRIFT}hibernatemode; "
[ "$PN" != "0" ] && DRIFT="${DRIFT}powernap; "
[ "$WOMP" != "0" ] && DRIFT="${DRIFT}womp; "

if [ -n "$DRIFT" ]; then
    log "DRIFT DETECTED: $DRIFT"
    $DASH/power_saver.sh on >> "$LOG" 2>&1
    osascript -e "display notification \"Power Saver restored after system change\" with title \"Battery Commander Recovery\"" 2>/dev/null
else
    log "check OK (hibernatemode=$HIB, powernap=$PN, womp=$WOMP)"
fi

exit 0
