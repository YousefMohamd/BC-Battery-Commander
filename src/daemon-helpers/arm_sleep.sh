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
SD_WATCHER="$HOME/.battopt-swiftbar/.sd_watch"
log() { echo "[$(date '+%H:%M:%S')] arm_sleep: $1" >> "$LOG"; }

log "=== ARM SLEEP START ==="

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

# === TASK 2 FIX: Respect active discharge/charge_full ===
ACTIVE_MODE=$(cat "$HOME/.battopt-swiftbar/.active_mode" 2>/dev/null)
case "$ACTIVE_MODE" in
    discharge)
        log "arm_sleep: active discharge detected — preserving (no limit change)"
        # Skip limit change entirely; discharge watcher handles the session
        # Still apply sleep profile (powernap, womp, etc.)
        "$HOME/.battopt-swiftbar/power_saver.sh" apply-delays "$APPLY_PROFILE"
        log "Applied sleep delay profile: $APPLY_PROFILE"
        ;;
    charge_full)
        log "arm_sleep: active charge_full detected — preserving (no limit change)"
        # charge_full watcher is running; do not interrupt
        "$HOME/.battopt-swiftbar/power_saver.sh" apply-delays "$APPLY_PROFILE"
        log "Applied sleep delay profile: $APPLY_PROFILE"
        ;;
    calibration)
        log "arm_sleep: active calibration detected — preserving (no limit change)"
        "$HOME/.battopt-swiftbar/power_saver.sh" apply-delays "$APPLY_PROFILE"
        log "Applied sleep delay profile: $APPLY_PROFILE"
        ;;
    *)
        # Idle — apply HOLD_ON_SLEEP normally

        # === TASK 3A FIX: Stop charge before limit change ===
        # Kill any pending charge processes to prevent SMC release race
        sudo pkill -9 -f "battopt charge " 2>/dev/null || true
        sudo -n /usr/local/bin/battopt charge stop >/dev/null 2>&1 || true
        sleep 1

        # Hold-on-Sleep: optionally force static hold before applying delays
        source "$HOME/.battopt-swiftbar/config" 2>/dev/null || true
        HOLD_ON_SLEEP="${HOLD_ON_SLEEP:-true}"

        if [ "$HOLD_ON_SLEEP" = "true" ] && [ -n "$LAST_UPPER" ]; then
            _LOWER=$((LAST_UPPER - 1))
            [ "$_LOWER" -lt 20 ] && _LOWER=20
            sudo -n /usr/local/bin/battopt limit "$LAST_UPPER" "$_LOWER" >> "$LOG" 2>&1
            log "arm_sleep: HOLD_ON_SLEEP=true → static hold $LAST_UPPER/$_LOWER"
        else
            sudo -n /usr/local/bin/battopt limit "$LAST_UPPER" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
            log "arm_sleep: HOLD_ON_SLEEP=$HOLD_ON_SLEEP → applied $LAST_UPPER/${LAST_LOWER:-80}"
        fi

        # === TASK 3B FIX: Sleep-time overshoot guard ===
        # If battery is already above target, stop charging immediately
        _CUR=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
        _MAXC=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')
        if [ -n "$_CUR" ] && [ -n "$_MAXC" ] && [ "$_MAXC" -gt 0 ]; then
            _PCT=$(( (_CUR * 100 + _MAXC / 2) / _MAXC ))
            if [ "$_PCT" -gt "$LAST_UPPER" ]; then
                log "arm_sleep: overshoot guard — battery $_PCT% > limit $LAST_UPPER%, stopping charge"
                sudo -n /usr/local/bin/battopt charge stop >/dev/null 2>&1 || true
                sudo pkill -9 -f "battopt charge " 2>/dev/null || true
            fi
        fi

        # Apply sleep profile (power_saver.sh sets standby, hibernatemode, etc.)
        "$HOME/.battopt-swiftbar/power_saver.sh" apply-delays "$APPLY_PROFILE"
        log "Applied sleep delay profile: $APPLY_PROFILE"
        ;;
esac

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
