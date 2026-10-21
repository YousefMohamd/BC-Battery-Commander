#!/bin/bash
# Predictive Diagnostics — detect trends before they become problems

LOG="$HOME/.battopt-swiftbar/actions.log"
DATA="$HOME/.battopt-swiftbar/predictive_data"
mkdir -p "$DATA"

log() { echo "[$(date '+%H:%M:%S')] predict: $1" >> "$LOG"; }

STAMP=$(date +%Y%m%d_%H)
SNAP="$DATA/snap_$STAMP.txt"

# Collect data
{
echo "TS=$(date +%s)"
echo "LOAD=$(sysctl -n vm.loadavg | awk '{print $2}')"
echo "SWAP=$(sysctl vm.swapusage | awk '{print $7}' | tr -d 'M')"
echo "TEMP=$(sudo battopt status 2>/dev/null | grep -oE '[0-9.]+.C' | head -1 | tr -d '°C')"
echo "BATT=$(pmset -g batt | grep -oE '[0-9]+%' | head -1 | tr -d '%')"
echo "HEALTH=$(sudo battopt status 2>/dev/null | grep -oE 'Health [0-9.]+' | grep -oE '[0-9.]+')"
echo "CYCLES=$(sudo battopt status 2>/dev/null | grep -oE 'Cycle [0-9]+' | grep -oE '[0-9]+')"
echo "PROC=$(ps aux | wc -l | tr -d ' ')"
} > "$SNAP"

# Analyze trends (last 24 snapshots = 24 hours)
SNAPS=$(ls -t "$DATA"/snap_*.txt 2>/dev/null | head -24 | tail -r)
if [ -z "$SNAPS" ]; then
    log "First run — no trend yet"
    exit 0
fi

# Temperature trend
TEMP_FIRST=$(grep TEMP= $(echo "$SNAPS" | head -1) | cut -d= -f2)
TEMP_LAST=$(grep TEMP= $(echo "$SNAPS" | tail -1) | cut -d= -f2)
if [ -n "$TEMP_FIRST" ] && [ -n "$TEMP_LAST" ]; then
    TEMP_DELTA=$(echo "$TEMP_LAST - $TEMP_FIRST" | bc)
    if (( $(echo "$TEMP_DELTA > 5" | bc -l) )); then
        log "PREDICT: Temp rising $TEMP_DELTA°C in 24h"
        osascript -e "display notification \"Temperature rising fast ($TEMP_DELTA°C/24h)\" with title \"BattOpt Predictive\"" 2>/dev/null
    fi
fi

# Swap trend
SWAP_FIRST=$(grep SWAP= $(echo "$SNAPS" | head -1) | cut -d= -f2)
SWAP_LAST=$(grep SWAP= $(echo "$SNAPS" | tail -1) | cut -d= -f2)
if [ -n "$SWAP_FIRST" ] && [ -n "$SWAP_LAST" ]; then
    SWAP_DELTA=$(echo "${SWAP_LAST%.*} - ${SWAP_FIRST%.*}" | bc)
    if [ "$SWAP_DELTA" -gt 500 ]; then
        log "PREDICT: Swap growing ${SWAP_DELTA} MB in 24h — restart recommended"
    fi
fi

# Process count trend
PROC_FIRST=$(grep PROC= $(echo "$SNAPS" | head -1) | cut -d= -f2)
PROC_LAST=$(grep PROC= $(echo "$SNAPS" | tail -1) | cut -d= -f2)
if [ -n "$PROC_FIRST" ] && [ -n "$PROC_LAST" ]; then
    PROC_DELTA=$((PROC_LAST - PROC_FIRST))
    if [ "$PROC_DELTA" -gt 100 ]; then
        log "PREDICT: Processes growing $PROC_DELTA in 24h — leak suspected"
    fi
fi

# Health trend (slower, check weekly)
if [ -f "$DATA/health_baseline" ]; then
    BASE=$(cat "$DATA/health_baseline")
    CUR=$(echo "$HEALTH")
    if [ -n "$CUR" ]; then
        DELTA=$(echo "$BASE - $CUR" | bc)
        if (( $(echo "$DELTA > 2" | bc -l) )); then
            log "PREDICT: Health dropped $DELTA% since baseline"
        fi
    fi
else
    echo "$(grep HEALTH= $SNAP | cut -d= -f2)" > "$DATA/health_baseline"
fi

# Cleanup old data (> 7 days)
find "$DATA" -name "snap_*.txt" -mtime +7 -delete 2>/dev/null

exit 0
