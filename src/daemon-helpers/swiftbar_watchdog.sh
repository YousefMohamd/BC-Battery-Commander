#!/bin/bash
# SwiftBar Watchdog — keeps SwiftBar alive + plugin enabled

LOG="$HOME/.battopt-swiftbar/actions.log"
SWIFTBAR_BIN="/Applications/SwiftBar.app/Contents/MacOS/SwiftBar"

[ -f "$HOME/.battopt-swiftbar/.user_shutdown" ] && exit 0

if ! pgrep -x SwiftBar >/dev/null 2>&1; then
    echo "[$(date '+%H:%M:%S')] watchdog: SwiftBar stopped, relaunching" >> "$LOG"
    "$HOME/.battopt-swiftbar/launch_swiftbar.sh"
else
    # Clean any .bak files that SwiftBar would treat as plugins
    if ls "$HOME/SwiftBar/"*.bak* >/dev/null 2>&1; then
        mkdir -p "$HOME/.battopt-swiftbar/plugin-backups"
        mv "$HOME/SwiftBar/"*.bak* "$HOME/.battopt-swiftbar/plugin-backups/" 2>/dev/null
        echo "[$(date '+%H:%M:%S')] watchdog: moved .bak files out of SwiftBar" >> "$LOG"
    fi

    DIS=$(defaults read com.ameba.SwiftBar DisabledPlugins 2>/dev/null |
        grep -c "battopt")

    if [ "$DIS" -gt 0 ]; then
        echo "[$(date '+%H:%M:%S')] watchdog: removing battopt from DisabledPlugins" \
            >> "$LOG"
        defaults delete com.ameba.SwiftBar DisabledPlugins 2>/dev/null
        touch "$HOME/SwiftBar/battopt.10s.sh"
    fi
fi
