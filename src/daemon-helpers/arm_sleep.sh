#!/bin/bash
if [ -z "$HOME" ]; then echo "ERROR: HOME is unset, refusing to guess user" >&2; exit 1; fi
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
# Prepare warning: sleep on charger below upper risks overshoot (enforcement pauses during sleep)
if [ -f "$HOME/.battopt-swiftbar/config" ]; then
    source "$HOME/.battopt-swiftbar/config" 2>/dev/null
fi
WARN_UPPER="${LAST_UPPER:-85}"
WARN_PCT=$(pmset -g batt 2>/dev/null | grep -oE '[0-9]+%' | head -1 | tr -d '%')
if [ -n "$WARN_PCT" ] && [ "$WARN_PCT" -lt "$WARN_UPPER" ] 2>/dev/null && pmset -g batt 2>/dev/null | grep -q "AC Power"; then
    log "WARNING: sleep on charger risk — Battery ${WARN_PCT}% < limit ${WARN_UPPER}%, charger attached, enforcement pauses during sleep, overshoot possible — unplug or wait for stable hold before sleeping"
    notify "BattOpt" "⚠ Sleep on charger risk: ${WARN_PCT}% < ${WARN_UPPER}%, charger attached — unplug or wait for hold before sleeping"
fi

# Keep the selected sleep policy when preparing to sleep.
SLEEP_PROFILE=$(cat "$HOME/.battopt-swiftbar/.sleep_profile" 2>/dev/null)
SLEEP_MODE=$(cat "$HOME/.battopt-swiftbar/.sleep_mode" 2>/dev/null)
case "$SLEEP_MODE" in
    travel)
        APPLY_PROFILE=travel
        ;;
    download)
        APPLY_PROFILE=long
        ;;
    *)
        case "$SLEEP_PROFILE" in
            active_ac|active_battery)
                APPLY_PROFILE=default
                ;;
            long_ac|long_battery)
                APPLY_PROFILE=long
                ;;
            *)
                APPLY_PROFILE=default
                ;;
        esac
        ;;
esac
if [ -f "$HOME/.battopt-swiftbar/.power_saver" ]; then
    "$HOME/.battopt-swiftbar/power_saver.sh" on
    "$HOME/.battopt-swiftbar/power_saver.sh" apply-delays "$APPLY_PROFILE"
    log "Applied sleep delay profile: $APPLY_PROFILE"
else
    "$HOME/.battopt-swiftbar/power_saver.sh" off
    log "Power Saver disabled; applied conservative sleep settings"
fi

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
