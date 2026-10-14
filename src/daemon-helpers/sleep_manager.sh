#!/bin/bash
# sleep_manager.sh — Layer 13
# Adaptive pmset tuning based on battery + lid state.
# Portable across Macs (detects capabilities).

DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/.sleep_manager.log"
CFG="$DASH/sleep_manager.conf"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }

# ── Config (can be overridden by user) ──
LONG_SLEEP_THRESHOLD="${LONG_SLEEP_THRESHOLD:-3600}"   # 1 hour
SHORT_SLEEP_THRESHOLD="${SHORT_SLEEP_THRESHOLD:-300}"  # 5 min

# Load overrides
[ -f "$CFG" ] && source "$CFG"

# ── Detect capabilities ──
CAP=$(pmset -g 2>/dev/null)
HAS_STANDBYDELAY=$(echo "$CAP" | grep -c standbydelay)
HAS_AUTOPOWEROFF=$(echo "$CAP" | grep -c autopoweroff)
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
    # On battery + lid closed → long sleep profile
    NEW_PROFILE="long_battery"
elif [ "$EXT" = "No" ] && [ "$CLAMSHELL" = "No" ]; then
    NEW_PROFILE="active_battery"
elif [ "$EXT" = "Yes" ] && [ "$CLAMSHELL" = "Yes" ]; then
    NEW_PROFILE="long_ac"
else
    NEW_PROFILE="active_ac"
fi

# ── Skip if no change ──
[ "$NEW_PROFILE" = "$CURRENT_PROFILE" ] && exit 0

log "profile: $CURRENT_PROFILE → $NEW_PROFILE (Ext=$EXT Clamshell=$CLAMSHELL)"

# ── Apply profile ──
case "$NEW_PROFILE" in
    long_battery)
        # Defer standby 1 hour — respects user's preference
        if [ "$HAS_STANDBYDELAY" -gt 0 ]; then
            sudo -n /usr/bin/pmset -b standbydelayhigh "$LONG_SLEEP_THRESHOLD" 2>/dev/null
            sudo -n /usr/bin/pmset -b standbydelaylow "$LONG_SLEEP_THRESHOLD" 2>/dev/null
            log "  set standbydelay=$LONG_SLEEP_THRESHOLD (battery)"
        fi
        if [ "$HAS_AUTOPOWEROFF" -gt 0 ]; then
            sudo -n /usr/bin/pmset -b autopoweroffdelay 1800 2>/dev/null
            log "  set autopoweroffdelay=1800"
        fi
        [ "$HAS_POWERNAP" -gt 0 ] && sudo -n /usr/bin/pmset -b powernap 0 2>/dev/null
        [ "$HAS_WOMP" -gt 0 ] && sudo -n /usr/bin/pmset -b womp 0 2>/dev/null
        ;;
    active_battery)
        # Normal active battery — short standby delay
        if [ "$HAS_STANDBYDELAY" -gt 0 ]; then
            sudo -n /usr/bin/pmset -b standbydelayhigh "$SHORT_SLEEP_THRESHOLD" 2>/dev/null
            sudo -n /usr/bin/pmset -b standbydelaylow "$SHORT_SLEEP_THRESHOLD" 2>/dev/null
            log "  set standbydelay=$SHORT_SLEEP_THRESHOLD (active battery)"
        fi
        ;;
    long_ac)
        # AC long — no hibernate needed, just keep responsive
        log "  AC + lid closed — no changes needed"
        ;;
    active_ac)
        log "  active AC — no changes needed"
        ;;
esac

echo "$NEW_PROFILE" > "$PROFILE_FILE"
log "  profile saved: $NEW_PROFILE"
exit 0
