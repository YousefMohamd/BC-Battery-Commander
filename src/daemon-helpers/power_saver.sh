#!/bin/bash
# BattOpt Power Saver — optimizes macOS for deep sleep
# Reduces battery drain during Sleep by ~60-70%

LOG="$HOME/.battopt-swiftbar/actions.log"
FLAG="$HOME/.battopt-swiftbar/.power_saver"

[ -f "$HOME/.battopt-swiftbar/.user_shutdown" ] && exit 0

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }

case "$1" in
    on)
        log "power_saver: ON"
        # ARCH_CHECK
        ARCH=$(uname -m)
        # Disable wake sources
        sudo -n /usr/bin/pmset -a powernap 0       # Prevent Power Nap wakeups
        sudo -n /usr/bin/pmset -a womp 0           # No wake-on-magic-packet
        sudo -n /usr/bin/pmset -a tcpkeepalive 0   # No TCP keep-alive during sleep
        sudo -n /usr/bin/pmset -a acwake 0         # No wake on AC change
        sudo -n /usr/bin/pmset -a lidwake 1        # Wake only on lid open
        # Faster transition to hibernate
        sudo -n /usr/bin/pmset -a standbydelay 900
        sudo -n /usr/bin/pmset -a standbydelayhigh 900
        sudo -n /usr/bin/pmset -a standbydelaylow 900
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
        sudo -n /usr/bin/pmset -a autopoweroffdelay 900
        printf "ENABLED" > "$FLAG.tmp" && mv "$FLAG.tmp" "$FLAG"
        echo "Power Saver: ENABLED"
        ;;
    off)
        log "power_saver: OFF"
        sudo -n /usr/bin/pmset -a powernap 1
        sudo -n /usr/bin/pmset -a womp 1
        sudo -n /usr/bin/pmset -a tcpkeepalive 1
        sudo -n /usr/bin/pmset -a acwake 1
        sudo -n /usr/bin/pmset -a lidwake 1
        sudo -n /usr/bin/pmset -a standbydelay 4200
        sudo -n /usr/bin/pmset -a standbydelayhigh 4200
        sudo -n /usr/bin/pmset -a standbydelaylow 4200
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
