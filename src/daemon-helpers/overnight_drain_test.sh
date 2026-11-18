#!/bin/bash
# Measure net battery drain over an overnight interval and capture pmset state.

set -u

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
OUTPUT_DIR="$DASH/overnight-tests"
DURATION_HOURS="${1:-10}"
INTERVAL_SECONDS="${2:-300}"
PMSET_BIN="${PMSET_BIN:-/usr/bin/pmset}"

# Validate the numeric args up front: a bad interval would spin a tight
# loop for hours; a zero duration divides by zero at the end (audit
# 2026-11-11, W25).
case "$DURATION_HOURS" in ''|*[!0-9.]*) echo "usage: $0 [hours] [interval_seconds] (positive numbers)" >&2; exit 1 ;; esac
case "$INTERVAL_SECONDS" in ''|*[!0-9]*) echo "usage: $0 [hours] [interval_seconds] (positive numbers)" >&2; exit 1 ;; esac
if [ "$(awk -v h="$DURATION_HOURS" 'BEGIN { print (h > 0) ? 1 : 0 }')" != "1" ]; then
    echo "duration must be > 0 hours" >&2; exit 1
fi
if [ "$INTERVAL_SECONDS" -le 0 ] 2>/dev/null; then
    echo "interval must be > 0 seconds" >&2; exit 1
fi

mkdir -p "$OUTPUT_DIR"

RUN_ID=$(date '+%Y%m%d-%H%M%S')
RESULT_FILE="$OUTPUT_DIR/$RUN_ID.txt"
SAMPLES_FILE="$OUTPUT_DIR/$RUN_ID-samples.tsv"

[ -x "$PMSET_BIN" ] || {
    echo "pmset was not found at $PMSET_BIN" >&2
    exit 1
}

read_battery_snapshot() {
    local output percent source

    output=$("$PMSET_BIN" -g batt 2>&1)
    percent=$(printf '%s\n' "$output" | grep -oE '[0-9]+%' | head -1 | tr -d '%')

    if printf '%s\n' "$output" | grep -q 'AC Power'; then
        source="AC"
    elif printf '%s\n' "$output" | grep -q 'Battery Power'; then
        source="Battery"
    else
        source="Unknown"
    fi

    printf '%s|%s\n' "$percent" "$source"
}

# read_mah — "cur|max" mAh from ioreg (energy proxy for the S1 H8 gauge
# analysis: % is an estimate and can jump; mAh is the physical reading).
read_mah() {
    local _io _cur _max
    _io=$(ioreg -rn AppleSmartBattery 2>/dev/null)
    _cur=$(printf '%s\n' "$_io" | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}' | head -1)
    _max=$(printf '%s\n' "$_io" | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}' | head -1)
    printf '%s|%s\n' "${_cur:-?}" "${_max:-?}"
}

START_EPOCH=$(date +%s)
START_SNAPSHOT=$(read_battery_snapshot)
START_PERCENT=${START_SNAPSHOT%%|*}
START_SOURCE=${START_SNAPSHOT#*|}
START_MAH=$(read_mah)

if [ -z "$START_PERCENT" ]; then
    echo "Could not read the starting battery percentage." >&2
    "$PMSET_BIN" -g batt >&2 || true
    exit 1
fi

{
    printf 'Battery Commander Overnight Drain Test\n'
    printf 'Started: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'Duration target: %s hours\n' "$DURATION_HOURS"
    printf 'Sampling interval: %s seconds\n' "$INTERVAL_SECONDS"
    printf 'Starting battery: %s%% (%s)\n' "$START_PERCENT" "$START_SOURCE"
    printf 'Starting mAh: %s / %s (CurrentCapacity / MaxCapacity)\n' "${START_MAH%|*}" "${START_MAH#*|}"
    printf '\nInitial pmset -g ps:\n'
    "$PMSET_BIN" -g ps 2>&1
    printf '\nSamples:\n'
} > "$RESULT_FILE"

printf 'timestamp_epoch\ttimestamp\tbattery_percent\tpower_source\n' > "$SAMPLES_FILE"

while :; do
    NOW_EPOCH=$(date +%s)
    NOW_SNAPSHOT=$(read_battery_snapshot)
    NOW_PERCENT=${NOW_SNAPSHOT%%|*}
    NOW_SOURCE=${NOW_SNAPSHOT#*|}

    printf '%s\t%s\t%s\t%s\n' \
        "$NOW_EPOCH" \
        "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
        "$NOW_PERCENT" \
        "$NOW_SOURCE" >> "$SAMPLES_FILE"

    {
        printf '%s  battery=%s%% source=%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
            "$NOW_PERCENT" \
            "$NOW_SOURCE"
    } >> "$RESULT_FILE"

    ELAPSED=$((NOW_EPOCH - START_EPOCH))
    TARGET_SECONDS=$(awk -v hours="$DURATION_HOURS" 'BEGIN { printf "%d", hours * 3600 }')

    if [ "$ELAPSED" -ge "$TARGET_SECONDS" ]; then
        break
    fi

    sleep "$INTERVAL_SECONDS"
done

END_EPOCH=$(date +%s)
END_SNAPSHOT=$(read_battery_snapshot)
END_PERCENT=${END_SNAPSHOT%%|*}
END_SOURCE=${END_SNAPSHOT#*|}
END_MAH=$(read_mah)
ELAPSED_SECONDS=$((END_EPOCH - START_EPOCH))
# Guard the division below: a near-zero duration ends the loop on the
# first sample with ELAPSED_SECONDS=0.
if [ "$ELAPSED_SECONDS" -le 0 ]; then
    ELAPSED_SECONDS=1
fi

if [ -z "$END_PERCENT" ]; then
    echo "Could not read the ending battery percentage." >&2
    exit 1
fi

DRAIN_RATE=$(awk \
    -v start="$START_PERCENT" \
    -v end="$END_PERCENT" \
    -v seconds="$ELAPSED_SECONDS" \
    'BEGIN { printf "%.2f", (start - end) * 3600 / seconds }')

{
    printf '\nVerification Results\n'
    printf 'Ended: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'Elapsed time: %s seconds (%.2f hours)\n' \
        "$ELAPSED_SECONDS" \
        "$(awk -v seconds="$ELAPSED_SECONDS" 'BEGIN { printf "%.2f", seconds / 3600 }')"
    printf 'Starting battery: %s%% (%s)\n' "$START_PERCENT" "$START_SOURCE"
    printf 'Ending battery: %s%% (%s)\n' "$END_PERCENT" "$END_SOURCE"
    printf 'Starting mAh: %s / %s (CurrentCapacity / MaxCapacity)\n' "${START_MAH%|*}" "${START_MAH#*|}"
    printf 'Ending mAh: %s / %s\n' "${END_MAH%|*}" "${END_MAH#*|}"
    _smah_cur="${START_MAH%|*}"
    _emah_cur="${END_MAH%|*}"
    case "$_smah_cur" in ''|*[!0-9]*) _smah_cur="" ;; esac
    case "$_emah_cur" in ''|*[!0-9]*) _emah_cur="" ;; esac
    if [ -n "$_smah_cur" ] && [ -n "$_emah_cur" ]; then
        printf 'mAh change: %s mAh\n' "$((_emah_cur - _smah_cur))"
    fi
    printf 'Battery change: %s percentage points\n' \
        "$(awk -v start="$START_PERCENT" -v end="$END_PERCENT" 'BEGIN { printf "%+.2f", end - start }')"
    printf 'Measured net drain rate: %s percentage points/hour\n' "$DRAIN_RATE"
    printf '\nFinal pmset -g ps:\n'
    "$PMSET_BIN" -g ps 2>&1
    printf '\nFinal pmset -g batt:\n'
    "$PMSET_BIN" -g batt 2>&1
    printf '\nSample data:\n'
    cat "$SAMPLES_FILE"
} >> "$RESULT_FILE"

if [ "$START_SOURCE" != "Battery" ] || [ "$END_SOURCE" != "Battery" ]; then
    {
        printf '\nValidation warning: the Mac was not on battery power for the full interval.\n'
        printf 'Treat the reported drain rate as a net system change, not battery-only drain.\n'
    } >> "$RESULT_FILE"
fi

cat "$RESULT_FILE"
