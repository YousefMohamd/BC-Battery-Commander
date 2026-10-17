#!/bin/bash
# BattOpt Charging Guard — fast overshoot prevention (2s poll)
# Runs from LaunchAgent. Reads ioreg only. Zero battery impact.
HOME="${HOME:-/Users/Yousef}"
DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
BAT="/usr/local/bin/battopt"
COOLDOWN="$DASH/.charging_guard_cooldown"

[ -f "$DASH/.user_shutdown" ] && exit 0

# Serialize with ac_watcher/guardian via state_guard lock
source "$DASH/state_guard.sh" 2>/dev/null || true

# Cooldown (30s) to avoid spamming charge stop
if [ -f "$COOLDOWN" ]; then
    AGE=$(( $(date +%s) - $(stat -f %m "$COOLDOWN" 2>/dev/null || echo 0) ))
    [ "$AGE" -lt 30 ] && exit 0
    rm -f "$COOLDOWN"
fi

# Read state with retry (ioreg can be empty under load)
IOREG=""
for _try in 1 2 3; do
    IOREG=$(ioreg -rn AppleSmartBattery 2>/dev/null)
    [ -n "$IOREG" ] && break
    sleep 0.2
done
if [ -z "$IOREG" ]; then
    echo "[$(date '+%H:%M:%S')] charging_guard: ioreg FAILED after 3 retries" >> "$LOG"
    exit 0
fi
ISCHG=$(echo "$IOREG" | grep -oE '"IsCharging" = [A-Za-z]+' | awk '{print $3}')
EXT=$(echo "$IOREG" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
CUR=$(echo "$IOREG" | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
MAX=$(echo "$IOREG" | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')
[ -z "$CUR" ] || [ -z "$MAX" ] || [ "$MAX" -eq 0 ] && exit 0
PCT=$(( (CUR * 100 + MAX / 2) / MAX ))

# Skip if not charging
[ "$EXT" = "Yes" ] && [ "$ISCHG" = "Yes" ] || exit 0

# Read config
CFG="$DASH/config"
UPPER=85
[ -f "$CFG" ] && source "$CFG"

# Skip if overshoot not happening
[ "$PCT" -le "$UPPER" ] && exit 0

# Skip if active session in progress
MODE=$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')
case "$MODE" in
    charge_full|discharge|calibration) exit 0 ;;
esac

# OVERSHOOT DETECTED — act immediately
if ! guard_lock; then
    echo "[$(date '+%H:%M:%S')] charging_guard: lock failed — skipping" >> "$LOG"
    exit 0
fi
# Re-check mode after acquiring lock (avoid stale read)
MODE2=$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')
case "$MODE2" in
    charge_full|discharge|calibration)
        guard_unlock
        exit 0
        ;;
esac
echo "[$(date '+%H:%M:%S')] charging_guard: OVERSHOOT PCT=$PCT > UPPER=$UPPER — stopping charge" >> "$LOG"
sudo -n "$BAT" charge stop >/dev/null 2>&1
sleep 1
sudo -n "$BAT" limit "$UPPER" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
# Verify SMC took effect
V=$(sudo -n "$BAT" status 2>/dev/null | grep -oE 'upper limit [0-9]+' | grep -oE '[0-9]+' | head -1)
if [ "$V" != "$UPPER" ]; then
    sleep 1
    sudo -n "$BAT" limit "$UPPER" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
    echo "[$(date '+%H:%M:%S')] charging_guard: verify-retry SMC=$V want=$UPPER" >> "$LOG"
fi
touch "$COOLDOWN"
guard_unlock
