#!/bin/bash
# Measure net battery drain over an overnight interval and capture pmset state.

set -u

DASH="$HOME/.battopt-swiftbar"
OUTPUT_DIR="$DASH/overnight-tests"
DURATION_HOURS="${1:-10}"
INTERVAL_SECONDS="${2:-300}"
PMSET_BIN="${PMSET_BIN:-/usr/bin/pmset}"

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

START_EPOCH=$(date +%s)
START_SNAPSHOT=$(read_battery_snapshot)
START_PERCENT=${START_SNAPSHOT%%|*}
START_SOURCE=${START_SNAPSHOT#*|}

if [ -z "$START_PERCENT" ]; then
    echo "Could not read the starting battery percentage." >&2
    "$PMSET_BIN" -g batt >&2 || true
    exit 1
fi

{
    printf 'BattOpt Overnight Drain Test\n'
    printf 'Started: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'Duration target: %s hours\n' "$DURATION_HOURS"
    printf 'Sampling interval: %s seconds\n' "$INTERVAL_SECONDS"
    printf 'Starting battery: %s%% (%s)\n' "$START_PERCENT" "$START_SOURCE"
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
ELAPSED_SECONDS=$((END_EPOCH - START_EPOCH))

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
