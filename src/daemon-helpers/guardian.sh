#!/bin/bash
# Guardian is now just an observer/producer
HOME="${HOME:-/Users/Yousef}"
DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
source "$DASH/state_guard.sh" || exit 1

log() { echo "[$(date '+%H:%M:%S')] guardian: $1" >> "$LOG"; }

# Check if we need to trigger sailing
[ -f "$DASH/config" ] && source "$DASH/config"
IOREG=$(ioreg -rn AppleSmartBattery 2>/dev/null)
EXT=$(echo "$IOREG" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
CUR=$(echo "$IOREG" | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
MAX=$(echo "$IOREG" | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')
[ -z "$CUR" ] || [ -z "$MAX" ] || [ "$MAX" -eq 0 ] && exit 0
PCT=$(( (CUR * 100 + MAX / 2) / MAX ))

MODE=$(read_effective_session)

if [ "$MODE" = "idle" ] && [ "$EXT" = "Yes" ] && [ "$SAILING" = "true" ]; then
    if [ "$PCT" -ge "$LAST_UPPER" ]; then
        log "Sailing condition met. Submitting request."
        submit_request "guardian" "sailing_discharge" "$LAST_UPPER" "$LAST_LOWER" "-" "-" "-" "0"
    fi
elif [ "$MODE" = "idle" ] && [ "$EXT" = "Yes" ]; then
    # Check drift
    SMC_UP=$(sudo -n /usr/local/bin/battopt status 2>/dev/null | grep -oE 'upper limit [0-9]+' | grep -oE '[0-9]+' | head -1)
    if [ -n "$SMC_UP" ] && [ "$SMC_UP" != "$LAST_UPPER" ]; then
        log "Drift detected ($SMC_UP != $LAST_UPPER). Submitting reconcile."
        submit_request "guardian" "reconcile" "-" "-" "-" "-" "-" "0"
    fi
fi
