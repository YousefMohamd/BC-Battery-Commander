#!/bin/bash
# Predictive Diagnostics — detect trends before they become problems

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
LOG="$DASH/actions.log"
DATA="$DASH/predictive_data"
BC_BUILD_DIR="${BC_BUILD_DIR:-$HOME/Projects/BattOpt-CC-Release/battopt-project/bc-build}"
mkdir -p "$DATA"

log() { echo "[$(date '+%H:%M:%S')] predict: $1" >> "$LOG"; }
# Guard: respect shutdown
if [ -f "$DASH/.user_shutdown" ]; then
    log "shutdown flag present - skipping predict"
    exit 0
fi


STAMP=$(date +%Y%m%d_%H)
SNAP="$DATA/snap_$STAMP.txt"

# Collect data
{
echo "TS=$(date +%s)"
echo "LOAD=$(sysctl -n vm.loadavg | awk '{print $2}')"
echo "SWAP=$(sysctl vm.swapusage | awk '{print $7}' | tr -d 'M')"
# BC: TEMP/HEALTH/CYCLES from bc-status (read-only), never battopt.
BC_OUT=""
[ -x "$BC_BUILD_DIR/bc-status" ] && BC_OUT=$("$BC_BUILD_DIR/bc-status" 2>/dev/null)
echo "TEMP=$(echo "$BC_OUT" | grep '^TempBatteryPack:' | grep -oE '[0-9.]+' | head -1)"
echo "BATT=$(pmset -g batt | grep -oE '[0-9]+%' | head -1 | tr -d '%')"
echo "HEALTH=$(echo "$BC_OUT" | grep '^Health:' | grep -oE '[0-9.]+' | head -1)"
echo "CYCLES=$(echo "$BC_OUT" | grep '^Cycle:' | grep -oE '[0-9]+' | head -1)"
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
        # Notify at most once a day (audit 2026-11-11, W13): the trend
        # persists for hours, so an uncooled notify fires every run.
        _tr_last=0
        [ -f "$DATA/.temp_rise_last" ] && _tr_last=$(cat "$DATA/.temp_rise_last" 2>/dev/null || echo 0)
        case "$_tr_last" in ''|*[!0-9]*) _tr_last=0 ;; esac
        if [ $(( $(date +%s) - _tr_last )) -ge 86400 ]; then
            # App-native transport (final cleanup 2026-11-18):
            # queue for BatteryCommander.app to post natively.
            printf '%s\t%s\n' "Battery Commander Predictive" "Temperature rising fast ($TEMP_DELTA°C/24h)" >> "$DASH/.notify_queue" 2>/dev/null || true
            echo "$(date +%s)" > "$DATA/.temp_rise_last"
        fi
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
    # HEALTH was never a shell variable — read the current value from
    # this run's snapshot (audit 2026-11-11, W13; the comparison was dead).
    CUR=$(grep HEALTH= "$SNAP" | cut -d= -f2)
    case "$BASE" in ''|*[!0-9.]*) BASE="" ;; esac
    case "$CUR" in ''|*[!0-9.]*) CUR="" ;; esac
    if [ -n "$BASE" ] && [ -n "$CUR" ]; then
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
