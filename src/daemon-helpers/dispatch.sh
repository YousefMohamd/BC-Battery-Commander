#!/bin/bash
BAT="/usr/local/bin/battopt"
LOG="$HOME/.battopt-swiftbar/actions.log"
LOCK="$HOME/.battopt-swiftbar/.op.lock"
CFG="$HOME/.battopt-swiftbar/config"
FORCE="$HOME/.battopt-swiftbar/force_reset.sh"

LAST_UPPER=85
LAST_LOWER=75
SAILING=true
SAIL_GAP=10
[ -f "$CFG" ] && source "$CFG"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }
raw() { sudo -n "$BAT" status 2>&1; }
get_pct() { raw | grep -oE "Capacity [0-9]+" | grep -oE "[0-9]+"; }
is_charging() { ioreg -rn AppleSmartBattery 2>/dev/null | grep -q '"IsCharging" = Yes'; }

save_cfg() {
    cat > "$CFG" <<EOF
LAST_UPPER=$LAST_UPPER
LAST_LOWER=$LAST_LOWER
SAILING=$SAILING
SAIL_GAP=$SAIL_GAP
EOF
}

kill_clients() { sudo pkill -9 -f "/usr/local/bin/battopt" 2>/dev/null; sleep 1; }
soft_stop() { sudo -n "$BAT" discharge stop >/dev/null 2>&1; sudo -n "$BAT" calibrate stop >/dev/null 2>&1; sleep 0.5; }

# Fast daemon health check — 3 second timeout
_daemon_ok() {
    ( sudo -n "$BAT" status >/dev/null 2>&1 ) &
    local pid=$!
    local count=0
    while [ $count -lt 6 ]; do
        if ! kill -0 $pid 2>/dev/null; then
            wait $pid
            return $?
        fi
        sleep 0.5
        count=$((count + 1))
    done
    kill -9 $pid 2>/dev/null
    return 1
}

# Preflight — called by every action. Guarantees daemon responds.
preflight() {
    # 1. Fast check
    if ! _daemon_ok; then
        log "preflight: daemon slow, restarting"
        sudo -n /usr/local/bin/battopt-daemon-restart >/dev/null 2>&1
        sleep 1
        if ! _daemon_ok; then
            log "preflight: restart failed, force_reset"
            "$FORCE" >/dev/null 2>&1
            sleep 1
        fi
    fi
    # 2. If there's a lingering "ongoing" error, clear it
    local st
    st=$(sudo -n "$BAT" status 2>&1)
    if echo "$st" | grep -qE "Error:.*ongoing"; then
        log "preflight: clearing ongoing state"
        sudo pkill -9 -f "/usr/local/bin/battopt " 2>/dev/null
        sleep 0.5
        sudo -n "$BAT" discharge stop >/dev/null 2>&1
        sudo -n "$BAT" calibrate stop >/dev/null 2>&1
        sleep 0.5
    fi
}

# Run battopt with auto-retry on "ongoing"
run_with_retry() {
    local out
    out=$(sudo -n "$BAT" "$@" 2>&1)
    local rc=$?
    if [ $rc -ne 0 ] && echo "$out" | grep -q "ongoing"; then
        log "run_with_retry: detected ongoing, clearing and retrying"
        sudo pkill -9 -f "/usr/local/bin/battopt " 2>/dev/null
        sudo -n "$BAT" discharge stop >/dev/null 2>&1
        sudo -n "$BAT" calibrate stop >/dev/null 2>&1
        sleep 1
        out=$(sudo -n "$BAT" "$@" 2>&1)
        rc=$?
    fi
    echo "$out"
    return $rc
}
ensure_clean() {
    kill_clients; soft_stop
    if raw | grep -q "ongoing"; then
        log "stuck - force"; "$FORCE" > /dev/null 2>&1
    fi
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
    # SAFETY LAYER: preflight before every action
    preflight
}
release() { rm -f "$LOCK"; }

notify() {
    local title="$1"
    local msg="$2"
    local icon="$HOME/.battopt-swiftbar/icons/battopt.png"

    # Priority 1: /Applications bundle
    local notifier="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
    if [ -x "$notifier" ]; then
        "$notifier" -title "$title" -message "$msg" \
            -appIcon "$icon" -contentImage "$icon" \
            -sound "Ping" -group "battopt" >/dev/null 2>&1 &
        return
    fi

    # Priority 2: MacPorts
    if [ -x /opt/local/bin/terminal-notifier ]; then
        /opt/local/bin/terminal-notifier -title "$title" -message "$msg" \
            -appIcon "$icon" -sound "Ping" -group "battopt" >/dev/null 2>&1 &
        return
    fi

    # Priority 3: osascript
    osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1 &
}

apply_intent() {
    if [ "$SAILING" = "true" ] && [ "$LAST_LOWER" -lt "$LAST_UPPER" ]; then
        log "apply: sailing $LAST_UPPER/$LAST_LOWER"
        run_with_retry limit "$LAST_UPPER" "$LAST_LOWER" >> "$LOG" 2>&1
    else
        local L=$((LAST_UPPER - 1))
        [ $L -lt 20 ] && L=20
        log "apply: hold $LAST_UPPER/$L"
        run_with_retry limit "$LAST_UPPER" "$L" >> "$LOG" 2>&1
    fi
}

hold_at_current() {
    local CUR=$(get_pct); [ -z "$CUR" ] && return 1
    local LOW=$((CUR - 1)); [ $LOW -lt 20 ] && LOW=20
    run_with_retry limit "$CUR" "$LOW" >> "$LOG" 2>&1
    sleep 2
    for i in $(seq 1 8); do
        ! is_charging && { log "held ${i}s"; return 0; }
        sleep 1
    done
    log "15s timeout - force"
    "$FORCE" > /dev/null 2>&1
    sleep 2
    ! is_charging && return 0
    run_with_retry limit "$CUR" "$LOW" >> "$LOG" 2>&1
    sleep 3
    is_charging && return 1
    return 0
}

kill_charge()    { log "kill_charge";    sudo pkill -9 -f "battopt charge " 2>/dev/null; sleep 0.5; }
kill_discharge() { log "kill_discharge"; sudo pkill -9 -f "battopt discharge" 2>/dev/null; sudo -n "$BAT" discharge stop >/dev/null 2>&1; sleep 0.5; }
kill_calibrate() { log "kill_calibrate"; sudo pkill -9 -f "battopt calibrate" 2>/dev/null; sudo -n "$BAT" calibrate stop >/dev/null 2>&1; sleep 0.5; }

case "$1" in
    force_reset) "$FORCE" ;;
    kill_charge)    kill_charge ;;
    kill_discharge) kill_discharge ;;
    kill_calibrate) kill_calibrate ;;

    stop_now)
        acquire; ensure_clean
        hold_at_current
        release ;;

    remove_limit_hold)
        acquire; ensure_clean
        hold_at_current
        release ;;

    disable_limit)
        acquire; ensure_clean
        log "disable all"
        run_with_retry limit disable >> "$LOG" 2>&1
        release ;;

    charge_full)
        acquire; ensure_clean
        run_with_retry limit disable >/dev/null 2>&1
        sleep 1
        nohup sudo -n "$BAT" charge 100 >/dev/null 2>&1 &
        release
        nohup bash -c '
            B="'"$BAT"'"; L="'"$LOG"'"
            for i in $(seq 1 720); do
                sleep 10
                P=$(sudo -n "$B" status 2>/dev/null | grep -oE "Capacity [0-9]+" | grep -oE "[0-9]+")
                if [ -n "$P" ] && [ "$P" -ge 99 ]; then
                    sudo -n "$B" limit 99 98 >/dev/null 2>&1
                    echo "[$(date +%H:%M:%S)] Auto-locked 99/98" >> "$L"
                    break
                fi
            done
        ' >/dev/null 2>&1 &
        ;;

    smart_discharge)
        acquire; ensure_clean
        CUR=$(get_pct); [ -z "$CUR" ] && { release; exit 1; }

        T=$(osascript <<AS
try
    set d to display dialog "Smart Discharge - Target

Current: ${CUR}%

Target battery level (20-90):" default answer "75" buttons {"Cancel", "Next"} default button "Next" with title "BattOpt"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$T" = "__CANCELLED__" ] && { release; exit 0; }
        { [ "$T" -lt 20 ] || [ "$T" -gt 90 ]; } && { release; exit 1; }
        [ "$T" -ge "$CUR" ] && { release; exit 1; }

        MODE=$(osascript <<AS
try
    set d to display dialog "Smart Discharge - Mode

After reaching ${T}%:

Sail = resume charging at (${T} - gap)
Hold = freeze at ${T}% only" buttons {"Cancel", "Hold", "Sail"} default button "Sail" with title "BattOpt"
    return button returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$MODE" = "__CANCELLED__" ] && { release; exit 0; }

        if [ "$MODE" = "Sail" ]; then
            G=$(osascript <<AS
try
    set opts to {"5", "10", "15", "30", "Custom"}
    set sel to choose from list opts with prompt "Sail gap in %:" default items {"10"} with title "BattOpt - Sail Gap" OK button name "Select" cancel button name "Cancel"
    if sel is false then
        return "__CANCELLED__"
    else
        return item 1 of sel
    end if
on error
    return "__CANCELLED__"
end try
AS
)
            [ "$G" = "__CANCELLED__" ] && { release; exit 0; }
            if [ "$G" = "Custom" ]; then
                G=$(osascript <<AS
try
    set d to display dialog "Custom sail gap (5-30):" default answer "10" buttons {"Cancel", "OK"} default button "OK" with title "BattOpt"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
                [ "$G" = "__CANCELLED__" ] && { release; exit 0; }
            fi
            { [ "$G" -lt 5 ] || [ "$G" -gt 30 ]; } && G=10
            LOW=$((T - G)); [ $LOW -lt 20 ] && LOW=20
            SAILING=true
        else
            LOW=$((T - 1)); [ $LOW -lt 20 ] && LOW=20
            SAILING=false
        fi

        LAST_UPPER=$T; LAST_LOWER=$LOW
        SAIL_GAP=$([ "$MODE" = "Sail" ] && echo $((T - LOW)) || echo 0)
        save_cfg
        echo "$T" > "$HOME/.battopt-swiftbar/.sd_watch"
        hold_at_current
        soft_stop
        log "smart_discharge: target=$T mode=$MODE low=$LOW"
        nohup sudo -n "$BAT" discharge "$T" >/dev/null 2>&1 &

        nohup bash -c '
            B="'"$BAT"'"; L="'"$LOG"'"; T='"$T"'; LOW='"$LOW"'
            for i in $(seq 1 720); do
                sleep 10
                P=$(sudo -n "$B" status 2>/dev/null | grep -oE "Capacity [0-9]+" | grep -oE "[0-9]+")
                if [ -n "$P" ] && [ "$P" -le "$T" ]; then
                    sudo -n "$B" limit "$T" "$LOW" >/dev/null 2>&1
                    echo "[$(date +%H:%M:%S)] Reached ${P}% - limit ${T}/${LOW}" >> "$L"
                    break
                fi
            done
        ' >/dev/null 2>&1 &
        release ;;

    limit_custom)
        acquire; ensure_clean
        DEF="${LAST_UPPER}/${LAST_LOWER}"
        R=$(osascript <<AS
try
    set d to display dialog "Charge Limit

Format: 85/75  (upper/lower)

Sailing: $([ "$SAILING" = "true" ] && echo ON || echo OFF)

Last saved: ${DEF}" default answer "$DEF" buttons {"Cancel", "OK"} default button "OK" with title "BattOpt - Charge Limit"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$R" = "__CANCELLED__" ] && { release; exit 0; }
        U=$(echo "$R" | cut -d'/' -f1 | tr -d ' ')
        L=$(echo "$R" | cut -d'/' -f2 | tr -d ' ')
        { [ -z "$U" ] || [ -z "$L" ]; } && { release; exit 1; }
        { [ "$U" -lt 50 ] || [ "$U" -gt 100 ]; } && { release; exit 1; }
        { [ "$L" -lt 20 ] || [ "$L" -ge "$U" ]; } && { release; exit 1; }

        LAST_UPPER=$U; LAST_LOWER=$L
        SAIL_GAP=$((U - L))
        [ "$L" -lt "$U" ] && SAILING=true
        save_cfg
        apply_intent
        release ;;

    sail_on)
        acquire
        SAILING=true
        [ "$LAST_LOWER" -ge "$LAST_UPPER" ] && LAST_LOWER=$((LAST_UPPER - 5))
        [ "$LAST_LOWER" -lt 20 ] && LAST_LOWER=20
        save_cfg
        ensure_clean; apply_intent
        release ;;

    sail_off)
        acquire
        SAILING=false
        save_cfg
        ensure_clean; apply_intent
        release ;;

    sail_gap_set)
        G="$2"
        acquire
        [ "$G" = "custom" ] && G=$(osascript <<AS
try
    set d to display dialog "Gap (5-30):" default answer "10" buttons {"Cancel", "OK"} default button "OK" with title "BattOpt"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$G" = "__CANCELLED__" ] && { release; exit 0; }
        [ -z "$G" ] && { release; exit 0; }
        { [ "$G" -lt 5 ] || [ "$G" -gt 30 ]; } && { release; exit 1; }
        SAIL_GAP=$G
        if [ "$SAILING" = "true" ]; then
            LAST_LOWER=$((LAST_UPPER - G)); [ $LAST_LOWER -lt 20 ] && LAST_LOWER=20
            save_cfg
            ensure_clean; apply_intent
        else
            save_cfg
        fi
        release ;;

    calibrate)
        acquire; ensure_clean
        log "calibrate"
        nohup sudo -n "$BAT" calibrate >/dev/null 2>&1 &
        release ;;

    cal_stop) log "cal_stop"; kill_calibrate ;;

    sched_on)  log "sched_on";  sudo -n "$BAT" schedule enable  >> "$LOG" 2>&1 ;;
    sched_off) log "sched_off"; sudo -n "$BAT" schedule disable >> "$LOG" 2>&1 ;;
    clam0) sudo -n "$BAT" clamshell 0 >> "$LOG" 2>&1 ;;
    clam1) sudo -n "$BAT" clamshell 1 >> "$LOG" 2>&1 ;;
    clam2) sudo -n "$BAT" clamshell 2 >> "$LOG" 2>&1 ;;

    shutdown)
        CONFIRM=$(osascript <<AS
try
    set d to display dialog "Shut Down BattOpt?

This will:
- Kill the daemon
- Disable launchd auto-start
- Hide the menu bar icon
- Remove all limits

Battery will charge normally to 100%.

To restore: open BattOpt.app" buttons {"Cancel", "Shut Down"} default button "Cancel" with icon caution with title "BattOpt - Shutdown"
    return button returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$CONFIRM" != "Shut Down" ] && exit 0
        log "shutdown requested"
        run_with_retry limit disable >> "$LOG" 2>&1
        sudo -n /usr/local/bin/battopt-daemon-stop
        touch "$HOME/.battopt-swiftbar/.disabled"
        sleep 1
        notify "BattOpt" "Control Center shut down. Open BattOpt.app to restore."
        ;;
    restore)
        log "restore requested"
        rm -f "$HOME/.battopt-swiftbar/.disabled"
        sudo -n /usr/local/bin/battopt-daemon-start
        sleep 3
        notify "BattOpt" "Control Center restored"
        ;;

    details)
        SNAP=$(raw)
        PROCS=$(pgrep -fl "battopt" 2>/dev/null | grep -v "daemon\|pkill" | head -5)
        osascript << A
display dialog "=== BattOpt Status ===

${SNAP}

=== Intent (saved) ===
Upper: ${LAST_UPPER}%
Lower: ${LAST_LOWER}%
Sailing: ${SAILING}
Sail Gap: ${SAIL_GAP}%

=== Active Processes ===
${PROCS:-none}" buttons {"OK"} default button "OK" with title "BattOpt - Details" with icon note
A
        ;;

    about)
        LOGO="$HOME/.battopt-swiftbar/icons/battopt.png"
        [ -f "$LOGO" ] && osascript << A
display dialog "BattOpt Control Center
SwiftBar Companion v11.0

Sailing Mode:
Keeps battery between upper and lower.

Smart Discharge:
Wizard: Target -> Sail/Hold -> Gap.

Calibration:
Full cycle: discharge -> 100% -> hold 1h.

Clamshell:
Standard / Balanced / Ultimate.

Schedule:
Automatic calibration on fixed days." buttons {"OK"} default button "OK" with title "About BattOpt" with icon POSIX file "$LOGO"
A
        ;;

    open_actions_log) open "$LOG" ;;

    login_toggle)
        STATE=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -c "BattOpt" || true)
        if [ "$STATE" -gt 0 ]; then
            osascript <<OSA
tell application "System Events"
    try
        delete login item "BattOpt"
    end try
end tell
OSA
            notify "BattOpt" "Removed from Login Items"
        else
            osascript <<OSA
tell application "System Events"
    try
        delete login item "BattOpt"
    end try
    make login item at end with properties {path:"/Applications/BattOpt.app", hidden:true}
end tell
OSA
            notify "BattOpt" "Added to Login Items"
        fi
        ;;

    open_app)
        open "/Applications/BattOpt.app"
        notify "BattOpt" "Opening BattOpt Control Center"
        ;;
    sleep_report)
        acquire
        REPORT="/tmp/battopt_sleep_report_$(date +%Y%m%d_%H%M).txt"
        {
            echo "=========================================="
            echo "  BattOpt - Sleep & Battery Report"
            echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "=========================================="
            echo ""
            echo "--- BATTERY ---"
            sudo -n "$BAT" status 2>&1 | tail -n +2
            echo ""
            echo "--- SMC STATE ---"
            ioreg -rn AppleSmartBattery 2>/dev/null | grep -E '"(IsCharging|NotChargingReason|FullyCharged|ExternalChargeCapable)"'
            echo ""
            echo "--- POWER SETTINGS ---"
            pmset -g | grep -E "womp|powernap|tcpkeepalive|standbydelay|standby |hibernatemode|sleep |disksleep|displaysleep"
            echo ""
            echo "--- WAKE EVENTS (last 24h) ---"
            pmset -g log | grep -E "Wake from|DarkWake" | tail -30
            echo ""
            echo "--- WAKE REASONS SUMMARY ---"
            pmset -g log | grep "Wake from\|DarkWake" | awk '{for(i=1;i<=NF;i++) if($i ~ /due to/) print $(i+1)}' | sort | uniq -c | sort -rn | head -15
            echo ""
            echo "--- TOP PROCESSES (CPU) ---"
            ps aux | sort -rk 3 | head -8 | awk '{printf "%-8s %5s%% %5s%% %s\n", $1, $3, $4, $11}'
            echo ""
            echo "--- USB DEVICES ---"
            system_profiler SPUSBDataType 2>/dev/null | grep -E "^\s{4}\w+|Manufacturer" | head -15
            echo ""
            echo "--- BATTOPT PROCESSES ---"
            pgrep -fl "battopt" | grep -v "pgrep\|pmset" || echo "none"
            echo ""
            echo "--- CURRENT ASSERTIONS ---"
            pmset -g assertions | head -25
            echo ""
            echo "=========================================="
            echo "  End of Report"
            echo "=========================================="
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
            echo "--- BATTERY ---"
            sudo -n "$BAT" status 2>&1 | tail -n +2
            echo ""
            echo "--- POWER SETTINGS ---"
            pmset -g | grep -E "womp|powernap|tcpkeepalive|standbydelay|hibernatemode|sleep "
            echo ""
            echo "--- WAKE EVENTS (last 24h) ---"
            pmset -g log | grep -E "Wake from|DarkWake" | tail -30
            echo ""
            echo "--- ASSERTIONS ---"
            pmset -g assertions | head -25
        } > "$REPORT" 2>&1
        log "report saved: $REPORT"
        notify "BattOpt" "Report saved: $(basename "$REPORT")"
        release
        ;;

    open_reports)
        open "$HOME/.battopt-swiftbar/reports/" 2>/dev/null || notify "BattOpt" "No reports yet"
        ;;

        power_saver_on)
        acquire
        log "power_saver: on"
        ~/.battopt-swiftbar/power_saver.sh on
        notify "BattOpt" "Power Saver enabled — deep sleep optimized"
        release
        ;;

    power_saver_off)
        acquire
        log "power_saver: off"
        ~/.battopt-swiftbar/power_saver.sh off
        notify "BattOpt" "Power Saver disabled"
        release
        ;;

    power_saver_report)
        acquire
        # Summary for dialog
        PSAVER_STATE=$([ -f "$HOME/.battopt-swiftbar/.power_saver" ] && echo "ENABLED" || echo "DISABLED")
        PCT=$(sudo -n "$BAT" status 2>/dev/null | grep -oE "Capacity [0-9]+" | grep -oE "[0-9]+")
        HEALTH=$(sudo -n "$BAT" status 2>/dev/null | grep -oE "Health [0-9.]+" | grep -oE "[0-9.]+")
        WAKE_24H=$(pmset -g log | grep -c "Wake from\|DarkWake" 2>/dev/null || echo 0)
        TOP_REASON=$(pmset -g log | grep -E "Wake from|DarkWake" | awk '{for(i=1;i<=NF;i++) if($i ~ /due to/) print $(i+1)}' | sort | uniq -c | sort -rn | head -1)
        USB_DEV=$(system_profiler SPUSBDataType 2>/dev/null | grep -A 2 "Wireless Device" | grep "Product ID" | head -1)
        
        # Build dialog content
        MSG="═══ BattOpt Sleep Report ═══
        
🔋 Battery: ${PCT}%
💚 Health: ${HEALTH}%
⚙️ Power Saver: ${PSAVER_STATE}
        
📊 Last 24 hours:
  • Wake events: ${WAKE_24H}
  • Top reason: ${TOP_REASON}
        
🔌 USB devices:
${USB_DEV:-  none detected}
        
📋 Active Issues:"
        
        # Detect issues
        ISSUES=""
        [ "$([ -f "$HOME/.battopt-swiftbar/.power_saver" ] && echo 1 || echo 0)" = "0" ] && ISSUES="${ISSUES}\n  ⚠️ Power Saver DISABLED"
        [ "$WAKE_24H" -gt 30 ] && ISSUES="${ISSUES}\n  🔴 High wake count (${WAKE_24H})"
        [ -n "$USB_DEV" ] && ISSUES="${ISSUES}\n  ⚠️ USB device may prevent deep sleep"
        
        [ -z "$ISSUES" ] && ISSUES="\n  ✅ No issues detected"
        
        MSG="${MSG}${ISSUES}"
        
        RESULT=$(osascript << AS
try
    set d to display dialog "${MSG}" buttons {"Close", "Save Full Report", "Toggle Saver"} default button "Close" with title "BattOpt Sleep Report" with icon note
    return button returned of d
on error
    return "cancelled"
end try
AS
)
        
        case "$RESULT" in
            "Save Full Report")
                ~/.battopt-swiftbar/dispatch.sh sleep_report_save
                ;;
            "Toggle Saver")
                if [ -f "$HOME/.battopt-swiftbar/.power_saver" ]; then
                    ~/.battopt-swiftbar/power_saver.sh off
                    notify "BattOpt" "Power Saver disabled"
                else
                    ~/.battopt-swiftbar/power_saver.sh on
                    notify "BattOpt" "Power Saver enabled"
                fi
                ;;
        esac
        release
        ;;

    esac