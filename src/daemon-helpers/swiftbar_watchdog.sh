#!/bin/bash
# SwiftBar Watchdog — keeps SwiftBar alive + plugin enabled
# BC version (renamed 2026-11-11): watches battery-commander.10s.sh.
# Was the old battopt watchdog (it wrote to ~/.battopt-swiftbar/ and
# re-created battopt.10s.sh) — rewritten for the BC state dir + plugin.

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
SWIFTBAR_BIN="/Applications/SwiftBar.app/Contents/MacOS/SwiftBar"

[ -f "$DASH/.user_shutdown" ] && exit 0

if ! pgrep -x SwiftBar >/dev/null 2>&1; then
    echo "[$(date '+%H:%M:%S')] watchdog: SwiftBar stopped, relaunching" >> "$LOG"
    if [ -x "$DASH/launch_swiftbar.sh" ]; then
        "$DASH/launch_swiftbar.sh"
    else
        echo "[$(date '+%H:%M:%S')] watchdog: launch_swiftbar.sh missing — cannot relaunch SwiftBar" >> "$LOG"
    fi
else
    # Clean any .bak files that SwiftBar would treat as plugins
    if ls "$HOME/SwiftBar/"*.bak* >/dev/null 2>&1; then
        mkdir -p "$DASH/plugin-backups"
        mv "$HOME/SwiftBar/"*.bak* "$DASH/plugin-backups/" 2>/dev/null
        echo "[$(date '+%H:%M:%S')] watchdog: moved .bak files out of SwiftBar" >> "$LOG"
    fi

    DIS=$(defaults read com.ameba.SwiftBar DisabledPlugins 2>/dev/null |
        grep -c "battery-commander")

    if [ "$DIS" -gt 0 ]; then
        echo "[$(date '+%H:%M:%S')] watchdog: removing battery-commander from DisabledPlugins" \
            >> "$LOG"
        defaults delete com.ameba.SwiftBar DisabledPlugins 2>/dev/null
        touch "$HOME/SwiftBar/battery-commander.10s.sh"
    fi
fi
