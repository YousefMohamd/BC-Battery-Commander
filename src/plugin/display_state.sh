#!/bin/bash
# display_state.sh - separate display-state system for BattOpt (read-only, no state writes)
# Reads hardware + mode once, decides ICON + colours in one table.
# Output (for eval by the plugin):
#   DISPLAY_MODE=... ICON=... STATE_COLOR=color=... FINAL_COLOR=color=...
# Exit 1 (no output) if ioreg data is missing, so the plugin falls back to its inline logic.
MODE_IN="${DISPLAY_MODE:-}"
TEMP_IN="${TEMP_INT:-}"
IOREG_DATA=$(ioreg -rn AppleSmartBattery 2>/dev/null)
[ -z "$IOREG_DATA" ] && exit 1
ICON_EXT=$(echo "$IOREG_DATA" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
ICON_ISCHG=$(echo "$IOREG_DATA" | grep -oE '"IsCharging" = [A-Za-z]+' | awk '{print $3}')
ICON_NCR=$(echo "$IOREG_DATA" | grep -oE '"NotChargingReason"=[0-9]+' | grep -oE '[0-9]+' | head -1)
[ -z "$ICON_EXT" ] && exit 1
[ -z "$ICON_ISCHG" ] && exit 1
[ -z "$ICON_NCR" ] && ICON_NCR=0
DISPLAY_MODE="$MODE_IN"
if [ "$ICON_NCR" = "14" ] && [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ] && \
   [ "$DISPLAY_MODE" != "discharge" ] && [ "$DISPLAY_MODE" != "calibration" ]; then
    DISPLAY_MODE="hold"
fi
if [ "$DISPLAY_MODE" = "discharge" ]; then
    if ! pgrep -f "battopt discharge" >/dev/null 2>&1; then
        # AUTODIS: trust an active session token through process gaps
        # (AC disconnect / restart). Demote only when no token remains.
        if [ ! -s "$HOME/.battopt-swiftbar/.active_token" ]; then
            DISPLAY_MODE="hold"
        fi
    fi
fi
if [ "$DISPLAY_MODE" != "discharge" ] && pgrep -f "battopt discharge" >/dev/null 2>&1; then
    DISPLAY_MODE="discharge"
fi
if [ "$DISPLAY_MODE" = "discharge" ]; then
    ICON="🔋"
elif [ "$ICON_EXT" = "No" ] && [ "$ICON_ISCHG" = "No" ]; then
    ICON="🔴"
elif [ "$DISPLAY_MODE" = "charge_full" ] || [ "$DISPLAY_MODE" = "calibration" ]; then
    ICON="⚡"
elif [ "$ICON_ISCHG" = "Yes" ]; then
    ICON="⚡"
elif [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
    ICON="🔌"
else
    ICON="🔴"
fi
if [ "$ICON_ISCHG" = "Yes" ]; then
    STATE_COLOR="color=#707070"
elif [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
    STATE_COLOR="color=#FFFFFF"
else
    STATE_COLOR="color=#E8A0A0"
fi
if [ "$DISPLAY_MODE" = "discharge" ]; then
    FINAL_COLOR="color=#8A9AAB"
elif [ -n "$TEMP_IN" ] && [ "$TEMP_IN" -ge 42 ] 2>/dev/null; then
    FINAL_COLOR="color=#FF3B30"
elif [ -n "$TEMP_IN" ] && [ "$TEMP_IN" -ge 38 ] 2>/dev/null; then
    FINAL_COLOR="color=#FF9500"
else
    FINAL_COLOR="$STATE_COLOR"
fi
printf 'DISPLAY_MODE=%s\nICON=%s\nSTATE_COLOR=%s\nFINAL_COLOR=%s\n' "$DISPLAY_MODE" "$ICON" "$STATE_COLOR" "$FINAL_COLOR"
exit 0
