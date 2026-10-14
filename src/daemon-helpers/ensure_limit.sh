#!/bin/bash
# Ensure limit is applied — runs after daemon restart
CONFIG="$HOME/.battopt-swiftbar/config"
LOG="$HOME/.battopt-swiftbar/actions.log"
[ -f "$CONFIG" ] && source "$CONFIG"

# === ACTIVE SESSION GUARD ===
# Skip if ANY session is active (charge_full, discharge, hold, calibrating)
if [ -f "$HOME/.battopt-swiftbar/state_guard.sh" ]; then
    source "$HOME/.battopt-swiftbar/state_guard.sh"
    if guard_session_active; then
        ACTIVE=$(cat "$HOME/.battopt-swiftbar/.active_mode" 2>/dev/null)
        echo "[$(date '+%H:%M:%S')] ensure_limit: active session ($ACTIVE) — skipping" >> "$LOG"
        exit 0
    fi
fi
# Also skip on legacy .sd_session (belt-and-suspenders)
if [ -f "$HOME/.battopt-swiftbar/.sd_session" ]; then
    SD_ID=$(cat "$HOME/.battopt-swiftbar/.sd_session" 2>/dev/null)
    if [ -n "$SD_ID" ] && [ "$SD_ID" != "none" ]; then
        echo "[$(date '+%H:%M:%S')] ensure_limit: SD session active ($SD_ID) — skipping" >> "$LOG"
        exit 0
    fi
fi
# === END GUARD ===

UPPER="${LAST_UPPER:-85}"
LOWER="${LAST_LOWER:-80}"

# Wait for daemon to be ready (max 10s)
for i in 1 2 3 4 5 6 7 8 9 10; do
    if sudo -n /usr/local/bin/battopt status 2>/dev/null | grep -q "Capacity"; then
        break
    fi
    sleep 1
done

STATUS=$(sudo -n /usr/local/bin/battopt status 2>/dev/null)
CURRENT=$(echo "$STATUS" | grep -oE "upper limit [0-9]+" | grep -oE "[0-9]+")

# Fix: narrow pattern — only when ACTUAL limit is disabled
if echo "$STATUS" | grep -qE "Charge limit is suspended|Charge limit: disabled"; then
    echo "[$(date '+%H:%M:%S')] ensure_limit: suspended — reapplying $UPPER/$LOWER" >> "$LOG"
    sudo -n /usr/local/bin/battopt limit "$UPPER" "$LOWER" >> "$LOG" 2>&1
    exit 0
fi

if [ -z "$CURRENT" ]; then
    echo "[$(date '+%H:%M:%S')] ensure_limit: no limit reported — applying $UPPER/$LOWER" >> "$LOG"
    sudo -n /usr/local/bin/battopt limit "$UPPER" "$LOWER" >> "$LOG" 2>&1
elif [ "$CURRENT" != "$UPPER" ]; then
    echo "[$(date '+%H:%M:%S')] ensure_limit: mismatch $CURRENT≠$UPPER — reapplying" >> "$LOG"
    sudo -n /usr/local/bin/battopt limit "$UPPER" "$LOWER" >> "$LOG" 2>&1
fi

exit 0
