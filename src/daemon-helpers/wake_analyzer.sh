#!/bin/bash
# wake_analyzer.sh — Layer 14
# After each wake, classify what happened and log to .sleep_analysis.log.

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
LOG="$DASH/.sleep_analysis.log"
STATE_FILE="$DASH/.last_wake_count"

# Get current wake count
CUR_WAKES=$(pmset -g log 2>/dev/null | grep -cE "Wake from|DarkWake")
LAST_WAKES=0
[ -f "$STATE_FILE" ] && LAST_WAKES=$(cat "$STATE_FILE" 2>/dev/null)
case "$LAST_WAKES" in ''|*[!0-9]*) LAST_WAKES=0 ;; esac
case "$CUR_WAKES" in ''|*[!0-9]*) CUR_WAKES=0 ;; esac

# pmset log rotates: the count can DECREASE. A decrease is a rotation,
# not "no new wakes" — reset the baseline and analyze this wake, or the
# high-water mark goes blind forever (audit 2026-11-11, W14).
if [ "$CUR_WAKES" -lt "$LAST_WAKES" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] wake_analyzer: pmset log rotated (wakes $LAST_WAKES -> $CUR_WAKES) — resetting baseline" >> "$LOG"
    LAST_WAKES="$CUR_WAKES"
fi

# Only proceed if new wakes happened
if [ "$CUR_WAKES" -le "$LAST_WAKES" ]; then
    exit 0
fi

printf '%s\n' "$CUR_WAKES" > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"

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
    echo "  Sleep dur   : ${DURATION:-?}s (~$(( ${DURATION:-0} / 60 ))min)"
    echo "  Charge sleep: ${CHARGE_SLEEP}%"
    echo "  Charge wake : ${CHARGE_WAKE}%"
    echo "  Drain       : ${DRAIN}%"
    echo ""
} >> "$LOG"

exit 0
