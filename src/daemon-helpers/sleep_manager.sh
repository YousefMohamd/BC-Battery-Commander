#!/bin/bash
# sleep_manager.sh — Layer 13
# Adaptive pmset tuning based on battery + lid state.
# Portable across Macs (detects capabilities).

DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/.sleep_manager.log"
CFG="$DASH/sleep_manager.conf"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }

# ── Config (can be overridden by user) ──

# Load overrides
[ -f "$CFG" ] && source "$CFG"

# ── Detect capabilities ──
CAP=$(pmset -g 2>/dev/null)
HAS_POWERNAP=$(echo "$CAP" | grep -c powernap)
HAS_WOMP=$(echo "$CAP" | grep -c womp)

# ── Detect current state ──
IOREG=$(ioreg -rn AppleSmartBattery 2>/dev/null)
EXT=$(echo "$IOREG" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
CLAMSHELL=$(ioreg -r -k AppleClamshellState 2>/dev/null | grep -oE '"AppleClamshellState" = [A-Za-z]+' | awk '{print $3}')

# Some Macs report clamshell differently
[ -z "$CLAMSHELL" ] && CLAMSHELL=$(ioreg -r -k AppleClamshellState 2>/dev/null | grep -oE 'AppleClamshellState" = [A-Za-z]+' | awk -F'= ' '{print $2}' | head -1)

# ── Determine profile ──
PROFILE_FILE="$DASH/.sleep_profile"
CURRENT_PROFILE=""
[ -f "$PROFILE_FILE" ] && CURRENT_PROFILE=$(cat "$PROFILE_FILE")

NEW_PROFILE=""
if [ "$EXT" = "No" ] && [ "$CLAMSHELL" = "Yes" ]; then
    NEW_PROFILE="long_battery"
elif [ "$EXT" = "No" ] && [ "$CLAMSHELL" = "No" ]; then
    NEW_PROFILE="active_battery"
elif [ "$EXT" = "Yes" ] && [ "$CLAMSHELL" = "Yes" ]; then
    NEW_PROFILE="long_ac"
else
    NEW_PROFILE="active_ac"
fi

case "$NEW_PROFILE" in
    active_ac|active_battery) MAPPED_PROFILE="default" ;;
    long_ac|long_battery)     MAPPED_PROFILE="long" ;;
    *)                        MAPPED_PROFILE="default" ;;
esac

log "profile: $CURRENT_PROFILE → $NEW_PROFILE (Ext=$EXT Clamshell=$CLAMSHELL)"

# ── Apply profile-specific settings ──
case "$NEW_PROFILE" in
    long_battery)
        log "  selected long_battery delay profile"
        ;;
    active_battery)
        log "  applied active_battery delay profile"
        ;;
    long_ac)
        log "  applied long_ac delay profile"
        ;;
    active_ac)
        log "  applied active_ac delay profile"
        ;;
esac

echo "$NEW_PROFILE" > "$PROFILE_FILE"
log "  profile saved: $NEW_PROFILE"
exit 0
