#!/bin/bash
# wake_analyzer.sh — Layer 14
# After each wake, classify what happened and log to .sleep_analysis.log.

DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/.sleep_analysis.log"
STATE_FILE="$DASH/.last_wake_count"

# Get current wake count
CUR_WAKES=$(pmset -g log 2>/dev/null | grep -cE "Wake from|DarkWake")
LAST_WAKES=0
[ -f "$STATE_FILE" ] && LAST_WAKES=$(cat "$STATE_FILE" 2>/dev/null)

# Only proceed if new wakes happened
if [ "$CUR_WAKES" -le "$LAST_WAKES" ]; then
    exit 0
fi

echo "$CUR_WAKES" > "$STATE_FILE"

# ── Classify the last sleep cycle ──
# Fetch recent log lines
RECENT=$(pmset -g log 2>/dev/null | grep -E "Entering Sleep|Wake from|DarkWake" | tail -20)

# Extract last Sleep → Wake pair
LAST_SLEEP_LINE=$(echo "$RECENT" | grep "Entering Sleep" | tail -1)
LAST_WAKE_LINE=$(echo "$RECENT" | grep -E "Wake from|DarkWake" | tail -1)

[ -z "$LAST_SLEEP_LINE" ] || [ -z "$LAST_WAKE_LINE" ] && exit 0

# Determine state transition
STATE_TYPE="unknown"
if echo "$LAST_WAKE_LINE" | grep -qi "Standby"; then
    STATE_TYPE="standby"
elif echo "$LAST_WAKE_LINE" | grep -qi "Hibernate"; then
    STATE_TYPE="hibernate"
elif echo "$LAST_WAKE_LINE" | grep -qi "Normal Sleep"; then
    STATE_TYPE="normal_sleep"
fi

# Extract duration and charge from sleep line
DURATION=$(echo "$LAST_SLEEP_LINE" | grep -oE '[0-9]+ secs' | awk '{print $1}')
CHARGE_SLEEP=$(echo "$LAST_SLEEP_LINE" | grep -oE 'Charge:[ ]*[0-9]+%' | grep -oE '[0-9]+')
CHARGE_WAKE=$(echo "$LAST_WAKE_LINE" | grep -oE 'Charge:[ ]*[0-9]+%' | grep -oE '[0-9]+')

# Drain calculation
if [ -n "$CHARGE_SLEEP" ] && [ -n "$CHARGE_WAKE" ]; then
    DRAIN=$((CHARGE_SLEEP - CHARGE_WAKE))
else
    DRAIN="?"
fi

# ── Log analysis ──
{
    echo "═══════════════════════════════════════════════════════"
    echo "Wake Event: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Sleep entry : $LAST_SLEEP_LINE"
    echo "  Wake entry  : $LAST_WAKE_LINE"
    echo "  State type  : $STATE_TYPE"
    echo "  Sleep dur   : ${DURATION}s (~$((DURATION / 60))min)"
    echo "  Charge sleep: ${CHARGE_SLEEP}%"
    echo "  Charge wake : ${CHARGE_WAKE}%"
    echo "  Drain       : ${DRAIN}%"
    echo ""
} >> "$LOG"

exit 0
