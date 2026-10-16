#!/bin/bash
# BattOpt Power Saver — optimizes macOS for deep sleep
# Reduces battery drain during Sleep by ~60-70%

LOG="$HOME/.battopt-swiftbar/actions.log"
FLAG="$HOME/.battopt-swiftbar/.power_saver"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }

apply_delays() {
    local profile="$1"
    local high=3600 low=3600 auto=3600 legacy=3600

    case "$profile" in
        long_battery|long_ac)
            high=3600
            low=3600
            auto=3600
            legacy=3600
            ;;
        travel|download)
            high=14400
            low=14400
            auto=0
            legacy=14400
            ;;
        active_battery|active_ac|default|"")
            high=1800
            low=1800
            auto=1800
            legacy=1800
            ;;
        *)
            log "apply_delays: unknown profile '$profile'; using defaults"
            ;;
    esac

    sudo -n /usr/bin/pmset -a standbydelayhigh "$high"
    sudo -n /usr/bin/pmset -a standbydelaylow "$low"
    sudo -n /usr/bin/pmset -a autopoweroffdelay "$auto"
    sudo -n /usr/bin/pmset -a standbydelay "$legacy"
}

enforce_sleep_policy() {
    apply_delays default
}

case "$1" in
    apply-delays)
        apply_delays "$2"
        ;;
    enforce-sleep-policy)
        enforce_sleep_policy
        ;;
    on)
        [ -f "$HOME/.battopt-swiftbar/.user_shutdown" ] && exit 0
        log "power_saver: ON"
        # ARCH_CHECK
        ARCH=$(uname -m)
        # Disable wake sources
        sudo -n /usr/bin/pmset -a powernap 0       # Prevent Power Nap wakeups
        sudo -n /usr/bin/pmset -a womp 0           # No wake-on-magic-packet
        sudo -n /usr/bin/pmset -a tcpkeepalive 0   # No TCP keep-alive during sleep
        sudo -n /usr/bin/pmset -a acwake 0         # No wake on AC change
        sudo -n /usr/bin/pmset -a lidwake 1        # Wake only on lid open
        enforce_sleep_policy
        sudo -n /usr/bin/pmset -a standby 1
        # Disk sleep (silences warnings)
        sudo -n /usr/bin/pmset -a disksleep 10
        # Cancel scheduled system wakes (RTC/Maintenance)
        sudo -n /usr/bin/pmset schedule cancelall 2>/dev/null
        # Deep hibernate (RAM → Disk)
        # Only for Intel Macs
        if [ "$ARCH" = "x86_64" ]; then
            sudo -n /usr/bin/pmset -a hibernatemode 25
        fi
        sudo -n /usr/bin/pmset -a autopoweroff 1
        printf "ENABLED" > "$FLAG.tmp" && mv "$FLAG.tmp" "$FLAG"
        echo "Power Saver: ENABLED"
        ;;
    off)
        [ -f "$HOME/.battopt-swiftbar/.user_shutdown" ] && exit 0
        log "power_saver: OFF"
        sudo -n /usr/bin/pmset -a powernap 1
        sudo -n /usr/bin/pmset -a womp 1
        sudo -n /usr/bin/pmset -a tcpkeepalive 1
        sudo -n /usr/bin/pmset -a acwake 1
        sudo -n /usr/bin/pmset -a lidwake 1
        enforce_sleep_policy
        sudo -n /usr/bin/pmset -a hibernatemode 3
        sudo -n /usr/bin/pmset -a autopoweroff 0
        sudo -n /usr/bin/pmset -a standby 0
        rm -f "$FLAG"
        echo "Power Saver: DISABLED"
        ;;
    status)
        if [ -f "$FLAG" ]; then echo "ENABLED"; else echo "DISABLED"; fi
        ;;
esac
