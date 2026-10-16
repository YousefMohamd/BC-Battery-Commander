#!/bin/bash
# BattOpt Power Saver — optimizes macOS for deep sleep
# Reduces battery drain during Sleep by ~60-70%

LOG="$HOME/.battopt-swiftbar/actions.log"
FLAG="$HOME/.battopt-swiftbar/.power_saver"
PMSET_BIN="${PMSET_BIN:-/usr/bin/pmset}"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }

apply_delays() {
    local profile="${1:-default}"
    local battery_high battery_low battery_auto
    local ac_high ac_low ac_auto ac_sleep

    case "$profile" in
        default)
            battery_high=2700
            battery_low=2700
            battery_auto=1800
            ac_high=3600
            ac_low=3600
            ac_auto=3600
            ac_sleep=90
            ;;
        long)
            battery_high=3600
            battery_low=3600
            battery_auto=1800
            ac_high=7200
            ac_low=7200
            ac_auto=3600
            ac_sleep=90
            ;;
        travel)
            battery_high=3600
            battery_low=3600
            battery_auto=1800
            ac_high=10800
            ac_low=10800
            ac_auto=3600
            ac_sleep=90
            ;;
        *)
            profile=default
            battery_high=2700
            battery_low=2700
            battery_auto=1800
            ac_high=3600
            ac_low=3600
            ac_auto=3600
            ac_sleep=90
            ;;
    esac

    sudo -n "$PMSET_BIN" -b standbydelayhigh "$battery_high"
    sudo -n "$PMSET_BIN" -b standbydelaylow "$battery_low"
    sudo -n "$PMSET_BIN" -b autopoweroffdelay "$battery_auto"
    sudo -n "$PMSET_BIN" -b standbydelay "$battery_high"

    sudo -n "$PMSET_BIN" -c standbydelayhigh "$ac_high"
    sudo -n "$PMSET_BIN" -c standbydelaylow "$ac_low"
    sudo -n "$PMSET_BIN" -c autopoweroffdelay "$ac_auto"
    sudo -n "$PMSET_BIN" -c standbydelay "$ac_high"
    sudo -n "$PMSET_BIN" -c sleep "$ac_sleep"

    log "apply_delays: profile=$profile battery=$battery_high/$battery_low/$battery_auto ac=$ac_high/$ac_low/$ac_auto sleep=$ac_sleep"
}

enforce_sleep_policy() {
    apply_delays default
}

case "$1" in
    apply-delays)
        apply_delays "${2:-default}"
        ;;
    enforce-sleep-policy)
        enforce_sleep_policy
        ;;
    on)
        [ -f "$HOME/.battopt-swiftbar/.user_shutdown" ] && exit 0
        log "power_saver: ON"
        ARCH=$(uname -m)
        sudo -n "$PMSET_BIN" -a powernap 0
        sudo -n "$PMSET_BIN" -a womp 0
        sudo -n "$PMSET_BIN" -a tcpkeepalive 0
        sudo -n "$PMSET_BIN" -a acwake 0
        sudo -n "$PMSET_BIN" -a lidwake 1
        enforce_sleep_policy
        sudo -n "$PMSET_BIN" -a standby 1
        sudo -n "$PMSET_BIN" -a disksleep 10
        sudo -n "$PMSET_BIN" schedule cancelall 2>/dev/null
        if [ "$ARCH" = "x86_64" ]; then
            sudo -n "$PMSET_BIN" -a hibernatemode 25
        fi
        sudo -n "$PMSET_BIN" -a autopoweroff 1
        printf "ENABLED" > "$FLAG.tmp" && mv "$FLAG.tmp" "$FLAG"
        echo "Power Saver: ENABLED"
        ;;
    off)
        [ -f "$HOME/.battopt-swiftbar/.user_shutdown" ] && exit 0
        log "power_saver: OFF"
        sudo -n "$PMSET_BIN" -a powernap 1
        sudo -n "$PMSET_BIN" -a womp 1
        sudo -n "$PMSET_BIN" -a tcpkeepalive 1
        sudo -n "$PMSET_BIN" -a acwake 1
        sudo -n "$PMSET_BIN" -a lidwake 1
        enforce_sleep_policy
        sudo -n "$PMSET_BIN" -a hibernatemode 3
        sudo -n "$PMSET_BIN" -a autopoweroff 0
        sudo -n "$PMSET_BIN" -a standby 0
        rm -f "$FLAG"
        echo "Power Saver: DISABLED"
        ;;
    status)
        if [ -f "$FLAG" ]; then echo "ENABLED"; else echo "DISABLED"; fi
        ;;
esac
