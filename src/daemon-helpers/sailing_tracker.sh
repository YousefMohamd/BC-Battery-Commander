#!/bin/bash
# Sailing Tracker — Records battery transitions within sailing range
# Runs every 5 minutes via LaunchAgent
# Provides honest data on Intel Mac Sailing Mode (which is mostly static)

LOG="$HOME/.battopt-swiftbar/actions.log"
STATE="$HOME/.battopt-swiftbar/.sailing_state"
HISTORY="$HOME/.battopt-swiftbar/.sailing_history"

log() { echo "[$(date '+%H:%M:%S')] sailing: $1" >> "$LOG"; }

# Get current state
SNAP=$(sudo -n /usr/local/bin/battopt status 2>/dev/null)
PCT=$(echo "$SNAP" | grep -oE "Capacity [0-9]+" | grep -oE "[0-9]+")
UPPER=$(echo "$SNAP" | grep -oE "upper limit [0-9]+" | grep -oE "[0-9]+")
LOWER=$(echo "$SNAP" | grep -oE "lower limit [0-9]+" | grep -oE "[0-9]+")
STATE_BATT=$(echo "$SNAP" | grep -oE "(charging|discharging|no charging)" | head -1)

[ -z "$PCT" ] && exit 0

# Read previous state
LAST_PCT=""
LAST_DIR=""
LAST_TIME=""
TRANSITIONS=0
[ -f "$STATE" ] && source "$STATE" 2>/dev/null
TRANSITIONS=${TRANSITIONS:-0}

# Determine direction
if [ -n "$UPPER" ] && [ -n "$LOWER" ]; then
    MID=$(( (UPPER + LOWER) / 2 ))
    
    if [ "$PCT" -ge "$MID" ]; then
        DIR="up"
    else
        DIR="down"
    fi
    
    # Detect transitions
    if [ -n "$LAST_DIR" ] && [ "$DIR" != "$LAST_DIR" ]; then
        TRANSITIONS=$((TRANSITIONS + 1))
        echo "$(date '+%Y-%m-%d %H:%M:%S') | $PCT% | $LAST_DIR→$DIR | range $LOWER-$UPPER" >> "$HISTORY"
        log "Transition: $LAST_DIR → $DIR at $PCT% (total: $TRANSITIONS)"
    fi
fi

# Save current state
cat > "$STATE" << EOF
LAST_PCT=$PCT
LAST_DIR=$DIR
LAST_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
TRANSITIONS=$TRANSITIONS
UPPER=$UPPER
LOWER=$LOWER
EOF

exit 0
