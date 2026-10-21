#!/bin/bash
# Post-Update Recovery
# Runs daily at 10 AM
# Restores pmset values after macOS updates (risk 1.7)

LOG="$HOME/.battopt-swiftbar/actions.log"
FLAG="$HOME/.battopt-swiftbar/.power_saver"

log() { echo "[$(date '+%H:%M:%S')] pmset_check: $1" >> "$LOG"; }

# Only if Power Saver intended to be on
[ ! -f "$FLAG" ] && exit 0

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
    ~/.battopt-swiftbar/power_saver.sh on >> "$LOG" 2>&1
    osascript -e "display notification \"Power Saver restored after system change\" with title \"BattOpt Recovery\"" 2>/dev/null
else
    log "check OK (hibernatemode=$HIB, powernap=$PN, womp=$WOMP)"
fi

exit 0
