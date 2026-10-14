#!/bin/bash
HOME="${HOME:-/Users/Yousef}"
[ -f "$HOME/.battopt-swiftbar/.user_shutdown" ] && exit 0

# Local notify — fallback if running standalone
if ! command -v notify >/dev/null 2>&1; then
    notify() {
        local NOTIFIER="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
        local ICON="$HOME/.battopt-swiftbar/icons/battopt.png"
        if [ -x "$NOTIFIER" ]; then
            [ -f "$ICON" ] && nohup "$NOTIFIER" -title "$1" -message "$2" -group battopt -timeout 3 >/dev/null 2>&1 &
        disown
        fi
    }
fi
# Arm Sleep — one-button preparation for sleep
# Kills audio apps, runs cleanup, arms PowerWatch

LOG="$HOME/.battopt-swiftbar/actions.log"
log() { echo "[$(date '+%H:%M:%S')] arm_sleep: $1" >> "$LOG"; }

log "=== ARM SLEEP START ==="

# 1. Kill audio apps completely (not just STOP)
for app in VLC Spotify Music; do
    if pgrep -x "$app" >/dev/null 2>&1; then
        /usr/bin/pkill -x "$app" 2>/dev/null
        log "Killed $app"
        sleep 0.5
    fi
done

# 2. Mute Firefox tabs
if pgrep -x firefox >/dev/null 2>&1; then
    osascript -e 'tell application "Firefox" to activate' 2>/dev/null
    sleep 0.3
    osascript -e 'tell application "System Events" to keystroke "m" using {command down, shift down}' 2>/dev/null
    log "Firefox muted"
fi

# 3. Run pre_sleep_cleanup
~/.battopt-swiftbar/pre_sleep_cleanup.sh 2>/dev/null

# 4. Verify audio contexts are gone
sleep 2
AUDIO=$(pmset -g assertions 2>/dev/null | grep -ci "coreaudiod.*PreventUserIdle")

if [ "$AUDIO" -eq 0 ]; then
    log "Arm complete — no audio contexts"
    notify "BattOpt" "✅ Ready for sleep — close the lid"
else
    log "Arm incomplete — $AUDIO audio contexts remain"
    notify "BattOpt" "⚠ $AUDIO audio contexts still active"
fi

# 5. Record baseline
echo "" >> "$HOME/.battopt-swiftbar/.arm_log"
echo "=== ARMED $(date '+%Y-%m-%d %H:%M') ===" >> "$HOME/.battopt-swiftbar/.arm_log"
echo "Battery: $(pmset -g batt | grep -oE '[0-9]+%' | head -1)" >> "$HOME/.battopt-swiftbar/.arm_log"
echo "Wakes: $(pmset -g log | grep -cE 'Wake from|DarkWake')" >> "$HOME/.battopt-swiftbar/.arm_log"
echo "Audio: $AUDIO" >> "$HOME/.battopt-swiftbar/.arm_log"

touch "$HOME/.battopt-swiftbar/.armed_for_sleep"
log "=== ARM SLEEP END ==="
