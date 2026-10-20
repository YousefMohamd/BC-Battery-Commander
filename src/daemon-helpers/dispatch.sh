#!/bin/bash
# BattOpt dispatcher.
# This file owns dialogs, input validation, and request submission.
# It does NOT mutate the battery. Every intent becomes a Sentinel request.

BAT="/usr/local/bin/battopt"
DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
LOCK="$DASH/.op.lock"
CFG="$DASH/config"
FORCE="$DASH/force_reset.sh"
LAST_INPUTS="$DASH/.last_inputs"

if [ -f "$DASH/state_guard.sh" ]; then
    source "$DASH/state_guard.sh"
else
    echo "dispatch: state_guard.sh missing, cannot submit requests" >> "$LOG"
    exit 1
fi

LAST_UPPER=85
LAST_LOWER=75
SAILING=true
SAIL_GAP=10
[ -f "$CFG" ] && source "$CFG"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }

raw() { sudo -n "$BAT" status 2>&1; }

get_pct() {
    local ior cur max
    ior=$(ioreg -rn AppleSmartBattery 2>/dev/null)
    cur=$(printf '%s\n' "$ior" | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}' | head -1)
    max=$(printf '%s\n' "$ior" | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}' | head -1)
    if [ -z "$cur" ] || [ -z "$max" ] || [ "$max" -le 0 ]; then
        return 1
    fi
    printf '%s\n' $(( (cur * 100 + max / 2) / max ))
}

get_last_input() {
    local key="$1" fallback="$2" val=""
    [ -f "$LAST_INPUTS" ] && val=$(grep "^${key}=" "$LAST_INPUTS" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -z "$val" ] && echo "$fallback" || echo "$val"
}

atomic_write() {
    local file="$1" content="$2" tmp="${file}.tmp.$$"
    printf '%s' "$content" > "$tmp" && mv "$tmp" "$file"
}

validate_int() {
    local v="$1" min="$2" max="$3"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    [ "$v" -ge "$min" ] && [ "$v" -le "$max" ] || return 1
    return 0
}

save_last_input() {
    local key="$1" val="$2" tmp="${LAST_INPUTS}.tmp"
    [ -z "$key" ] && return 0
    [ -z "$val" ] && return 0
    if [ -f "$LAST_INPUTS" ]; then
        grep -v "^${key}=" "$LAST_INPUTS" 2>/dev/null > "$tmp" || true
    else
        touch "$tmp"
    fi
    echo "${key}=${val}" >> "$tmp"
    mv "$tmp" "$LAST_INPUTS" 2>/dev/null || true
}

acquire() {
    if [ -f "$LOCK" ]; then
        OLD=$(cat "$LOCK" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$OLD" ] && ! kill -0 "$OLD" 2>/dev/null; then
            rm -f "$LOCK"
        else
            AGE=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
            [ "$AGE" -gt 30 ] && rm -f "$LOCK" || { log "lock held"; exit 2; }
        fi
    fi
    echo $$ > "$LOCK"
}

clear_cache() { rm -f "$HOME/.battopt-swiftbar/.status_cache"; }
release() { rm -f "$LOCK"; clear_cache; }

notify() {
    local NOTIFIER="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
    local ICON="$HOME/.battopt-swiftbar/icons/battopt.png"
    [ -x "$NOTIFIER" ] || return 0
    if [ -f "$ICON" ]; then
        nohup "$NOTIFIER" -title "$1" -message "$2" -appIcon "$ICON" -group battopt -timeout 3 >/dev/null 2>&1 &
    else
        nohup "$NOTIFIER" -title "$1" -message "$2" -group battopt -timeout 3 >/dev/null 2>&1 &
    fi
    disown
}

refresh_swiftbar() {
    /usr/bin/open -g "swiftbar://refreshplugin?name=battopt.10s" >/dev/null 2>&1 || true
}

# === INTENT ROUTER (v1.7.0) ===
intent_apply() {
    local kind="$1"; shift
    local rc=0
    case "$kind" in
        limit)
            local upper="$1" lower="$2" mode="$3" gap="$4"
            case "$mode" in
                Hold|hold|false)         mode="Hold" ;;
                Sailing|Sail|sail|true)  mode="Sailing" ;;
                *) log "intent_apply: invalid limit mode '$mode'"; return 1 ;;
            esac
            [ -z "$gap" ] && gap=1
            submit_request "user" "set_limit" "$upper" "$lower" "$mode" "$gap" "-" "0"
            ;;
        hold_current)      submit_request "user" "hold_current"      "-" "-" "-" "-" "-" "0" ;;
        disable_limit)     submit_request "user" "disable_limit"     "-" "-" "-" "-" "-" "0" ;;
        charge_full)       submit_request "user" "charge_full"       "-" "-" "-" "-" "-" "0" ;;
        smart_discharge)   submit_request "user" "smart_discharge"   "$1" "$2" "$3" "$4" "-" "0" ;;
        calibration_start) submit_request "user" "calibration_start" "-" "-" "-" "-" "-" "0" ;;
        calibration_stop)  submit_request "user" "calibration_stop"  "-" "-" "-" "-" "-" "0" ;;
        *) log "intent_apply: unknown intent '$kind'"; return 1 ;;
    esac
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "intent_apply: $kind rejected (rc=$rc)"
        notify "BattOpt" "Request not queued: $kind"
        return "$rc"
    fi
    log "intent_apply: $kind queued"
    notify "BattOpt" "Queued: $kind"
    return 0
}

trap refresh_swiftbar EXIT

case "$1" in
    force_reset) "$FORCE" ;;

    sleep_mode_default)
        acquire
        rm -f "$HOME/.battopt-swiftbar/.sleep_override_ac" "$HOME/.battopt-swiftbar/.sleep_override_lid" "$HOME/.battopt-swiftbar/.sleep_override_batt"
        sudo -n /usr/bin/pmset -a disablesleep 0
        ~/.battopt-swiftbar/power_saver.sh enforce-sleep-policy
        sudo -n /usr/bin/pmset -c sleep 120
        sudo -n /usr/bin/pmset -c displaysleep 20
        sudo -n /usr/bin/pmset -c disksleep 0
        sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null
        atomic_write "$HOME/.battopt-swiftbar/.sleep_mode" "default"
        log "sleep_mode: default"
        notify "BattOpt" "Sleep Mode: Default"
        release
        ;;

    sleep_mode_presentation)
        acquire
        if ! pmset -g batt 2>/dev/null | grep -q "AC Power"; then
            osascript -e 'display dialog "AC required. Presentation Mode only works with the charger connected." buttons {"OK"} with title "Sleep Mode" with icon caution' 2>/dev/null
            release; exit 0
        fi
        rm -f "$HOME/.battopt-swiftbar/.sleep_override_lid" "$HOME/.battopt-swiftbar/.sleep_override_batt"
        touch "$HOME/.battopt-swiftbar/.sleep_override_ac"
        sudo -n /usr/bin/pmset -c sleep 0
        sudo -n /usr/bin/pmset -c displaysleep 0
        sudo -n /usr/bin/pmset -c disksleep 0
        sudo -n /usr/bin/pmset -a disablesleep 0
        atomic_write "$HOME/.battopt-swiftbar/.sleep_mode" "presentation"
        log "sleep_mode: presentation"
        notify "BattOpt" "Sleep Mode: Presentation"
        release
        ;;

    sleep_mode_download)
        acquire
        if ! pmset -g batt 2>/dev/null | grep -q "AC Power"; then
            osascript -e 'display dialog "AC required. Long Tasks only works with the charger connected." buttons {"OK"} with title "Sleep Mode" with icon caution' 2>/dev/null
            release; exit 0
        fi
        BUTTON=$(osascript <<'AS'
try
    display dialog "Enable Long Tasks Mode? Keeps Mac awake with lid closed. Risks: heat buildup. Never put in bag." buttons {"Cancel", "Enable"} default button "Cancel" with title "Sleep Mode" with icon caution
    return button returned of result
on error
    return "CANCELLED"
end try
AS
)
        [ "$BUTTON" != "Enable" ] && { release; exit 0; }
        sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null
        sleep 1
        sudo -n /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1
        sleep 1
        if [ "$(pmset -g | awk '/SleepDisabled/{print $2}')" != "1" ]; then
            notify "BattOpt" "Long Tasks: FAILED to start"
            release; exit 1
        fi
        atomic_write "$HOME/.battopt-swiftbar/.sleep_mode" "download"
        log "sleep_mode: download (disablesleep=1)"
        notify "BattOpt" "Long Tasks: ON - disable when done"
        release
        ;;

    sleep_mode_normal_from_download)
        acquire
        sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null
        atomic_write "$HOME/.battopt-swiftbar/.sleep_mode" "default"
        log "sleep_mode: disablesleep=0"
        notify "BattOpt" "Long Tasks: OFF"
        release
        ;;

    sleep_mode_travel)
        acquire
        BUTTON=$(osascript <<'AS'
try
    display dialog "Enable Travel Mode? Battery hibernates after 4h instead of 30min. Drains ~3% more overnight." buttons {"Cancel", "Enable"} default button "Cancel" with title "Sleep Mode" with icon caution
    return button returned of result
on error
    return "CANCELLED"
end try
AS
)
        [ "$BUTTON" != "Enable" ] && { release; exit 0; }
        rm -f "$HOME/.battopt-swiftbar/.sleep_override_ac" "$HOME/.battopt-swiftbar/.sleep_override_lid"
        touch "$HOME/.battopt-swiftbar/.sleep_override_batt"
        ~/.battopt-swiftbar/power_saver.sh apply-delays travel
        sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null
        atomic_write "$HOME/.battopt-swiftbar/.sleep_mode" "travel"
        log "sleep_mode: travel"
        notify "BattOpt" "Sleep Mode: Travel"
        release
        ;;

    reapply_limit)
        if [ "$SAILING" = "true" ]; then
            intent_apply limit "$LAST_UPPER" "$LAST_LOWER" "Sailing" "$SAIL_GAP"
        else
            intent_apply limit "$LAST_UPPER" "$LAST_LOWER" "Hold" "1"
        fi
        ;;

    kill_charge)    log "kill_charge -> hold_current";        intent_apply hold_current ;;
    kill_discharge) log "kill_discharge -> hold_current";     intent_apply hold_current ;;
    kill_calibrate) log "kill_calibrate -> calibration_stop"; intent_apply calibration_stop ;;

    reset_defaults)
        acquire
        BUTTON=$(osascript <<'AS'
try
    set d to display dialog "Reset all BattOpt settings to defaults? Limits 85/80, Sailing ON gap 5, Power Mode Balanced." buttons {"Cancel", "Reset"} default button "Cancel" with title "BattOpt - Reset to Defaults" with icon caution
    return button returned of d
on error
    return "CANCELLED"
end try
AS
)
        [ "$BUTTON" != "Reset" ] && { release; exit 0; }
        cat > "$CFG" <<'CFGEOF'
LAST_UPPER=85
LAST_LOWER=80
SAILING=true
SAIL_GAP=5
CFGEOF
        rm -f "$HOME/.battopt-swiftbar/.last_inputs" "$HOME/.battopt-swiftbar/.sd_watch" "$HOME/.battopt-swiftbar/.daemon_fail_count"
        ~/.battopt-swiftbar/power_mode.sh balanced >> "$LOG" 2>&1
        log "reset_defaults: 85/80, Sailing ON, gap 5"
        release
        intent_apply limit 85 80 "Sailing" 5
        ;;

    stop_now)          intent_apply hold_current ;;
    remove_limit_hold) intent_apply hold_current ;;

    disable_limit)
        acquire; log "disable all"; release
        intent_apply disable_limit
        ;;

    charge_full)
        acquire; log "charge_full: START"; release
        intent_apply charge_full
        ;;

    smart_discharge)
        acquire
        CUR=$(get_pct); [ -z "$CUR" ] && { release; exit 1; }
        LAST_TARGET=$(get_last_input SD_TARGET 75)
        if [ "$LAST_TARGET" -ge "$CUR" ]; then
            DEFAULT_TARGET=$((CUR - 5)); [ "$DEFAULT_TARGET" -lt 20 ] && DEFAULT_TARGET=20
        else
            DEFAULT_TARGET="$LAST_TARGET"
        fi
        T=$(osascript <<AS
try
    set d to display dialog "Smart Discharge - Target\n\nCurrent: ${CUR}%\nTarget must be LOWER than ${CUR}%\nTarget (20-90):" default answer "${DEFAULT_TARGET}" buttons {"Cancel", "Next"} default button "Next" with title "BattOpt"
    return text returned of d
on error
    return "CANCELLED"
end try
AS
)
        [ "$T" = "CANCELLED" ] && { release; exit 0; }
        validate_int "$T" 20 90 || { notify "BattOpt" "Invalid target (20-90)"; release; exit 0; }
        save_last_input SD_TARGET "$T"
        [ "$T" -ge "$CUR" ] && { notify "BattOpt" "Target ${T}% must be < current ${CUR}%"; release; exit 0; }
        MODE=$(osascript <<AS
try
    set d to display dialog "Smart Discharge - Mode\n\nAfter reaching ${T}%:\nHold = freeze at ${T}%\nSail = oscillate with gap" buttons {"Cancel", "Hold", "Sail"} default button "Sail" with title "BattOpt"
    return button returned of d
on error
    return "CANCELLED"
end try
AS
)
        [ "$MODE" = "CANCELLED" ] && { release; exit 0; }
        save_last_input SD_MODE "$MODE"
        if [ "$MODE" = "Sail" ]; then
            G=$(osascript <<AS
try
    set opts to {"5", "10", "15", "30"}
    set sel to choose from list opts with prompt "Sail gap in %:" default items {"10"} with title "BattOpt"
    if sel is false then
        return "CANCELLED"
    else
        return item 1 of sel
    end if
on error
    return "CANCELLED"
end try
AS
)
            [ "$G" = "CANCELLED" ] && { release; exit 0; }
            LOW=$((T - G)); [ $LOW -lt 20 ] && LOW=20
        else
            LOW=$((T - 1)); [ $LOW -lt 20 ] && LOW=20
            G=0
        fi
        release
        intent_apply smart_discharge "$T" "$LOW" "$MODE" "$G"
        ;;

    limit_custom)
        acquire
        CUR=$(get_pct)
        DEF=$(get_last_input LIMIT_CUSTOM "")
        [ -z "$DEF" ] && DEF="${LAST_UPPER}/${LAST_LOWER}"
        R=$(osascript <<AS
try
    set d to display dialog "Charge Limit\n\nCurrent battery: ${CUR}%\nFormat: 85/75 (upper/lower)\nLast saved: ${DEF}" default answer "$DEF" buttons {"Cancel", "OK"} default button "OK" with title "BattOpt - Charge Limit"
    return text returned of d
on error
    return "CANCELLED"
end try
AS
)
        [ "$R" = "CANCELLED" ] && { release; exit 0; }
        U=$(echo "$R" | cut -d'/' -f1 | tr -d ' ')
        L=$(echo "$R" | cut -d'/' -f2 | tr -d ' ')
        { [ -z "$U" ] || [ -z "$L" ]; } && { notify "BattOpt" "Empty input"; release; exit 0; }
        validate_int "$U" 50 100 || { notify "BattOpt" "Upper 50-100"; release; exit 0; }
        validate_int "$L" 20 99  || { notify "BattOpt" "Lower 20-99";  release; exit 0; }
        [ "$L" -ge "$U" ] && { notify "BattOpt" "Lower < upper"; release; exit 0; }
        MODE=$(osascript <<AS
try
    set d to display dialog "After reaching ${U}%:\nHold = freeze\nSailing = oscillate" buttons {"Cancel","Hold","Sailing"} default button "Sailing" with title "BattOpt"
    return button returned of d
on error
    return "CANCELLED"
end try
AS
)
        [ "$MODE" = "CANCELLED" ] && { release; exit 0; }
        if [ "$MODE" = "Sailing" ]; then
            GSEL=$(osascript <<AS
try
    set opts to {"5","10","15","30"}
    set sel to choose from list opts with prompt "Sail gap in %:" default items {"10"} with title "BattOpt"
    if sel is false then
        return "CANCELLED"
    else
        return item 1 of sel
    end if
on error
    return "CANCELLED"
end try
AS
)
            [ "$GSEL" = "CANCELLED" ] && { release; exit 0; }
            validate_int "$GSEL" 5 30 || { notify "BattOpt" "Invalid gap"; release; exit 0; }
            GAP="$GSEL"
            L=$((U - GAP)); [ "$L" -lt 20 ] && L=20
        else
            MODE="Hold"; GAP=1; L=$((U - 1)); [ "$L" -lt 20 ] && L=20
        fi
        save_last_input LIMIT_CUSTOM "$U/$L"
        release
        intent_apply limit "$U" "$L" "$MODE" "$GAP"
        ;;

    sail_on)  intent_apply limit "$LAST_UPPER" "$LAST_LOWER" "Sailing" "$SAIL_GAP" ;;
    sail_off) intent_apply limit "$LAST_UPPER" "$LAST_LOWER" "Hold" "1" ;;

    sail_gap_set)
        G="$2"
        if [ "$G" = "custom" ] || [ -z "$G" ]; then
            acquire
            G=$(osascript <<AS
try
    set d to display dialog "Gap (5-30):" default answer "$(get_last_input GAP_CUSTOM 10)" buttons {"Cancel", "OK"} default button "OK" with title "BattOpt"
    return text returned of d
on error
    return "CANCELLED"
end try
AS
)
            [ "$G" = "CANCELLED" ] && { release; exit 0; }
            validate_int "$G" 5 30 || { notify "BattOpt" "Invalid gap"; release; exit 0; }
            save_last_input GAP_CUSTOM "$G"
            release
        fi
        validate_int "$G" 5 30 || { notify "BattOpt" "Invalid gap"; exit 0; }
        intent_apply limit "$LAST_UPPER" "$LAST_LOWER" "Sailing" "$G"
        ;;

    calibrate) acquire; log "calibrate";  release; intent_apply calibration_start ;;
    cal_stop)  acquire; log "cal_stop";   release; intent_apply calibration_stop ;;

    sched_on)  log "sched_on";  sudo -n "$BAT" schedule enable  >> "$LOG" 2>&1 ;;
    sched_off) log "sched_off"; sudo -n "$BAT" schedule disable >> "$LOG" 2>&1 ;;
    clam0) sudo -n "$BAT" clamshell 0 >> "$LOG" 2>&1 ;;
    clam1) sudo -n "$BAT" clamshell 1 >> "$LOG" 2>&1 ;;
    clam2) sudo -n "$BAT" clamshell 2 >> "$LOG" 2>&1 ;;

    shutdown)
        acquire
        CONFIRM=$(osascript <<'AS'
try
    set d to display dialog "Shut Down BattOpt?\n\nStops all agents, releases limit, removes menu icon." buttons {"Cancel", "Shut Down"} default button "Shut Down" with icon caution with title "BattOpt - Shutdown"
    return button returned of d
on error
    return "CANCELLED"
end try
AS
)
        [ "$CONFIRM" != "Shut Down" ] && { release; exit 0; }
        log "shutdown: START"
        START_TS=$(date +%s)
        if [ -f "$HOME/.battopt-swiftbar/.pre_charge_full_config" ]; then
            cp "$HOME/.battopt-swiftbar/.pre_charge_full_config" "$HOME/.battopt-swiftbar/.last_session_config"
        elif [ -f "$CFG" ]; then
            cp "$CFG" "$HOME/.battopt-swiftbar/.last_session_config"
        fi
        touch "$HOME/.battopt-swiftbar/.user_shutdown"
        sleep 2
        pkill -f "/Applications/BattOpt.app" 2>/dev/null || true
        osascript -e 'tell application "System Events" to try' -e 'delete login item "BattOpt"' -e 'end try' 2>/dev/null || true
        pkill -9 -f "force_reset" 2>/dev/null || true
        intent_apply disable_limit
        RELEASED=no
        for i in $(seq 1 10); do
            sleep 1
            NCR_NOW=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -oE '"NotChargingReason"=[0-9]+' | grep -oE '[0-9]+' | head -1)
            [ "$NCR_NOW" != "14" ] && { RELEASED=yes; log "shutdown: limit released after ${i}s"; break; }
        done
        [ "$RELEASED" = "no" ] && log "shutdown: WARN limit still enforced"
        for plist in "$HOME/Library/LaunchAgents/"com.battopt.*.plist; do
            [ -f "$plist" ] || continue
            launchctl unload -w "$plist" 2>/dev/null
        done
        pkill -9 -f "guardian" 2>/dev/null || true
        pkill -9 -f "enforce_watchdog" 2>/dev/null || true
        pkill -9 -f "sd_watcher" 2>/dev/null || true
        sudo -n launchctl bootout system/com.buddha-path.BattOpt.daemon 2>/dev/null || true
        sudo -n launchctl unload -w /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist 2>/dev/null || true
        sudo -n launchctl disable system/com.buddha-path.BattOpt.daemon 2>/dev/null || true
        sleep 2
        sudo -n pkill -9 -f "Application Support/battopt/battopt daemon" 2>/dev/null || true
        sudo -n rm -f "/Library/Application Support/battopt/battopt.sock" 2>/dev/null || true
        sudo -n launchctl bootout system/com.battopt.powerwatch 2>/dev/null || true
        sudo -n /usr/local/bin/battopt-powerwatch-stop 2>/dev/null || true
        sudo -n launchctl unload -w /Library/LaunchDaemons/com.battopt.powerwatch.plist 2>/dev/null || true
        sudo -n pkill -9 -f "battopt-swiftbar/powerwatch" 2>/dev/null || true
        for _sf in .session .sentinel_heartbeat .active_token .active_mode .desired_state .sequence \
                   .sd_session .sd_watch .hold_override .hold_token .pre_hold_config \
                   .armed_for_sleep .status_cache .enforce_hb .enforce_state .ac_state .ncr_state \
                   .sleep_prediction .current_power_mode .sleep_mode .sleep_profile .temp_alert_state; do
            rm -f "$HOME/.battopt-swiftbar/$_sf" 2>/dev/null
        done
        rmdir "$HOME/.battopt-swiftbar/.state_guard.lock" 2>/dev/null || true
        rm -f "$HOME/.battopt-swiftbar/.op.lock" "$HOME/.battopt-swiftbar/.launch.lock" 2>/dev/null
        mkdir -p "$HOME/.battopt-swiftbar/disabled"
        for pf in "$HOME/SwiftBar/"battopt.*.sh; do
            [ -f "$pf" ] || continue
            mv "$pf" "$HOME/.battopt-swiftbar/disabled/" 2>/dev/null
        done
        killall SwiftBar 2>/dev/null || true
        END_TS=$(date +%s)
        log "shutdown: COMPLETE in $((END_TS-START_TS))s"
        notify "BattOpt" "Shut down. Open BattOpt.app to restore."
        release
        ;;

    resume)
        acquire
        log "resume requested"
        mkdir -p "$HOME/SwiftBar"
        if [ -f "$HOME/.battopt-swiftbar/disabled/battopt.10s.sh" ]; then
            mv "$HOME/.battopt-swiftbar/disabled/battopt.10s.sh" "$HOME/SwiftBar/"
            chmod +x "$HOME/SwiftBar/battopt.10s.sh"
        fi
        rm -f "$HOME/.battopt-swiftbar/.disabled" "$HOME/.battopt-swiftbar/.paused" "$HOME/.battopt-swiftbar/.user_shutdown" 2>/dev/null
        osascript -e 'tell application "System Events" to try' -e 'make login item at end with properties {path:"/Applications/BattOpt.app", hidden:true}' -e 'end try' 2>/dev/null || true
        sudo -n /usr/local/bin/battopt-daemon-start 2>/dev/null
        sleep 3
        sudo -n /usr/local/bin/battopt-powerwatch-start 2>/dev/null
        sleep 1
        for plist in "$HOME/Library/LaunchAgents/"com.battopt.*.plist; do
            [ -f "$plist" ] || continue
            launchctl load -w "$plist" 2>/dev/null
        done
        source "$DASH/config" 2>/dev/null
        if [ "$SAILING" = "true" ]; then
            intent_apply limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" "Sailing" "${SAIL_GAP:-10}"
        else
            intent_apply limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" "Hold" "1"
        fi
        pgrep -x SwiftBar >/dev/null 2>&1 || nohup /Applications/SwiftBar.app/Contents/MacOS/SwiftBar >/dev/null 2>&1 &
        notify "BattOpt" "Restored"
        release
        ;;

    restore) ~/.battopt-swiftbar/dispatch.sh resume ;;

    details)
        SNAP=$(raw)
        SESSION=$(cat "$HOME/.battopt-swiftbar/.session" 2>/dev/null)
        osascript <<A
 display dialog "=== BattOpt ===\n\n${SNAP}\n\nSession: ${SESSION:-none}" buttons {"OK"} default button "OK" with title "BattOpt Details" with icon note
A
        ;;

    about)
        LOGO="$HOME/.battopt-swiftbar/icons/battopt.png"
        if [ -f "$LOGO" ]; then
            osascript - "$LOGO" <<'A'
on run argv
    display dialog "BattOpt Control Center v1.7.0" buttons {"OK"} default button "OK" with title "About" with icon (POSIX file (item 1 of argv))
end run
A
        else
            osascript -e 'display dialog "BattOpt Control Center v1.7.0" buttons {"OK"} default button "OK" with title "About"'
        fi
        ;;

    open_actions_log) open "$LOG" ;;

    login_toggle)
        acquire
        STATE=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -c "BattOpt" || true)
        STATE=${STATE:-0}; case "$STATE" in ''|*[!0-9]*) STATE=0;; esac
        if [ "$STATE" -gt 0 ]; then
            osascript -e 'tell application "System Events" to try' -e 'delete login item "BattOpt"' -e 'end try'
            notify "BattOpt" "Removed from Login Items"
        else
            osascript -e 'tell application "System Events" to try' -e 'delete login item "BattOpt"' -e 'end try' -e 'make login item at end with properties {path:"/Applications/BattOpt.app", hidden:true}'
            notify "BattOpt" "Added to Login Items"
        fi
        release
        ;;

    open_app) open "/Applications/BattOpt.app"; notify "BattOpt" "Opening BattOpt Control Center" ;;

    sleep_report)
        acquire
        REPORT="/tmp/battopt_sleep_report_$(date +%Y%m%d_%H%M).txt"
        {
            echo "BattOpt Sleep & Battery Report - $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
            echo "--- BATTERY ---"
            sudo -n "$BAT" status 2>&1 | tail -n +2
            echo ""
            echo "--- SESSION ---"
            cat "$HOME/.battopt-swiftbar/.session" 2>/dev/null || echo "none"
            echo ""
            echo "--- POWER SETTINGS ---"
            pmset -g | grep -E "womp|powernap|tcpkeepalive|standbydelay|hibernatemode|sleep "
            echo ""
            echo "--- WAKE EVENTS (last 30) ---"
            pmset -g log | grep -E "Wake from|DarkWake" | tail -30
        } > "$REPORT" 2>&1
        log "sleep_report: $REPORT"
        open -e "$REPORT"
        release
        ;;

    sleep_report_save)
        acquire
        DIR="$HOME/.battopt-swiftbar/reports"
        mkdir -p "$DIR"
        REPORT="$DIR/report_$(date +%Y%m%d_%H%M).txt"
        {
            echo "BattOpt Report - $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
            sudo -n "$BAT" status 2>&1 | tail -n +2
            echo ""
            cat "$HOME/.battopt-swiftbar/.session" 2>/dev/null || echo "none"
            echo ""
            pmset -g | grep -E "womp|powernap|tcpkeepalive|standbydelay|hibernatemode|sleep "
        } > "$REPORT" 2>&1
        log "report saved: $REPORT"
        notify "BattOpt" "Report saved: $(basename "$REPORT")"
        release
        ;;

    open_reports) open "$HOME/.battopt-swiftbar/reports/" 2>/dev/null || notify "BattOpt" "No reports yet" ;;

    power_saver_on)  acquire; log "power_saver: on";  ~/.battopt-swiftbar/power_saver.sh on;  notify "BattOpt" "Power Saver ON";  release ;;
    power_saver_off) acquire; log "power_saver: off"; ~/.battopt-swiftbar/power_saver.sh off; notify "BattOpt" "Power Saver OFF"; release ;;

    power_saver_report)
        acquire
        PSAVER_STATE=$([ -f "$HOME/.battopt-swiftbar/.power_saver" ] && echo "ENABLED" || echo "DISABLED")
        PCT=$(sudo -n "$BAT" status 2>/dev/null | grep -oE "Capacity [0-9]+" | grep -oE "[0-9]+")
        HEALTH=$(sudo -n "$BAT" status 2>/dev/null | grep -oE "Health [0-9.]+" | grep -oE "[0-9.]+")
        WAKE_24H=$(pmset -g log 2>/dev/null | grep -cE "Wake from|DarkWake")
        RESULT=$(osascript <<AS
display dialog "Power Saver: ${PSAVER_STATE}\nBattery: ${PCT}%\nHealth: ${HEALTH}%\nWakes: ${WAKE_24H}" buttons {"Close", "Save Report"} default button "Close" with title "BattOpt"
AS
)
        [ -n "$RESULT" ] && echo "$RESULT" | grep -q "Save" && ~/.battopt-swiftbar/dispatch.sh sleep_report_save
        release
        ;;

    auto_cleanup_toggle)
        acquire
        AUTO_FLAG="$HOME/.battopt-swiftbar/.auto_cleanup"
        if [ -f "$AUTO_FLAG" ]; then
            rm -f "$AUTO_FLAG"; log "auto_cleanup: OFF"; notify "BattOpt" "Auto Cleanup disabled"
        else
            touch "$AUTO_FLAG"; log "auto_cleanup: ON"; notify "BattOpt" "Auto Cleanup enabled"
        fi
        release
        ;;

    pre_sleep_now)  acquire; ~/.battopt-swiftbar/pre_sleep_cleanup.sh;  notify "BattOpt" "Pre-Sleep applied"; release ;;
    post_wake_now)  acquire; ~/.battopt-swiftbar/post_wake_restore.sh; rm -f "$HOME/.battopt-swiftbar/.pre_sleep_done"; notify "BattOpt" "Services restored"; release ;;
    arm_sleep)      acquire; ~/.battopt-swiftbar/arm_sleep.sh; release ;;
    disarm_sleep)   acquire; ~/.battopt-swiftbar/post_wake_restore.sh; notify "BattOpt" "Sleep disarmed"; release ;;

    logs_ai_bundle)
        acquire
        DIR="$HOME/.battopt-swiftbar/reports/ai_diagnostic"
        mkdir -p "$DIR"
        BUNDLE="$DIR/bundle_$(date +%Y%m%d_%H%M%S).md"
        {
            echo "# BattOpt AI Diagnostic Bundle"
            echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
            echo "## System"; echo '```'; sw_vers; uname -a; uptime; echo '```'
            echo ""
            echo "## Battery"; echo '```'; sudo -n "$BAT" status 2>&1; echo '```'
            echo ""
            echo "## Session"; echo '```'; cat "$HOME/.battopt-swiftbar/.session" 2>/dev/null || echo "none"; echo ""; cat "$HOME/.battopt-swiftbar/.sentinel_heartbeat" 2>/dev/null || echo "no heartbeat"; echo '```'
            echo ""
            echo "## pmset"; echo '```'; pmset -g | grep -E "hibernatemode|standbydelay|autopoweroff|powernap|womp|tcpkeepalive|displaysleep|^ sleep"; echo '```'
            echo ""
            echo "## LaunchAgents"; echo '```'; launchctl list | grep battopt 2>&1; echo '```'
            echo ""
            echo "## Recent Actions (100)"; echo '```'; tail -100 "$HOME/.battopt-swiftbar/actions.log" 2>/dev/null; echo '```'
        } > "$BUNDLE"
        log "logs_ai_bundle: $BUNDLE"
        notify "BattOpt" "AI Bundle ready"
        open -R "$BUNDLE"
        release
        ;;

    logs_actions) open -e "$HOME/.battopt-swiftbar/actions.log" ;;
    logs_sailing) open -e "$HOME/.battopt-swiftbar/.sailing_history" ;;
    logs_arm)     open -e "$HOME/.battopt-swiftbar/.arm_log" ;;
    logs_daemon)  open "$HOME/Library/Logs/battopt" 2>/dev/null || open "/Library/Logs/battopt" ;;
    logs_reports) open "$HOME/.battopt-swiftbar/reports" ;;

    power_mode_fast)     acquire; ~/.battopt-swiftbar/power_mode.sh fast;     notify "BattOpt" "Power Mode: Fast";     release ;;
    power_mode_balanced) acquire; ~/.battopt-swiftbar/power_mode.sh balanced; notify "BattOpt" "Power Mode: Balanced"; release ;;
    power_mode_awake)    acquire; ~/.battopt-swiftbar/power_mode.sh awake;    notify "BattOpt" "Power Mode: Awake";    release ;;
    power_mode_deep)     acquire; ~/.battopt-swiftbar/power_mode.sh deep;     notify "BattOpt" "Power Mode: Deep";     release ;;

    power_mode_custom)
        acquire
        S=$(osascript <<AS
try
    set d to display dialog "Sleep timer (minutes, 0=never):" default answer "18" buttons {"Cancel", "Next"} default button "Next" with title "Power Mode"
    return text returned of d
on error
    return "CANCELLED"
end try
AS
)
        [ "$S" = "CANCELLED" ] && { release; exit 0; }
        SD=$(osascript <<AS
try
    set d to display dialog "Standby delay (seconds):" default answer "900" buttons {"Cancel", "OK"} default button "OK" with title "Power Mode"
    return text returned of d
on error
    return "CANCELLED"
end try
AS
)
        [ "$SD" = "CANCELLED" ] && { release; exit 0; }
        ~/.battopt-swiftbar/power_mode.sh custom "$S" "$SD"
        notify "BattOpt" "Custom: sleep=$S, standby=$SD"
        release
        ;;

    project_health)
        acquire
        ~/.battopt-swiftbar/project_health.sh > /dev/null 2>&1
        open -e /tmp/battopt_health_latest.txt 2>/dev/null
        release
        ;;

    conflict_check)
        acquire
        ~/.battopt-swiftbar/conflict_check.sh > /tmp/battopt_conflicts_latest.txt 2>&1
        open -e /tmp/battopt_conflicts_latest.txt
        release
        ;;

    predictive)      acquire; ~/.battopt-swiftbar/predictive.sh;      notify "BattOpt" "Predictive done"; release ;;
    process_monitor) acquire; ~/.battopt-swiftbar/process_monitor.sh; notify "BattOpt" "Process monitor done"; release ;;

    *) log "dispatch: unknown action '$1'" ;;
esac
