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
        conservative)
            battery_high=3600
            battery_low=3600
            battery_auto=3600
            ac_high=3600
            ac_low=3600
            ac_auto=3600
            ac_sleep=30
            ;;
        default)
            battery_high=300
            battery_low=300
            battery_auto=900
            ac_high=300
            ac_low=300
            ac_auto=900
            ac_sleep=20
            ;;
        long)
            battery_high=300
            battery_low=300
            battery_auto=900
            ac_high=300
            ac_low=300
            ac_auto=900
            ac_sleep=20
            ;;
        travel)
            battery_high=300
            battery_low=300
            battery_auto=900
            ac_high=300
            ac_low=300
            ac_auto=900
            ac_sleep=20
            ;;
        *)
            profile=default
            battery_high=300
            battery_low=300
            battery_auto=900
            ac_high=300
            ac_low=300
            ac_auto=900
            ac_sleep=20
            ;;
    esac

    sudo -n "$PMSET_BIN" -b standbydelayhigh "$battery_high"
    sudo -n "$PMSET_BIN" -b standbydelaylow "$battery_low"
    sudo -n "$PMSET_BIN" -b autopoweroffdelay "$battery_auto"
    sudo -n "$PMSET_BIN" -b standbydelay "$battery_high"
    sudo -n "$PMSET_BIN" -b disksleep 10

    sudo -n "$PMSET_BIN" -c standbydelayhigh "$ac_high"
    sudo -n "$PMSET_BIN" -c standbydelaylow "$ac_low"
    sudo -n "$PMSET_BIN" -c autopoweroffdelay "$ac_auto"
    sudo -n "$PMSET_BIN" -c standbydelay "$ac_high"
    sudo -n "$PMSET_BIN" -c sleep "$ac_sleep"
    sudo -n "$PMSET_BIN" -c disksleep 10

    log "apply_delays: profile=$profile battery=$battery_high/$battery_low/$battery_auto ac=$ac_high/$ac_low/$ac_auto sleep=$ac_sleep"
}

enforce_sleep_policy() {
    apply_delays conservative
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
        sudo -n "$PMSET_BIN" -a standbydelay 300
        sudo -n "$PMSET_BIN" -b standbydelayhigh 300
        sudo -n "$PMSET_BIN" -b standbydelaylow 300
        sudo -n "$PMSET_BIN" -c standbydelayhigh 300
        sudo -n "$PMSET_BIN" -c standbydelaylow 300
        sudo -n "$PMSET_BIN" -a sleep 20
        sudo -n "$PMSET_BIN" -b sleep 20
        sudo -n "$PMSET_BIN" -c sleep 20
        sudo -n "$PMSET_BIN" -a disksleep 10
        if [ "$ARCH" = "x86_64" ]; then
            sudo -n "$PMSET_BIN" -a hibernatemode 25
        fi
        sudo -n "$PMSET_BIN" -a autopoweroff 1
        sudo -n "$PMSET_BIN" -a autopoweroffdelay 900
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
        sudo -n "$PMSET_BIN" -a standby 0
        sudo -n "$PMSET_BIN" -a standbydelay 3600
        sudo -n "$PMSET_BIN" -b standbydelayhigh 3600
        sudo -n "$PMSET_BIN" -b standbydelaylow 3600
        sudo -n "$PMSET_BIN" -c standbydelayhigh 3600
        sudo -n "$PMSET_BIN" -c standbydelaylow 3600
        sudo -n "$PMSET_BIN" -a sleep 30
        sudo -n "$PMSET_BIN" -b sleep 30
        sudo -n "$PMSET_BIN" -c sleep 30
        sudo -n "$PMSET_BIN" -a disksleep 10
        sudo -n "$PMSET_BIN" -a hibernatemode 3
        sudo -n "$PMSET_BIN" -a autopoweroff 0
        sudo -n "$PMSET_BIN" -a autopoweroffdelay 3600
        rm -f "$FLAG"
        echo "Power Saver: DISABLED"
        ;;
    status)
        if [ -f "$FLAG" ]; then echo "ENABLED"; else echo "DISABLED"; fi
        ;;
esac
