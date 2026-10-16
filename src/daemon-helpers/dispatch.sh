#!/bin/bash

BAT="/usr/local/bin/battopt"
LOG="$HOME/.battopt-swiftbar/actions.log"
LOCK="$HOME/.battopt-swiftbar/.op.lock"
CFG="$HOME/.battopt-swiftbar/config"
FORCE="$HOME/.battopt-swiftbar/force_reset.sh"

# Shared session guard (state_guard.sh provides guard_session_active, etc.)
if [ -f "$HOME/.battopt-swiftbar/state_guard.sh" ]; then
    source "$HOME/.battopt-swiftbar/state_guard.sh"
fi

LAST_UPPER=85
LAST_LOWER=75
SAILING=true
SAIL_GAP=10
[ -f "$CFG" ] && source "$CFG"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }
raw() { sudo -n "$BAT" status 2>&1; }
get_pct() { raw | grep -oE "Capacity [0-9]+" | grep -oE "[0-9]+"; }

# === SMART DISCHARGE SESSION ===
SD_SESSION_FILE="$HOME/.battopt-swiftbar/.sd_session"

sd_session_new() {
    local ID="$(date +%s)_$$"
    echo "$ID" > "$SD_SESSION_FILE"
    echo "$ID"
}

sd_session_current() {
    cat "$SD_SESSION_FILE" 2>/dev/null || echo "none"
}

sd_session_invalidate() {
    rm -f "$SD_SESSION_FILE"
}

is_charging() { ioreg -rn AppleSmartBattery 2>/dev/null | grep -q '"IsCharging" = Yes'; }



# === INPUT PERSISTENCE ===
LAST_INPUTS="$HOME/.battopt-swiftbar/.last_inputs"

get_last_input() {
    local key="$1" fallback="$2"
    local val=""
    [ -f "$LAST_INPUTS" ] && val=$(grep "^${key}=" "$LAST_INPUTS" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -z "$val" ] && echo "$fallback" || echo "$val"
}


# === ATOMIC WRITE ===
atomic_write() {
    local file="$1" content="$2"
    local tmp="${file}.tmp.$$"
    printf '%s' "$content" > "$tmp" && mv "$tmp" "$file"
}


# === INPUT VALIDATION ===
validate_int() {
    # $1 = value, $2 = min, $3 = max
    local v="$1" min="$2" max="$3"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    [ "$v" -ge "$min" ] && [ "$v" -le "$max" ] || return 1
    return 0
}


save_last_input() {
    local key="$1" val="$2"
    [ -z "$key" ] && return 0
    [ -z "$val" ] && return 0
    local tmp="${LAST_INPUTS}.tmp"
    if [ -f "$LAST_INPUTS" ]; then
        grep -v "^${key}=" "$LAST_INPUTS" 2>/dev/null > "$tmp" || true
    else
        touch "$tmp"
    fi
    echo "${key}=${val}" >> "$tmp"
    mv "$tmp" "$LAST_INPUTS" 2>/dev/null || true
}



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
    wait $pid 2>/dev/null
    return 1
}

# Preflight — called by every action. Guarantees daemon responds.
preflight() {
    [ -f "$HOME/.battopt-swiftbar/.user_shutdown" ] && return 0
    # Respect active session — do NOT force_reset during charge/discharge/hold
    if command -v guard_session_active >/dev/null 2>&1 && guard_session_active; then
        log "preflight: active session ($(cat "$HOME/.battopt-swiftbar/.active_mode" 2>/dev/null)) — skipping force_reset"
        return 0
    fi
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
    # Invalidate old discharge ownership before starting another operation.
    sd_session_invalidate 2>/dev/null || true
    sudo pkill -9 -f "sd_watcher.sh" 2>/dev/null || true
    kill_clients; soft_stop
    [ -f "$HOME/.battopt-swiftbar/.user_shutdown" ] && return 0
    # Respect active session — skip force_reset during charge/discharge/hold
    if command -v guard_session_active >/dev/null 2>&1 && guard_session_active; then
        log "ensure_clean: active session — skipping force_reset"
        return 0
    fi
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
release() { rm -f "$LOCK"
    clear_cache; }

notify() {
    local NOTIFIER="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
    local ICON="$HOME/.battopt-swiftbar/icons/battopt.png"
    if [ -x "$NOTIFIER" ]; then
        if [ -f "$ICON" ]; then
            nohup "$NOTIFIER" -title "$1" -message "$2" -appIcon "$ICON" -group battopt -timeout 3 >/dev/null 2>&1 &
        else
            nohup "$NOTIFIER" -title "$1" -message "$2" -group battopt -timeout 3 >/dev/null 2>&1 &
        fi
        disown
    fi
}

apply_intent() {
    local PCT=$(get_pct)
    
    if [ "$SAILING" = "true" ] && [ "$LAST_LOWER" -lt "$LAST_UPPER" ]; then
        # Check if battery is above upper
        if [ -n "$PCT" ] && [ "$PCT" -gt "$LAST_UPPER" ]; then
            # Battery above upper — trigger discharge to upper
            local SD_ID=$(sd_session_new)
            echo "$SD_ID" > "$HOME/.battopt-swiftbar/.sd_session"
            log "apply: DISCHARGE above upper ($PCT% > $LAST_UPPER%) session=$SD_ID"
            
            # Kill old discharge
            sudo pkill -9 -f "battopt discharge" 2>/dev/null
            sudo -n "$BAT" discharge stop >/dev/null 2>&1
            sleep 1
            
            # Start watcher (background)
            nohup "$HOME/.battopt-swiftbar/sd_watcher.sh" \
                "$SD_ID" "$LAST_UPPER" "$LAST_LOWER" "$HOME/.battopt-swiftbar/.sd_session" "$LOG" "$BAT" \
                >/dev/null 2>&1 &
            disown
            
            # Start discharge
            nohup sudo -n "$BAT" discharge "$LAST_UPPER" >/dev/null 2>&1 &
            disown
            
            sleep 2
            if pgrep -f "battopt discharge" >/dev/null; then
                log "apply: discharge ACTIVE ($PCT% → $LAST_UPPER%)"
            else
                # Fallback: just set limit
                run_with_retry limit "$LAST_UPPER" "$LAST_LOWER" >> "$LOG" 2>&1
            fi
        else
            # Normal: battery below upper
            log "apply: sailing $LAST_UPPER/$LAST_LOWER (PCT=$PCT)"
            run_with_retry limit "$LAST_UPPER" "$LAST_LOWER" >> "$LOG" 2>&1
        fi
    else
        # Static hold
        local L=$((LAST_UPPER - 1))
        [ $L -lt 20 ] && L=20
        log "apply: hold $LAST_UPPER/$L (PCT=$PCT)"
        run_with_retry limit "$LAST_UPPER" "$L" >> "$LOG" 2>&1
    fi
}

hold_at_current() {
    local CUR=$(get_pct); [ -z "$CUR" ] && return 1
    local LOW=$((CUR - 1)); [ $LOW -lt 20 ] && LOW=20

    # ─── Layer 16b: unique token for this hold session ───
    local TOKEN="hold_$$_$(date +%s)_${RANDOM}"
    echo "$TOKEN" > "$HOME/.battopt-swiftbar/.hold_token"

    # Stop any discharge
    sd_session_invalidate 2>/dev/null || true
    sudo pkill -9 -f "battopt discharge" 2>/dev/null
    sudo -n "$BAT" discharge stop >/dev/null 2>&1

    # Save PRE-HOLD config so Custom dialog can default to it
    if [ ! -f "$HOME/.battopt-swiftbar/.hold_override" ]; then
        cp "$HOME/.battopt-swiftbar/config" "$HOME/.battopt-swiftbar/.pre_hold_config" 2>/dev/null
        echo "[$(date +%H:%M:%S)] saved pre-hold config (fresh hold)" >> "$LOG"
    fi

    # Persist hold target
    LAST_UPPER=$CUR
    LAST_LOWER=$LOW
    SAILING=false
    save_cfg
    log "hold: config persisted LAST_UPPER=$CUR LAST_LOWER=$LOW SAILING=false (token=$TOKEN)"
    echo "hold" > "$HOME/.battopt-swiftbar/.active_mode"
    touch "$HOME/.battopt-swiftbar/.hold_override"

    # FAST PATH: if not charging, apply and return
    if ! is_charging; then
        run_with_retry limit "$CUR" "$LOW" >> "$LOG" 2>&1
        log "held (was idle)"
        return 0
    fi

    # Apply limit IMMEDIATELY
    run_with_retry limit "$CUR" "$LOW" >> "$LOG" 2>&1
    log "limit applied at ${CUR}% — SMC wait in background"

    # Background watcher — with abort checks
    (
        sleep 2

        for i in $(seq 1 60); do
            # Abort #1: token replaced (newer hold or custom limit)
            CURRENT_TOKEN=$(cat "$HOME/.battopt-swiftbar/.hold_token" 2>/dev/null)
            if [ "$CURRENT_TOKEN" != "$TOKEN" ]; then
                echo "[$(date +%H:%M:%S)] watcher[$TOKEN]: aborted (token replaced)" >> "$LOG"
                exit 0
            fi

            # Abort #2: hold_override cleared
            if [ ! -f "$HOME/.battopt-swiftbar/.hold_override" ]; then
                echo "[$(date +%H:%M:%S)] watcher[$TOKEN]: aborted (hold_override gone)" >> "$LOG"
                exit 0
            fi

            # Success: charging stopped
            if ! is_charging; then
                echo "[$(date +%H:%M:%S)] held ${i}s" >> "$LOG"
                exit 0
            fi

            sleep 1
        done

        # Timeout reached — re-verify before force
        CURRENT_TOKEN=$(cat "$HOME/.battopt-swiftbar/.hold_token" 2>/dev/null)
        if [ "$CURRENT_TOKEN" != "$TOKEN" ]; then
            echo "[$(date +%H:%M:%S)] watcher[$TOKEN]: timeout aborted (token changed)" >> "$LOG"
            exit 0
        fi
        if [ ! -f "$HOME/.battopt-swiftbar/.hold_override" ]; then
            echo "[$(date +%H:%M:%S)] watcher[$TOKEN]: timeout aborted (hold_override gone)" >> "$LOG"
            exit 0
        fi

        # Confirm the SMC actually has our limit
        CUR_LIMIT=$(sudo -n "$BAT" status 2>/dev/null | grep -oE "upper limit [0-9]+" | grep -oE "[0-9]+")
        if [ "$CUR_LIMIT" = "$CUR" ]; then
            echo "[$(date +%H:%M:%S)] SMC slow but limit applied (60s)" >> "$LOG"
        else
            echo "[$(date +%H:%M:%S)] 60s timeout + limit FAILED → force" >> "$LOG"
            "$FORCE" > /dev/null 2>&1
        fi
    ) &
    disown

    return 0
}

kill_charge()    { log "kill_charge";    sudo pkill -9 -f "battopt charge " 2>/dev/null; sleep 0.5; }
kill_discharge() { log "kill_discharge"; sudo pkill -9 -f "battopt discharge" 2>/dev/null; sudo -n "$BAT" discharge stop >/dev/null 2>&1; sleep 0.5; }
kill_calibrate() { log "kill_calibrate"; sudo pkill -9 -f "battopt calibrate" 2>/dev/null; sudo -n "$BAT" calibrate stop >/dev/null 2>&1; sleep 0.5; }


# === CACHE INVALIDATION ===
clear_cache() {
    rm -f "$HOME/.battopt-swiftbar/.status_cache"
}

case "$1" in
    force_reset) "$FORCE" ;;
    
    sleep_mode_default)
        acquire
        rm -f "$HOME/.battopt-swiftbar/.sleep_override_ac"
        rm -f "$HOME/.battopt-swiftbar/.sleep_override_lid"
        rm -f "$HOME/.battopt-swiftbar/.sleep_override_batt"
        sudo -n /usr/bin/pmset -a disablesleep 0
        # Battery defaults
        sudo -n /usr/bin/pmset -b standbydelaylow 900
        sudo -n /usr/bin/pmset -b standbydelayhigh 900
        sudo -n /usr/bin/pmset -b autopoweroffdelay 900
        # AC defaults — restore normal sleep timing
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
        # Requires AC
        if ! pmset -g batt 2>/dev/null | grep -q "AC Power"; then
            osascript -e 'display dialog "⚠️  AC required

Presentation Mode only works with the charger connected." buttons {"OK"} with title "Sleep Mode" with icon caution' 2>/dev/null
            release
            exit 0
        fi
        rm -f "$HOME/.battopt-swiftbar/.sleep_override_lid" "$HOME/.battopt-swiftbar/.sleep_override_batt"
        touch "$HOME/.battopt-swiftbar/.sleep_override_ac"
        sudo -n /usr/bin/pmset -c sleep 0
        sudo -n /usr/bin/pmset -c displaysleep 0
        sudo -n /usr/bin/pmset -c disksleep 0
        sudo -n /usr/bin/pmset -a disablesleep 0
        sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null
        atomic_write "$HOME/.battopt-swiftbar/.sleep_mode" "presentation"
        log "sleep_mode: presentation"
        notify "BattOpt" "Sleep Mode: Presentation"
        release
        ;;

    sleep_mode_download)
        acquire
        if ! pmset -g batt 2>/dev/null | grep -q "AC Power"; then
            osascript -e 'display dialog "⚠️  AC required

Long Tasks mode only works with the charger connected." buttons {"OK"} with title "Sleep Mode" with icon caution' 2>/dev/null
            release
            exit 0
        fi
        BUTTON=$(osascript << 'AS'
try
    display dialog "⚠️  Enable Long Tasks Mode?

Keeps Mac fully awake with lid closed.

Risks:
• Heat buildup — place on hard surface only
• Never put in bag or cushion
• Auto-disables when unplugged

Best for: large downloads, long exports, backups." buttons {"Cancel", "Enable"} default button "Cancel" with title "Sleep Mode" with icon caution
    return button returned of result
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$BUTTON" != "Enable" ] && { release; exit 0; }
        
        # Ensure sleep disable is off before starting
        sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null
        sleep 1
        
        # Enable sleep disable (lid-closed awake)
        sudo -n /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1
        
        # Verify it started
        sleep 1
        if [ "$(pmset -g | awk '/SleepDisabled/{print $2}')" != "1" ]; then
            notify "BattOpt" "Long Tasks: FAILED to start"
            release
            exit 1
        fi
        
        atomic_write "$HOME/.battopt-swiftbar/.sleep_mode" "download"
        log "sleep_mode: download (disablesleep=1)"
        notify "BattOpt" "Long Tasks: ON — disable when done"
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
        BUTTON=$(osascript << 'AS'
try
    display dialog "⚠️  Enable Travel Mode?

Battery hibernates after 4h instead of 30min.

Impact:
• Drains battery ~3% more overnight
• Keeps session state alive longer
• Only affects battery (AC unchanged)

Best for: short trips, keeping state alive." buttons {"Cancel", "Enable"} default button "Cancel" with title "Sleep Mode" with icon caution
    return button returned of result
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$BUTTON" != "Enable" ] && { release; exit 0; }
        
        rm -f "$HOME/.battopt-swiftbar/.sleep_override_ac" "$HOME/.battopt-swiftbar/.sleep_override_lid"
        touch "$HOME/.battopt-swiftbar/.sleep_override_batt"
        sudo -n /usr/bin/pmset -b standbydelaylow 14400
        sudo -n /usr/bin/pmset -b standbydelayhigh 14400
        sudo -n /usr/bin/pmset -b autopoweroffdelay 14400
        sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null
        atomic_write "$HOME/.battopt-swiftbar/.sleep_mode" "travel"
        log "sleep_mode: travel"
        notify "BattOpt" "Sleep Mode: Travel"
        release
        ;;
    


    
    
    
    reapply_limit)
        # Manually reapply the saved limit (called after daemon restart)
        source "$HOME/.battopt-swiftbar/config"
        UPPER="${LAST_UPPER:-85}"
        LOWER="${LAST_LOWER:-80}"
        sudo -n "$BAT" limit "$UPPER" "$LOWER" >> "$LOG" 2>&1
        sleep 1
        log "reapply_limit: $UPPER/$LOWER"
        notify "BattOpt" "Limit re-applied: $UPPER/$LOWER"
        ;;
    
    reset_defaults)
        acquire
        BUTTON=$(osascript << 'AS'
try
    set d to display dialog "Reset all BattOpt settings to defaults?

This will:
  • Charge limits: 85% / 80%
  • Sailing Mode: ON (gap 5)
  • Power Mode: Balanced (18/10/15)
  • Clear saved dialog inputs (.last_inputs)
  • Kill any running discharge/calibration

This action cannot be undone." buttons {"Cancel", "Reset"} default button "Cancel" with title "BattOpt - Reset to Defaults" with icon caution
    return button returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$BUTTON" = "__CANCELLED__" ] && { release; exit 0; }
        
        if [ "$BUTTON" = "Reset" ]; then
            sd_session_invalidate
            sudo -n pkill -9 -f "sd_watcher" 2>/dev/null || true
            # 1) Kill running operations
            kill_discharge 2>/dev/null
            kill_charge 2>/dev/null
            kill_calibrate 2>/dev/null
            
            # 2) Reset config file
            cat > "$HOME/.battopt-swiftbar/config" << 'CFGEOF'
LAST_UPPER=85
LAST_LOWER=80
SAILING=true
SAIL_GAP=5
CFGEOF
            
            # 3) Apply limit to SMC
            sudo -n "$BAT" limit 85 80 >> "$LOG" 2>&1
            
            # 4) Reset Power Mode to Balanced
            ~/.battopt-swiftbar/power_mode.sh balanced >> "$LOG" 2>&1

            # 5) Clear saved input history (reset dialogs to defaults)
            rm -f "$HOME/.battopt-swiftbar/.last_inputs" 2>/dev/null
            
            # 6) Remove stale state files
            rm -f "$HOME/.battopt-swiftbar/.sd_watch" 2>/dev/null
            rm -f "$HOME/.battopt-swiftbar/.daemon_fail_count" 2>/dev/null
            
            log "reset_defaults: 85/80, Sailing ON, Power Mode Balanced"
            notify "BattOpt" "Reset to Defaults — done"
        fi
        release
        echo "idle" > "$HOME/.battopt-swiftbar/.active_mode"
        ;;
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
        LAST_UPPER=100
        LAST_LOWER=99
        SAILING=false
        SAIL_GAP=1
        save_cfg
        rm -f "$HOME/.battopt-swiftbar/.sd_session"
        [ -n "$(guard_token 2>/dev/null)" ] && guard_session_end "$(guard_token)" 2>/dev/null
        echo "idle" > "$HOME/.battopt-swiftbar/.active_mode"
        release ;;

    charge_full)
        acquire; ensure_clean
        # Clear legacy discharge session so its watcher can't corrupt state
        sd_session_invalidate 2>/dev/null || true
        sudo -n pkill -9 -f "sd_watcher" 2>/dev/null || true
        rm -f "$HOME/.battopt-swiftbar/.sd_session"
        # A guard token must be created and retained before the watcher can
        # verify ownership. The current block writes charge_full without one.
        log "charge_full: START"

        # Layer 18: mark active mode + create guard token
        TOKEN=$(guard_session_begin charge_full)
        [ -n "$TOKEN" ] || { log "charge_full: token fail"; release; exit 1; }

        # Release all limits — must use 100/99 to clear SMC hold
        # (limit disable alone doesn't release NCR=14)
        run_with_retry limit 100 99 >/dev/null 2>&1
        sleep 2

        # Start charging
        nohup sudo -n "$BAT" charge 100 >/dev/null 2>&1 &
        release

        # Background watcher: after 99%, sync config + active_mode
        nohup bash -c '
            B="'"$BAT"'"
            L="'"$LOG"'"
            D="'"$HOME"'/.battopt-swiftbar"
            T="'"$TOKEN"'"
            source "$D/state_guard.sh" 2>/dev/null
            COMPLETED=0
            for i in $(seq 1 720); do
                sleep 10
                P=$(sudo -n "$B" status 2>/dev/null | grep -oE "Capacity [0-9]+" | grep -oE "[0-9]+")
                if [ -n "$P" ] && [ "$P" -ge 99 ]; then
                    guard_token_matches "$T" 2>/dev/null || [ "$(cat "$D/.active_mode" 2>/dev/null)" = "charge_full" ] || exit 0
                    [ "$(cat "$D/.active_mode" 2>/dev/null)" = "charge_full" ] || exit 0
                    # Lock SMC at 99/98
                    sudo -n "$B" limit 99 98 >/dev/null 2>&1
                    # Layer 18: sync config to match — prevents guardian drift
                    cat > "$D/config" <<CFG
LAST_UPPER=99
LAST_LOWER=98
SAILING=false
SAIL_GAP=1
CFG
                    sudo -n "$B" charge stop >/dev/null 2>&1
                    guard_session_end "$T" 2>/dev/null
                    echo "[$(date +%H:%M:%S)] charge_full: reached 99%, config synced to 99/98" >> "$L"
                    COMPLETED=1
                    break
                fi
            done
            if [ "$COMPLETED" -eq 0 ]; then
                echo "[$(date +%H:%M:%S)] charge_full: timeout — stopping charge and ending session" >> "$L"
                sudo -n "$B" charge stop >/dev/null 2>&1
                guard_session_end "$T" 2>/dev/null
            fi
        ' >/dev/null 2>&1 &
        ;;



    smart_discharge)
        acquire; ensure_clean
        # === SAFETY: kill previous discharge + reset limit ===
        sudo pkill -9 -f "battopt discharge" 2>/dev/null
        sudo -n "$BAT" discharge stop >/dev/null 2>&1
        sleep 1
        # If old limit was temp (from previous hold_at_current), restore from config
        source "$HOME/.battopt-swiftbar/config" 2>/dev/null
        sudo -n "$BAT" limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" >/dev/null 2>&1
        # === END SAFETY ===
        
        CUR=$(get_pct); [ -z "$CUR" ] && { release; exit 1; }

        # Smart default: if last target >= current, use CUR-5
        LAST_TARGET=$(get_last_input SD_TARGET 75)
        if [ "$LAST_TARGET" -ge "$CUR" ]; then
            DEFAULT_TARGET=$((CUR - 5))
            [ "$DEFAULT_TARGET" -lt 20 ] && DEFAULT_TARGET=20
        else
            DEFAULT_TARGET="$LAST_TARGET"
        fi
        
        T=$(osascript <<AS
try
    set d to display dialog "Smart Discharge - Target

Current: ${CUR}%

Target must be LOWER than ${CUR}%
Recommended: ${DEFAULT_TARGET}%

Target battery level (20-90):" default answer "${DEFAULT_TARGET}" buttons {"Cancel", "Next"} default button "Next" with title "BattOpt"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$T" = "__CANCELLED__" ] && { release; exit 0; }
        if ! validate_int "$T" 20 90; then
            notify "BattOpt" "Invalid target (20-90) — cancelled"
            release
            exit 0
        fi
        save_last_input SD_TARGET "$T"
        if [ "$T" -lt 20 ] || [ "$T" -gt 90 ]; then
            notify "BattOpt" "Invalid target: ${T}% (must be 20-90)"
            release
            exit 0
        fi
        if [ "$T" -ge "$CUR" ]; then
            notify "BattOpt" "Target ${T}% must be < current ${CUR}%"
            release
            exit 0
        fi

        MODE=$(osascript <<AS
try
    set d to display dialog "Smart Discharge - Mode

After reaching ${T}%:

Sail = resume charging at (${T} - gap)
Hold = freeze at ${T}% only" buttons {"Cancel", "Hold", "Sail"} default button "$(get_last_input SD_MODE Sail)" with title "BattOpt"
    return button returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$MODE" = "__CANCELLED__" ] && { release; exit 0; }
        save_last_input SD_MODE "$MODE"

        if [ "$MODE" = "Sail" ]; then
            # Determine default item based on last SD_SAIL_GAP
            LAST_GAP=$(get_last_input SD_SAIL_GAP 10)
            case "$LAST_GAP" in
                5|10|15|30) DEFAULT_GAP="$LAST_GAP" ;;
                *)          DEFAULT_GAP="Custom" ;;
            esac
            
            G=$(osascript <<AS
try
    set opts to {"5", "10", "15", "30", "Custom"}
    set sel to choose from list opts with prompt "Sail gap in %:" default items {"$DEFAULT_GAP"} with title "BattOpt - Sail Gap" OK button name "Select" cancel button name "Cancel"
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
            [ "$G" != "Custom" ] && save_last_input SD_SAIL_GAP "$G"
            if [ "$G" = "Custom" ]; then
                G=$(osascript <<AS
try
    set d to display dialog "Custom sail gap (5-30):" default answer "$(get_last_input SAIL_GAP_CUSTOM 10)" buttons {"Cancel", "OK"} default button "OK" with title "BattOpt"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
                [ "$G" = "__CANCELLED__" ] && { release; exit 0; }
                if ! validate_int "$G" 5 30; then
                    notify "BattOpt" "Invalid gap (5-30) — cancelled"
                    release
                    exit 0
                fi
                save_last_input SAIL_GAP_CUSTOM "$G"
                save_last_input SD_SAIL_GAP "$G"
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
        # Stop charging cleanly without invoking hold_at_current
        sd_session_invalidate 2>/dev/null || true
        sudo -n "$BAT" discharge stop >/dev/null 2>&1
        sudo -n "$BAT" charge stop >/dev/null 2>&1
        sudo -n pkill -9 -f "battopt charge " 2>/dev/null || true
        sleep 1
        # Mark active mode as discharge.
        echo "discharge" > "$HOME/.battopt-swiftbar/.active_mode"
        rm -f "$HOME/.battopt-swiftbar/.hold_override" "$HOME/.battopt-swiftbar/.hold_token" "$HOME/.battopt-swiftbar/.pre_hold_config"
        soft_stop
        # Layer 18e: create a guarded session so guardian sees it as legitimate.
        rm -f "$HOME/.battopt-swiftbar/.active_token"
        SD_ID=$(guard_session_begin discharge)
        [ -n "$SD_ID" ] || { release; exit 1; }
        echo "$SD_ID" > "$HOME/.battopt-swiftbar/.sd_session"
        log "smart_discharge: target=$T mode=$MODE low=$LOW active_mode=discharge session=$SD_ID"
        # Launch persistent watcher
        nohup "$HOME/.battopt-swiftbar/sd_watcher.sh" \
            "$SD_ID" "$T" "$LOW" "$HOME/.battopt-swiftbar/.sd_session" "$LOG" "$BAT" \
            >/dev/null 2>&1 &
        disown
        # Launch discharge
        nohup sudo -n "$BAT" discharge "$T" >/dev/null 2>&1 &
        disown
        sleep 3
        pgrep -f "battopt discharge" >/dev/null || \
            sudo -n "$BAT" limit "$T" "$LOW" >> "$LOG" 2>&1
        release ;;

    limit_custom)
        acquire; ensure_clean

        # FIX: Kill ALL active ops (charge_full blocks discharge)
        log "limit_custom: killing active ops"
        sudo pkill -9 -f "battopt charge" 2>/dev/null || true
        sudo pkill -9 -f "battopt discharge" 2>/dev/null || true
        sudo pkill -9 -f "battopt calibrate" 2>/dev/null || true
        sudo -n "$BAT" charge stop >/dev/null 2>&1 || true
        sudo -n "$BAT" discharge stop >/dev/null 2>&1 || true
        sudo -n "$BAT" calibrate stop >/dev/null 2>&1 || true
        sd_session_invalidate 2>/dev/null || true
        rm -f "$HOME/.battopt-swiftbar/.active_token"
        echo "idle" > "$HOME/.battopt-swiftbar/.active_mode"
        sleep 2
        
        CUR=$(get_pct)

        # Default: prefer last user-entered custom limit
        DEF=$(get_last_input LIMIT_CUSTOM "")
        [ -z "$DEF" ] && DEF="${LAST_UPPER}/${LAST_LOWER}"
        log "limit_custom: default $DEF"
        
        R=$(osascript <<AS
try
    set d to display dialog "Charge Limit

Current battery: ${CUR}%

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
        { [ -z "$U" ] || [ -z "$L" ]; } && { notify "BattOpt" "Empty input"; release; exit 0; }
        validate_int "$U" 50 100 || { notify "BattOpt" "Upper must be 50-100"; release; exit 0; }
        validate_int "$L" 20 99 || { notify "BattOpt" "Lower must be 20-99"; release; exit 0; }
        [ "$L" -ge "$U" ] && { notify "BattOpt" "Lower must be below upper"; release; exit 0; }
        
        LAST_UPPER=$U; LAST_LOWER=$L
        SAIL_GAP=$((U - L))
        [ "$L" -lt "$U" ] && SAILING=true
        save_cfg
        save_last_input LIMIT_CUSTOM "$U/$L"
        # LAYER 16: clear hold flags
        rm -f "$HOME/.battopt-swiftbar/.hold_override"
        rm -f "$HOME/.battopt-swiftbar/.hold_token"
        rm -f "$HOME/.battopt-swiftbar/.pre_hold_config"
        log "limit_custom: cleared hold flags + pre-hold config"
        
        if [ "$CUR" -gt "$U" ]; then
            # Discharge path
            rm -f "$HOME/.battopt-swiftbar/.active_token"
            SD_ID=$(guard_session_begin discharge)
            [ -n "$SD_ID" ] || SD_ID=$(sd_session_new)
            echo "$SD_ID" > "$HOME/.battopt-swiftbar/.sd_session"
            log "limit_custom: START discharge $CUR%→$U% (session $SD_ID)"
            notify "BattOpt" "Discharging ${CUR}% → ${U}%"
            
            # Start watcher in background
            nohup "$HOME/.battopt-swiftbar/sd_watcher.sh" \
                "$SD_ID" "$U" "$L" "$HOME/.battopt-swiftbar/.sd_session" "$LOG" "$BAT" \
                >/dev/null 2>&1 &
            disown
            
            # Mark active mode as discharge
            echo "discharge" > "$HOME/.battopt-swiftbar/.active_mode"
            # Start discharge
            nohup sudo -n "$BAT" discharge "$U" >/dev/null 2>&1 &
            disown
            
            sleep 3
            if pgrep -f "battopt discharge" >/dev/null; then
                log "limit_custom: discharge ACTIVE (active_mode=discharge)"
                notify "BattOpt" "Discharge active → ${U}%"
            else
                log "limit_custom: discharge FAILED — fallback to limit"
                rm -f "$HOME/.battopt-swiftbar/.sd_session"
                rm -f "$HOME/.battopt-swiftbar/.active_token"
                echo "idle" > "$HOME/.battopt-swiftbar/.active_mode"
                sudo -n "$BAT" limit "$U" "$L" >/dev/null 2>&1
            fi
        else
            # Charge/Hold path
            sd_session_invalidate
            echo "idle" > "$HOME/.battopt-swiftbar/.active_mode"
            apply_intent
            log "limit_custom: applied $U/$L (PCT=$CUR, will charge, active_mode=idle)"
            notify "BattOpt" "Limit set ${U}% / ${L}%"
        fi
        
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
    set d to display dialog "Gap (5-30):" default answer "$(get_last_input GAP_CUSTOM 10)" buttons {"Cancel", "OK"} default button "OK" with title "BattOpt"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$G" = "__CANCELLED__" ] && { release; exit 0; }
            save_last_input GAP_CUSTOM "$G"
        [ -z "$G" ] && { release; exit 0; }
        validate_int "$G" 5 30 || { notify "BattOpt" "Invalid gap (5-30)"; release; exit 0; }
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

    cal_stop) acquire; log "cal_stop"; kill_calibrate; release ;;

    sched_on)  log "sched_on";  sudo -n "$BAT" schedule enable  >> "$LOG" 2>&1 ;;
    sched_off) log "sched_off"; sudo -n "$BAT" schedule disable >> "$LOG" 2>&1 ;;
    clam0) sudo -n "$BAT" clamshell 0 >> "$LOG" 2>&1 ;;
    clam1) sudo -n "$BAT" clamshell 1 >> "$LOG" 2>&1 ;;
    clam2) sudo -n "$BAT" clamshell 2 >> "$LOG" 2>&1 ;;

    shutdown)
        acquire
        CONFIRM=$(osascript <<'AS'
try
    set d to display dialog "Shut Down BattOpt?\n\nThis will stop all agents, release battery limit,\nand remove the menu bar icon." buttons {"Cancel", "Shut Down"} default button "Shut Down" with icon caution with title "BattOpt - Shutdown"
    return button returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$CONFIRM" != "Shut Down" ] && { release; exit 0; }
        log "shutdown: START"
        START_TS=$(date +%s)

        # 1. Set flag FIRST
        touch "$HOME/.battopt-swiftbar/.user_shutdown"

        # 1b. Grace period
        sleep 2

        # 1c. Kill BattOpt.app and remove from Login Items
        pkill -f "/Applications/BattOpt.app" 2>/dev/null || true
        osascript -e 'tell application "System Events" to try' \
                -e 'delete login item "BattOpt"' \
                -e 'end try' 2>/dev/null || true

        # 2. Kill in-flight ops + force_reset watchdog
        pkill -9 -f "force_reset" 2>/dev/null || true
        sudo -n pkill -9 -f "battopt discharge" 2>/dev/null || true
        sudo -n pkill -9 -f "battopt charge" 2>/dev/null || true
        sudo -n pkill -9 -f "battopt calibrate" 2>/dev/null || true
        sleep 1

        # 3. Unload user agents FIRST + kill residual watchdogs
        for plist in "$HOME/Library/LaunchAgents/"com.battopt.*.plist; do
            [ -f "$plist" ] || continue
            launchctl unload -w "$plist" 2>/dev/null
        done
        pkill -9 -f "guardian" 2>/dev/null || true
        pkill -9 -f "enforce_watchdog" 2>/dev/null || true
        pkill -9 -f "consolidated" 2>/dev/null || true
        pkill -9 -f "self-healing" 2>/dev/null || true
        pkill -9 -f "sd_watcher" 2>/dev/null || true
        log "shutdown: agents unloaded"

        # 4. Release SMC WHILE DAEMON STILL ALIVE (chicken-egg fix)
        log "shutdown: setting limit_enable=0 in battopt_cfg"
        sudo -n /usr/local/bin/battopt-release-cfg >> "$LOG" 2>&1
        log "shutdown: sending limit 100 99"
        sudo -n /usr/local/bin/battopt limit 100 99 >> "$LOG" 2>&1 || true

        # 5. Poll SMC BEFORE killing daemon
        RELEASED=no
        for i in $(seq 1 10); do
            sleep 1
            NCR_NOW=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -oE '"NotChargingReason"=[0-9]+' | grep -oE '[0-9]+' | head -1)
            if [ "$NCR_NOW" != "14" ]; then
                RELEASED=yes
                log "shutdown: SMC released after ${i}s (NCR=$NCR_NOW)"
                break
            fi
        done
        [ "$RELEASED" = "no" ] && log "shutdown: WARN SMC still NCR=14 before daemon kill"

        # 6. THEN stop daemon ROBUSTLY
        sudo -n pkill -9 -f "Application Support/battopt/battopt daemon" 2>/dev/null || true
        sudo -n launchctl bootout system/com.buddha-path.BattOpt.daemon 2>/dev/null || true
        sudo -n launchctl unload -w /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist 2>/dev/null || true
        sudo -n launchctl disable system/com.buddha-path.BattOpt.daemon 2>/dev/null || true
        sleep 2
        sudo -n pkill -9 -f "Application Support/battopt/battopt daemon" 2>/dev/null || true
        sudo -n rm -f "/Library/Application Support/battopt/battopt.sock" 2>/dev/null || true
        if sudo -n launchctl print system/com.buddha-path.BattOpt.daemon 2>&1 | grep -q "Could not find service"; then
            log "shutdown: daemon stopped+disabled verified"
        else
            log "shutdown: WARN daemon still loaded after bootout/unload"
        fi

        # 7. Stop powerwatch
        sudo -n launchctl bootout system/com.battopt.powerwatch 2>/dev/null || true
        sudo -n /usr/local/bin/battopt-powerwatch-stop 2>/dev/null || true
        sudo -n launchctl unload -w /Library/LaunchDaemons/com.battopt.powerwatch.plist 2>/dev/null || true
        sudo -n pkill -9 -f "battopt-swiftbar/powerwatch" 2>/dev/null || true
        sleep 1
        log "shutdown: powerwatch stopped"

        # 8. Verify cfg still 0 after daemon dead
        if sudo -n grep -q "limit_enable = 1" "/Library/Application Support/battopt/battopt_cfg" 2>/dev/null; then
            log "shutdown: cfg reverted to 1 after daemon kill, retrying release-cfg"
            sudo -n /usr/local/bin/battopt-release-cfg >> "$LOG" 2>&1 || true
        fi

        # 9. Purge state files
        for _sf in .sd_session .sd_watch .active_mode \
                   .hold_override .hold_token .pre_hold_config \
                   .armed_for_sleep .status_cache \
                   .enforce_hb .enforce_state .ac_state .ncr_state \
                   .sleep_prediction .current_power_mode \
                   .sleep_mode .sleep_profile .temp_alert_state; do
            rm -f "$HOME/.battopt-swiftbar/$_sf" 2>/dev/null
        done
        rm -f "$HOME/.battopt-swiftbar/.op.lock" "$HOME/.battopt-swiftbar/.launch.lock" 2>/dev/null
        rm -f "$HOME/.battopt-swiftbar/.throttle_"* 2>/dev/null
        rm -rf "$HOME/.battopt-swiftbar/.notify"/* 2>/dev/null
        mkdir -p "$HOME/.battopt-swiftbar/.notify"
        : > "$HOME/.battopt-swiftbar/.enforce.log" 2>/dev/null
        : > "$HOME/.battopt-swiftbar/.guardian.log" 2>/dev/null
        log "shutdown: state files purged"

        # 10. Park plugin
        mkdir -p "$HOME/.battopt-swiftbar/disabled"
        for pf in "$HOME/SwiftBar/"battopt.*.sh; do
            [ -f "$pf" ] || continue
            mv "$pf" "$HOME/.battopt-swiftbar/disabled/" 2>/dev/null
        done

        # 11. Kill SwiftBar
        killall SwiftBar 2>/dev/null

        # 12. Verification gate
        sleep 1
        SURVIVORS=$(pgrep -fl 'battopt|powerwatch|sd_watcher|guardian|enforce_watchdog' 2>/dev/null | grep -v "dispatch.sh" || true)
        LAUNCH_SURVIVORS=""
        if ! sudo -n launchctl print system/com.buddha-path.BattOpt.daemon 2>&1 | grep -q "Could not find service"; then
            LAUNCH_SURVIVORS="com.buddha-path.BattOpt.daemon"
        fi
        if ! sudo -n launchctl print system/com.battopt.powerwatch 2>&1 | grep -q "Could not find service"; then
            LAUNCH_SURVIVORS="${LAUNCH_SURVIVORS} com.battopt.powerwatch"
        fi
        NCR_NOW=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -oE '"NotChargingReason"=[0-9]+' | grep -oE '[0-9]+' | head -1)
        CFG_EN=$(sudo -n head -c 100 "/Library/Application Support/battopt/battopt_cfg" 2>/dev/null | grep -oE "limit_enable = [01]" || echo "unknown")
        FAIL=0
        [ -n "$SURVIVORS" ] && { log "shutdown: FAIL survivors pgrep: $SURVIVORS"; FAIL=1; }
        [ -n "$LAUNCH_SURVIVORS" ] && { log "shutdown: FAIL survivors launchctl: $LAUNCH_SURVIVORS"; FAIL=1; }
        [ "$CFG_EN" = "limit_enable = 1" ] && { log "shutdown: FAIL cfg still enabled ($CFG_EN)"; FAIL=1; }
        [ "$NCR_NOW" = "14" ] && log "shutdown: WARN SMC still NCR=14"
        END_TS=$(date +%s)
        if [ "$FAIL" -eq 0 ]; then
            log "shutdown: COMPLETE VERIFIED in $((END_TS-START_TS))s"
        else
            log "shutdown: INCOMPLETE in $((END_TS-START_TS))s"
        fi
        notify "BattOpt" "Shut down. Open BattOpt.app to restore."
        release
        ;;

    resume)
        acquire
        log "resume requested"
        
        # 1. Restore plugin file
        mkdir -p "$HOME/SwiftBar"
        if [ -f "$HOME/.battopt-swiftbar/disabled/battopt.10s.sh" ]; then
            mv "$HOME/.battopt-swiftbar/disabled/battopt.10s.sh" "$HOME/SwiftBar/"
            chmod +x "$HOME/SwiftBar/battopt.10s.sh"
        fi
        
        # 2. Clean stale flags
        rm -f "$HOME/.battopt-swiftbar/.disabled" "$HOME/.battopt-swiftbar/.paused" "$HOME/.battopt-swiftbar/.user_shutdown" 2>/dev/null
        # 2b. Re-add BattOpt.app to Login Items
        osascript -e 'tell application "System Events" to try' \
                -e 'make login item at end with properties {path:"/Applications/BattOpt.app", hidden:true}' \
                -e 'end try' 2>/dev/null || true
        defaults delete com.ameba.SwiftBar DisabledPlugins 2>/dev/null
        
        # 3. Start daemon
        sudo -n /usr/local/bin/battopt-daemon-start 2>/dev/null
        sleep 3
        # 3b. Start powerwatch
        sudo -n /usr/local/bin/battopt-powerwatch-start 2>/dev/null
        sleep 1

        # 3c. Reload all LaunchAgents (reverses shutdown unload -w)
        for plist in "$HOME/Library/LaunchAgents/"com.battopt.*.plist; do
            [ -f "$plist" ] || continue
            launchctl load -w "$plist" 2>/dev/null
        done

        
        # 4. Reapply limit
        source "$HOME/.battopt-swiftbar/config" 2>/dev/null
        sudo -n "$BAT" limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
        
        # 5. Launch SwiftBar if not running
        if ! pgrep -x SwiftBar >/dev/null 2>&1; then
            nohup /Applications/SwiftBar.app/Contents/MacOS/SwiftBar >/dev/null 2>&1 &
        fi
        
        # 6. Notify
        notify "BattOpt" "Restored"
        release
        ;;

    restore)
        ~/.battopt-swiftbar/dispatch.sh resume
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
        [ -f "$LOGO" ] && osascript - "$LOGO" <<'A'
on run argv
    set logoPath to item 1 of argv
    set aboutText to "BattOpt Control Center" & return & ¬
        "SwiftBar Companion v1.3.0" & return & return & ¬
        "Sailing Mode:" & return & ¬
        "Keeps battery between upper and lower." & return & return & ¬
        "Smart Discharge:" & return & ¬
        "Wizard: Target -> Sail/Hold -> Gap." & return & return & ¬
        "Calibration:" & return & ¬
        "Full cycle: discharge -> 100% -> hold 1h." & return & return & ¬
        "Clamshell:" & return & ¬
        "Standard / Balanced / Ultimate." & return & return & ¬
        "Schedule:" & return & ¬
        "Automatic calibration on fixed days."
    display dialog aboutText buttons {"OK"} default button "OK" with title "About BattOpt" with icon (POSIX file logoPath)
end run
A
        ;;

    open_actions_log) open "$LOG" ;;

    login_toggle)
        acquire
        STATE=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -c "BattOpt" || true)
        STATE=${STATE:-0}; case "$STATE" in ''|*[!0-9]*) STATE=0;; esac
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
        release
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
            pmset -g log | awk '/Wake from|DarkWake/ { for (i = 1; i <= NF; i++) if ($i == "due" && $(i + 1) == "to") print $(i + 2) }' | sort | uniq -c | sort -rn | head -15
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
        WAKE_24H=$(pmset -g log 2>/dev/null | grep -cE "Wake from|DarkWake")
        WAKE_24H=${WAKE_24H:-0}
        TOP_REASON=$(pmset -g log | awk '/Wake from|DarkWake/ { for (i = 1; i <= NF; i++) if ($i == "due" && $(i + 1) == "to") print $(i + 2) }' | sort | uniq -c | sort -rn | head -1)
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

        auto_cleanup_toggle)
        acquire
        AUTO_FLAG="$HOME/.battopt-swiftbar/.auto_cleanup"
        if [ -f "$AUTO_FLAG" ]; then
            rm -f "$AUTO_FLAG"
            log "auto_cleanup: OFF"
            notify "BattOpt" "Auto Cleanup disabled"
        else
            touch "$AUTO_FLAG"
            log "auto_cleanup: ON"
            notify "BattOpt" "Auto Cleanup enabled (15 min idle)"
        fi
        release
        ;;

    pre_sleep_now)
        acquire
        log "Manual pre-sleep cleanup"
        ~/.battopt-swiftbar/pre_sleep_cleanup.sh
        notify "BattOpt" "Pre-Sleep cleanup applied"
        release
        ;;

    post_wake_now)
        acquire
        log "Manual post-wake restore"
        ~/.battopt-swiftbar/post_wake_restore.sh
        rm -f "$HOME/.battopt-swiftbar/.pre_sleep_done"
        notify "BattOpt" "Services restored"
        release
        ;;

        arm_sleep)
        acquire
        ~/.battopt-swiftbar/arm_sleep.sh
        release
        ;;

    disarm_sleep)
        acquire
        ~/.battopt-swiftbar/post_wake_restore.sh
        notify "BattOpt" "Sleep disarmed — services restored"
        release
        ;;

        logs_ai_bundle)
        acquire
        DIR="$HOME/.battopt-swiftbar/reports/ai_diagnostic"
        mkdir -p "$DIR"
        STAMP=$(date +%Y%m%d_%H%M%S)
        BUNDLE="$DIR/bundle_$STAMP.md"
        
        {
            echo "# BattOpt — AI Diagnostic Bundle"
            echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
            echo "## System"
            echo '```'
            sw_vers
            uname -a
            uptime
            echo '```'
            echo ""
            echo "## Battery State"
            echo '```'
            sudo -n "$BAT" status 2>&1
            echo '```'
            echo ""
            echo "## pmset Settings"
            echo '```'
            pmset -g | grep -E "hibernatemode|standbydelay|autopoweroff|powernap|womp|tcpkeepalive|displaysleep|^ sleep"
            echo '```'
            echo ""
            echo "## LaunchAgents (battopt)"
            echo '```'
            launchctl list | grep battopt 2>&1
            sudo launchctl list | grep battopt 2>&1
            echo '```'
            echo ""
            echo "## Recent Actions (100 lines)"
            echo '```'
            tail -100 "$HOME/.battopt-swiftbar/actions.log" 2>/dev/null
            echo '```'
            echo ""
            echo "## Sailing History"
            echo '```'
            cat "$HOME/.battopt-swiftbar/.sailing_history" 2>/dev/null || echo "No transitions"
            echo '```'
            echo ""
            echo "## Arm Log"
            echo '```'
            tail -50 "$HOME/.battopt-swiftbar/.arm_log" 2>/dev/null || echo "No data"
            echo '```'
            echo ""
            echo "## BattOpt Daemon Log (last 50)"
            echo '```'
            tail -50 /Library/Logs/battopt/battopt.log 2>/dev/null
            echo '```'
            echo ""
            echo "## Wake Events (last 20)"
            echo '```'
            pmset -g log | grep -E "Wake from|DarkWake|Entering Sleep" | tail -20
            echo '```'
            echo ""
            echo "## Top CPU (10)"
            echo '```'
            ps -axo %cpu,%mem,command | sort -k1 -nr | head -10
            echo '```'
            echo ""
            echo "## Audio Contexts"
            echo '```'
            pmset -g assertions 2>/dev/null | grep -c "coreaudiod.*preventuseridlesleep"
            echo '```'
            echo ""
            echo "## Reports Folder"
            echo '```'
            ls -la "$HOME/.battopt-swiftbar/reports/" 2>/dev/null
            echo '```'
        } > "$BUNDLE"
        
        log "logs_ai_bundle: $BUNDLE"
        notify "BattOpt" "AI Bundle ready: $(basename "$BUNDLE")"
        open -R "$BUNDLE"
        release
        ;;

    logs_actions)
        open -e "$HOME/.battopt-swiftbar/actions.log"
        ;;

    logs_sailing)
        open -e "$HOME/.battopt-swiftbar/.sailing_history"
        ;;

    logs_arm)
        open -e "$HOME/.battopt-swiftbar/.arm_log"
        ;;

    logs_daemon)
        open "$HOME/Library/Logs/battopt" 2>/dev/null || open "/Library/Logs/battopt"
        ;;

    logs_reports)
        open "$HOME/.battopt-swiftbar/reports"
        ;;

        power_mode_fast)
        acquire
        ~/.battopt-swiftbar/power_mode.sh fast
        notify "BattOpt" "Power Mode: Fast Sleep"
        release
        ;;

    power_mode_balanced)
        acquire
        ~/.battopt-swiftbar/power_mode.sh balanced
        notify "BattOpt" "Power Mode: Balanced"
        release
        ;;

    power_mode_awake)
        acquire
        ~/.battopt-swiftbar/power_mode.sh awake
        notify "BattOpt" "Power Mode: Always Awake"
        release
        ;;

    power_mode_deep)
        acquire
        ~/.battopt-swiftbar/power_mode.sh deep
        notify "BattOpt" "Power Mode: Deep Only"
        release
        ;;

        project_health)
        acquire
        ~/.battopt-swiftbar/project_health.sh > /dev/null 2>&1
        sleep 1
        PASS_LINE=$(grep "PASS:" /tmp/battopt_health_latest.txt | tail -1)
        STATUS_LINE=$(grep -E "Project is" /tmp/battopt_health_latest.txt | head -1)
        TEMP=$(sudo -n battopt status 2>/dev/null | grep -oE "[0-9.]+.C" | head -1)
        LOAD=$(sysctl -n vm.loadavg | awk '{print $2}')
        BUTTON=$(osascript << 'AS'
display dialog "BattOpt Health Check

${PASS_LINE}
${STATUS_LINE}

Temperature: ${TEMP}
Load: ${LOAD}

Full report: /tmp/battopt_health_latest.txt" buttons {"Close", "Open Report"} default button "Close" with title "BattOpt Diagnostics" with icon note
return button returned of result
AS
)
        [ "$BUTTON" = "Open Report" ] && /usr/bin/open -e /tmp/battopt_health_latest.txt
        release
        ;;

    conflict_check)
        acquire
        ~/.battopt-swiftbar/conflict_check.sh > /tmp/battopt_conflicts_latest.txt 2>&1
        BUTTON=$(osascript <<'AS'
try
    set dialogResult to display dialog "Conflict Detection

Report saved to:
/tmp/battopt_conflicts_latest.txt" buttons {"Close", "Open"} default button "Close" with title "BattOpt Conflicts" with icon note
    return button returned of dialogResult
on error
    return "Close"
end try
AS
)
        [ "$BUTTON" = "Open" ] && /usr/bin/open -e /tmp/battopt_conflicts_latest.txt
        release
        ;;

    predictive)
        acquire
        ~/.battopt-swiftbar/predictive.sh
        notify "BattOpt" "Predictive analysis complete"
        release
        ;;

    process_monitor)
        acquire
        ~/.battopt-swiftbar/process_monitor.sh
        notify "BattOpt" "Process monitor done"
        release
        ;;




    power_mode_custom)
        acquire
        S=$(osascript << AS
try
    set msg to "STEP 1 of 2 — Sleep Timer

How many minutes of inactivity before your Mac enters Sleep?

  • 0   = Never sleep (Mac stays awake always)
  • 5   = Aggressive battery saving
  • 18  = Balanced (macOS default)
  • 60  = Keep awake for an hour

Recommended for daily use: 18"
    set d to display dialog msg default answer "$(get_last_input PM_SLEEP 18)" buttons {"Cancel", "Next"} default button "Next" with title "Power Mode — Custom"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$S" = "__CANCELLED__" ] && { release; exit 0; }
        save_last_input PM_SLEEP "$S"
        
        SD=$(osascript << AS
try
    set msg to "STEP 2 of 2 — Standby Delay

After entering Sleep, how many SECONDS should RAM stay powered
before it is written to Disk (Standby)?

  • 0    = Immediate (RAM → Disk instantly, saves power)
  • 300  = 5 minutes
  • 900  = 15 minutes (recommended)
  • 4200 = 70 minutes (macOS default, wastes power)

Recommended for battery saving: 900"
    set d to display dialog msg default answer "$(get_last_input PM_SB_DELAY 900)" buttons {"Cancel", "OK"} default button "OK" with title "Power Mode — Custom"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$SD" = "__CANCELLED__" ] && { release; exit 0; }
        save_last_input PM_SB_DELAY "$SD"
        ~/.battopt-swiftbar/power_mode.sh custom "$S" "$SD"
        notify "BattOpt" "Custom Power Mode: sleep=$S min, standby=$SD sec"
        release
        ;;

    esac
