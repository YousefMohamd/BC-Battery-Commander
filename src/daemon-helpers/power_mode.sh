#!/bin/bash

# Battery Commander power-mode profiles.
# Each profile controls sleep timing and standby behavior through pmset.

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
LOG="$DASH/actions.log"
MODE_FILE="$DASH/.current_power_mode"
PMSET_BIN="${PMSET_BIN:-/usr/bin/pmset}"

mkdir -p "$DASH"

log() {
    printf '[%s] power_mode: %s\n' "$(date '+%H:%M:%S')" "$1" >> "$LOG"
}

fail() {
    log "failed: $1"
    echo "Power Mode: failed"
    exit 1
}

valid_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

apply_setting() {
    local scope="$1"
    local key="$2"
    local value="$3"

    sudo -n "$PMSET_BIN" "$scope" "$key" "$value" >/dev/null 2>&1 || {
        log "could not set ${scope} ${key} ${value}"
        return 1
    }
}

apply_profile() {
    local profile="$1"
    local sleep_minutes standby_seconds hibernate_mode
    local errors=0

    case "$profile" in
        fast)
            sleep_minutes=5
            standby_seconds=300
            hibernate_mode=25
            ;;
        balanced)
            sleep_minutes=18
            standby_seconds=900
            hibernate_mode=3
            ;;
        awake)
            sleep_minutes=0
            standby_seconds=3600
            hibernate_mode=3
            ;;
        deep)
            sleep_minutes=5
            standby_seconds=0
            hibernate_mode=25
            ;;
        custom)
            sleep_minutes="$2"
            standby_seconds="$3"

            valid_int "$sleep_minutes" || fail "sleep timer must be a non-negative integer"
            valid_int "$standby_seconds" || fail "standby delay must be a non-negative integer"

            [ "$sleep_minutes" -le 1440 ] ||
                fail "sleep timer must be between 0 and 1440 minutes"
            [ "$standby_seconds" -le 86400 ] ||
                fail "standby delay must be between 0 and 86400 seconds"

            hibernate_mode=3
            ;;
        *)
            fail "unknown profile: $profile"
            ;;
    esac

    # Keep battery and AC settings aligned. The profile controls when the
    # computer enters sleep and when macOS writes memory to disk.
    apply_setting -a sleep "$sleep_minutes" || errors=1
    apply_setting -a standby 1 || errors=1
    apply_setting -a standbydelayhigh "$standby_seconds" || errors=1
    apply_setting -a standbydelaylow "$standby_seconds" || errors=1
    apply_setting -a standbydelay "$standby_seconds" || errors=1

    # Hibernatemode 25 is supported on Intel Macs. Apple silicon ignores this
    # setting, so a failure here does not invalidate the rest of the profile.
    if [ "$(uname -m)" = "x86_64" ]; then
        apply_setting -a hibernatemode "$hibernate_mode" || errors=1
    fi

    [ "$errors" -eq 0 ] || fail "one or more pmset settings could not be applied"

    printf '%s\n' "$profile" > "$MODE_FILE.tmp.$$" || fail "could not write mode state"
    mv "$MODE_FILE.tmp.$$" "$MODE_FILE" || fail "could not save mode state"

    log "applied profile=$profile sleep=${sleep_minutes}m standby=${standby_seconds}s hibernatemode=${hibernate_mode}"
    echo "Power Mode: $profile"
}

case "${1:-}" in
    fast)
        apply_profile fast
        ;;
    balanced)
        apply_profile balanced
        ;;
    awake)
        apply_profile awake
        ;;
    deep)
        apply_profile deep
        ;;
    custom)
        [ "$#" -eq 3 ] || fail "custom mode requires sleep minutes and standby seconds"
        apply_profile custom "$2" "$3"
        ;;
    status)
        if [ -f "$MODE_FILE" ]; then
            printf '%s\n' "$(cat "$MODE_FILE")"
        else
            echo "balanced"
        fi
        ;;
    *)
        echo "Usage: $0 {fast|balanced|awake|deep|custom <sleep-minutes> <standby-seconds>|status}" >&2
        exit 2
        ;;
esac
