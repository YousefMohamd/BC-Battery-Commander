#!/bin/bash
# charge_upper_watcher.sh - watch explicit charge to UPPER, stop at UPPER
# Args: BAT DASH LOG TOKEN UPPER
B="$1"; D="$2"; L="$3"; T="$4"; U="$5"
P=0
for i in $(seq 1 720); do
    sleep 10
    if [ -f "$D/.user_shutdown" ]; then
        sudo -n "$B" charge stop >/dev/null 2>&1
        [ "$(cat "$D/.charge_upper_token" 2>/dev/null)" = "$T" ] && rm -f "$D/.charge_upper_token"
        echo "[$(date +%H:%M:%S)] charge_to_upper: shutdown, stopping" >> "$L"
        break
    fi
    if ! pmset -g batt 2>/dev/null | grep -q "AC Power"; then
        sudo -n "$B" charge stop >/dev/null 2>&1
        [ "$(cat "$D/.charge_upper_token" 2>/dev/null)" = "$T" ] && rm -f "$D/.charge_upper_token"
        echo "[$(date +%H:%M:%S)] charge_to_upper: AC disconnected, stopping" >> "$L"
        break
    fi
    MODE=$(cat "$D/.active_mode" 2>/dev/null | tr -d '[:space:]')
    case "$MODE" in
        discharge|charge_full|calibration)
            echo "[$(date +%H:%M:%S)] charge_to_upper: new session $MODE, exiting without stop" >> "$L"
            [ "$(cat "$D/.charge_upper_token" 2>/dev/null)" = "$T" ] && rm -f "$D/.charge_upper_token"
            break
            ;;
    esac
    P=$(sudo -n "$B" status 2>/dev/null | grep -oE "Capacity [0-9]+" | grep -oE "[0-9]+" | head -1)
    if [ -n "$P" ] && [ "$P" -ge "$U" ]; then
        sudo -n "$B" charge stop >/dev/null 2>&1
        if [ "$P" -eq "$U" ]; then
            echo "[$(date +%H:%M:%S)] charge_to_upper: reached $U%, stopping" >> "$L"
        else
            echo "[$(date +%H:%M:%S)] charge_to_upper: overshoot $P% > $U%, stopping" >> "$L"
        fi
        [ "$(cat "$D/.charge_upper_token" 2>/dev/null)" = "$T" ] && rm -f "$D/.charge_upper_token"
        break
    fi
done
if [ "$(cat "$D/.charge_upper_token" 2>/dev/null)" = "$T" ]; then
    sudo -n "$B" charge stop >/dev/null 2>&1
    rm -f "$D/.charge_upper_token"
    echo "[$(date +%H:%M:%S)] charge_to_upper: timeout, stopping" >> "$L"
fi
echo "[$(date +%H:%M:%S)] charge_to_upper: watcher finished" >> "$L"
exit 0
