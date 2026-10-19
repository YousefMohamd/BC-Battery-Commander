#!/bin/bash
HOME="${HOME:-/Users/Yousef}"
DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
STATE_FILE="$DASH/.ac_state"
source "$DASH/state_guard.sh" || exit 1

IOREG=$(ioreg -rn AppleSmartBattery 2>/dev/null)
EXT=$(echo "$IOREG" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
[ -z "$EXT" ] && exit 0

PREV=""
[ -f "$STATE_FILE" ] && PREV=$(cat "$STATE_FILE" 2>/dev/null)
echo "$EXT" > "$STATE_FILE"

if [ "$PREV" = "No" ] && [ "$EXT" = "Yes" ]; then
    echo "[$(date '+%H:%M:%S')] ac_watcher: AC CONNECTED — submitting reconcile" >> "$LOG"
    submit_request "ac" "reconcile" "-" "-" "-" "-" "-" "0"
fi
