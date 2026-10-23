#!/bin/bash
LOG="$HOME/.battopt-swiftbar/maintenance.log"; exec >> "$LOG" 2>&1
DASH="$HOME/.battopt-swiftbar"
FAIL_REASON=""

# 1. Daemon responsive
if ! sudo -n /usr/local/bin/battopt status >/dev/null 2>&1; then
    FAIL_REASON="Daemon is not responding"
fi

# 2. SMC Hold Check (Smart Logic)
if [ -z "$FAIL_REASON" ]; then
    source "$DASH/config" 2>/dev/null
    UPPER=${LAST_UPPER:-85}

    BATT_DATA=$(ioreg -rn AppleSmartBattery 2>/dev/null)
    CUR=$(echo "$BATT_DATA" | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
    MAX=$(echo "$BATT_DATA" | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')
    EXT=$(echo "$BATT_DATA" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
    NCR=$(echo "$BATT_DATA" | grep -oE '"NotChargingReason"=[0-9]+' | cut -d= -f2)

    if [ "$MAX" -gt 0 ] 2>/dev/null; then
        PCT=$(( (CUR * 100 + MAX / 2) / MAX ))
    else
        PCT=""
    fi

    if [ "$EXT" = "Yes" ] && [ -n "$PCT" ] && [ "$PCT" -ge "$UPPER" ] && [ "$NCR" != "14" ]; then
        FAIL_REASON="SMC not holding at $UPPER% (Current: $PCT%, NCR: $NCR)"
    fi
fi

# 3. Hung Shutdown
if [ -z "$FAIL_REASON" ]; then
    if pgrep -f "dispatch.sh shutdown" >/dev/null 2>&1; then
        FAIL_REASON="Hung dispatch.sh shutdown process detected"
    fi
fi

# 4. Disk Space (20GB)
if [ -z "$FAIL_REASON" ]; then
    FREE_GB=$(df -g /var/vm | tail -1 | awk '{print $4}')
    if [ "$FREE_GB" -lt 20 ]; then
        FAIL_REASON="Low disk space in /var/vm ($FREE_GB GB, need 20 GB)"
    fi
fi

# 5. Process Storm
if [ -z "$FAIL_REASON" ]; then
    GUARD_CNT=$(pgrep -f "guardian.sh" | wc -l | tr -d ' ')
    if [ "$GUARD_CNT" -gt 5 ]; then
        FAIL_REASON="Guardian process storm ($GUARD_CNT instances)"
    fi
fi

if [ -z "$FAIL_REASON" ]; then
    echo "[PASS] all self-maintenance checks"
else
    echo "[FAIL] $FAIL_REASON"

    ALERT_FLAG="$DASH/.maint_alerted"
    ALERT_COOLDOWN=3600
    NOW=$(date +%s)
    LAST_ALERT=$(cat "$ALERT_FLAG" 2>/dev/null || echo 0)

    if [ $((NOW - LAST_ALERT)) -gt "$ALERT_COOLDOWN" ]; then
        /Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier \
            -title "BattOpt Alert" \
            -message "$FAIL_REASON"
        echo "$NOW" > "$ALERT_FLAG"
    fi
fi
