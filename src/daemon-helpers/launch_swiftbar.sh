#!/bin/bash
# SwiftBar Launcher — respects .paused state

LOG="$HOME/.battopt-swiftbar/actions.log"

# Clear SwiftBar's DisabledPlugins cache (SwiftBar bug workaround)
defaults delete com.ameba.SwiftBar DisabledPlugins 2>/dev/null

# Launch or ensure SwiftBar
if pgrep -x SwiftBar >/dev/null 2>&1; then
    # Already running — just make sure plugin is enabled
    exit 0
fi

nohup /Applications/SwiftBar.app/Contents/MacOS/SwiftBar > /dev/null 2>&1 &
disown
sleep 3

# Verify
if pgrep -x SwiftBar >/dev/null 2>&1; then
    echo "[$(date '+%H:%M:%S')] launch_swiftbar: SwiftBar launched" >> "$LOG"
    exit 0
else
    echo "[$(date '+%H:%M:%S')] launch_swiftbar: FAILED to launch" >> "$LOG"
    exit 1
fi
