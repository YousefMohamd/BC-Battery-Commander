#!/bin/bash

# Layer 15: battery-mode throttle
source "/Users/Yousef/.battopt-swiftbar/.throttle_helper.sh" 2>/dev/null && ac_throttle "adaptive_governor" 300

# Adaptive Power Governor — pause charging when hot or under load
LOG="$HOME/.battopt-swiftbar/actions.log"
STATE_FILE="$HOME/.battopt-swiftbar/.apg_state"
PAUSED_FILE="$HOME/.battopt-swiftbar/.apg_paused"

log() { echo "[$(date '+%H:%M:%S')] apg: $1" >> "$LOG"; }

[ -f "$HOME/.battopt-swiftbar/.apg_off" ] && exit 0

SNAP=$(sudo -n battopt status 2>/dev/null)
[ -z "$SNAP" ] && exit 0

TEMP=$(echo "$SNAP" | grep -oE '[0-9]+\.[0-9]+°C' | head -1 | sed 's/°C//')
[ -z "$TEMP" ] && exit 0

LOAD=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
CHARGE_STATE=$(echo "$SNAP" | grep -oE 'charging|discharging|no charging' | head -1)

PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "green")
TEMP_INT=${TEMP%.*}
LOAD_INT=${LOAD%.*}

# Determine new state
if [ "$TEMP_INT" -gt 42 ] || [ "$LOAD_INT" -gt 6 ]; then
    NEW_STATE="red"
elif [ "$TEMP_INT" -ge 38 ] || [ "$LOAD_INT" -ge 4 ]; then
    NEW_STATE="yellow"
else
    NEW_STATE="green"
fi

# Hysteresis — prevents oscillation
# Red → Green: must pass through Yellow unless cooled by 2°C
if [ "$PREV_STATE" = "red" ] && [ "$NEW_STATE" = "green" ]; then
    if [ "$TEMP_INT" -gt 40 ] || [ "$LOAD_INT" -gt 5 ]; then
        NEW_STATE="yellow"
    fi
fi

# Yellow → Green: must cool 1°C below threshold
if [ "$PREV_STATE" = "yellow" ] && [ "$NEW_STATE" = "green" ]; then
    if [ "$TEMP_INT" -ge 37 ] || [ "$LOAD_INT" -ge 3 ]; then
        NEW_STATE="yellow"
    fi
fi

# Act on state change
if [ "$NEW_STATE" != "$PREV_STATE" ]; then
    case "$NEW_STATE" in
        green)
            log "state=GREEN (T=${TEMP}°C L=${LOAD})"
            if [ -f "$PAUSED_FILE" ]; then
                rm -f "$PAUSED_FILE"
                source "$HOME/.battopt-swiftbar/config" 2>/dev/null
                sudo -n battopt limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
                notify "BattOpt" "System cooled — charging resumed"
            fi
            ;;
        yellow)
            log "state=YELLOW (T=${TEMP}°C L=${LOAD})"
            if [ "$CHARGE_STATE" = "charging" ]; then
                CURRENT=$(echo "$SNAP" | grep -oE 'Capacity [0-9]+' | grep -oE '[0-9]+' | head -1)
                [ -n "$CURRENT" ] && {
                    sudo -n battopt limit "$CURRENT" "$((CURRENT - 1))" >> "$LOG" 2>&1
                    touch "$PAUSED_FILE"
                    notify "BattOpt" "Warm — charging paused at ${CURRENT}%"
                }
            fi
            ;;
        red)
            log "state=RED (T=${TEMP}°C L=${LOAD})"
            CURRENT=$(echo "$SNAP" | grep -oE 'Capacity [0-9]+' | grep -oE '[0-9]+' | head -1)
            [ -n "$CURRENT" ] && {
                sudo -n battopt limit "$CURRENT" "$((CURRENT - 1))" >> "$LOG" 2>&1
                touch "$PAUSED_FILE"
                notify "BattOpt" "🔥 Hot (${TEMP}°C) — charging stopped"
            }
            ;;
    esac
    echo "$NEW_STATE" > "$STATE_FILE"
fi

exit 0