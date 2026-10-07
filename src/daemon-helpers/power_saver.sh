#!/bin/bash
# BattOpt Power Saver — optimizes macOS for deep sleep
# Reduces battery drain during Sleep by ~60-70%

LOG="$HOME/.battopt-swiftbar/actions.log"
FLAG="$HOME/.battopt-swiftbar/.power_saver"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }

case "$1" in
    on)
        log "power_saver: ON"
        # Disable wake sources
        /usr/bin/sudo /usr/bin/pmset -a powernap 0       # Prevent Power Nap wakeups
        /usr/bin/sudo /usr/bin/pmset -a womp 0           # No wake-on-magic-packet
        /usr/bin/sudo /usr/bin/pmset -a tcpkeepalive 0   # No TCP keep-alive during sleep
        /usr/bin/sudo /usr/bin/pmset -a acwake 0         # No wake on AC change
        /usr/bin/sudo /usr/bin/pmset -a lidwake 1        # Wake only on lid open
        # Faster transition to hibernate
        /usr/bin/sudo /usr/bin/pmset -a standbydelay 1800
        /usr/bin/sudo /usr/bin/pmset -a standbydelayhigh 1800
        /usr/bin/sudo /usr/bin/pmset -a standbydelaylow 1800
        /usr/bin/sudo /usr/bin/pmset -a standby 1
        # Disk sleep (silences warnings)
        /usr/bin/sudo /usr/bin/pmset -a disksleep 10
        # Cancel scheduled system wakes (RTC/Maintenance)
        /usr/bin/sudo /usr/bin/pmset schedule cancelall 2>/dev/null
        echo "ENABLED" > "$FLAG"
        echo "Power Saver: ENABLED"
        ;;
    off)
        log "power_saver: OFF"
        /usr/bin/sudo /usr/bin/pmset -a powernap 1
        /usr/bin/sudo /usr/bin/pmset -a womp 1
        /usr/bin/sudo /usr/bin/pmset -a tcpkeepalive 1
        /usr/bin/sudo /usr/bin/pmset -a acwake 1
        /usr/bin/sudo /usr/bin/pmset -a lidwake 1
        /usr/bin/sudo /usr/bin/pmset -a standbydelay 4200
        /usr/bin/sudo /usr/bin/pmset -a standbydelayhigh 4200
        /usr/bin/sudo /usr/bin/pmset -a standbydelaylow 4200
        rm -f "$FLAG"
        echo "Power Saver: DISABLED"
        ;;
    status)
        if [ -f "$FLAG" ]; then echo "ENABLED"; else echo "DISABLED"; fi
        ;;
esac
