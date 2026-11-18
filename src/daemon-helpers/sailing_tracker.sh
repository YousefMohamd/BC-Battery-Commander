#!/bin/bash
# Sailing Tracker — Records battery transitions within sailing range
# Runs every 10 minutes via the watchdog consolidated fold (600 s)
# Provides honest data on Intel Mac Sailing Mode (which is mostly static)

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
STATE="$DASH/.sailing_state"
HISTORY="$DASH/.sailing_history"

log() { echo "[$(date '+%H:%M:%S')] sailing: $1" >> "$LOG"; }

# Get current state (BC: no battopt — PCT from ioreg, limits from
# the canonical config; STATE_BATT was computed but never used).
IOREG=$(ioreg -rn AppleSmartBattery 2>/dev/null)
CUR=$(echo "$IOREG" | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
MAX=$(echo "$IOREG" | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')
PCT=""
if [ -n "$CUR" ] && [ -n "$MAX" ] && [ "$MAX" -gt 0 ] 2>/dev/null; then
    PCT=$((CUR * 100 / MAX))
fi
[ -z "$PCT" ] && exit 0
UPPER=86
LOWER=85
if [ -f "$DASH/config" ]; then
    while IFS='=' read -r _k _v; do
        case "$_k" in
            LAST_UPPER) UPPER="$_v" ;;
            LAST_LOWER) LOWER="$_v" ;;
        esac
    done < "$DASH/config"
fi
case "$UPPER" in ''|*[!0-9]*) UPPER=86 ;; esac
case "$LOWER" in ''|*[!0-9]*) LOWER=85 ;; esac

# Read previous state
LAST_PCT=""
LAST_DIR=""
LAST_TIME=""
TRANSITIONS=0
# Previous state: KEY=value parse, never source a data file.
if [ -f "$STATE" ]; then
    while IFS='=' read -r _k _v; do
        case "$_k" in
            LAST_PCT) LAST_PCT="$_v" ;;
            LAST_DIR) LAST_DIR="$_v" ;;
            LAST_TIME) LAST_TIME="$_v" ;;
            TRANSITIONS) TRANSITIONS="$_v" ;;
        esac
    done < "$STATE"
fi
TRANSITIONS=${TRANSITIONS:-0}
case "$TRANSITIONS" in ''|*[!0-9]*) TRANSITIONS=0 ;; esac

# Determine direction
if [ -n "$UPPER" ] && [ -n "$LOWER" ]; then
    MID=$(( (UPPER + LOWER) / 2 ))
    
    if [ "$PCT" -ge "$MID" ]; then
        DIR="up"
    else
        DIR="down"
    fi
    
    # Detect transitions
    if [ -n "$LAST_DIR" ] && [ "$DIR" != "$LAST_DIR" ]; then
        TRANSITIONS=$((TRANSITIONS + 1))
        echo "$(date '+%Y-%m-%d %H:%M:%S') | $PCT% | $LAST_DIR→$DIR | range $LOWER-$UPPER" >> "$HISTORY"
        # Trim the history (audit 2026-11-11, W15): it grew unbounded.
        _hcount=$(wc -l < "$HISTORY" 2>/dev/null | tr -d ' ')
        if [ "${_hcount:-0}" -gt 200 ]; then
            tail -200 "$HISTORY" > "$HISTORY.tmp.$$" && mv "$HISTORY.tmp.$$" "$HISTORY"
        fi
        log "Transition: $LAST_DIR → $DIR at $PCT% (total: $TRANSITIONS)"
    fi
fi

# Save current state (atomic — tmp+mv; a torn .sailing_state would be
# parsed as empty on the next run and reset the transition count).
{
echo "LAST_PCT=$PCT"
echo "LAST_DIR=$DIR"
echo "LAST_TIME=$(date '+%Y-%m-%d %H:%M:%S')"
echo "TRANSITIONS=$TRANSITIONS"
echo "UPPER=$UPPER"
echo "LOWER=$LOWER"
} > "$STATE.tmp.$$" && mv "$STATE.tmp.$$" "$STATE"

exit 0
