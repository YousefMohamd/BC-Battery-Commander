#!/bin/bash

DASH="$HOME/.battopt-swiftbar"
BAT="/usr/local/bin/battopt"
LOG="$DASH/actions.log"
LOCK="$DASH/.op.lock"
CFG="$DASH/config"
FORCE="$DASH/force_reset.sh"

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

kill_charge()    { log "kill_charge";    sudo pkill -9 -f "battopt charge " 2>/dev/null; sleep 0.5; }
kill_discharge() { log "kill_discharge"; sudo pkill -9 -f "battopt discharge" 2>/dev/null; sudo -n "$BAT" discharge stop >/dev/null 2>&1; sleep 0.5; }
kill_calibrate() { log "kill_calibrate"; sudo pkill -9 -f "battopt calibrate" 2>/dev/null; sudo -n "$BAT" calibrate stop >/dev/null 2>&1; sleep 0.5; }


# === CACHE INVALIDATION ===
clear_cache() {
    rm -f "$HOME/.battopt-swiftbar/.status_cache"
}

# === SWIFTBAR REFRESH HOOK ===
# Trigger SwiftBar to re-run the plugin immediately after any dispatch action.
# Falls back silently if SwiftBar isn't running or URL scheme unsupported.
refresh_swiftbar() {
    /usr/bin/open -g "swiftbar://refreshplugin?name=battopt.10s" >/dev/null 2>&1 || true
}

# === INTENT APPLY (v1.6.2) — atomic battery mutations ===

_kill_transients() {
    sudo pkill -9 -f "battopt charge"    2>/dev/null || true
    sudo pkill -9 -f "battopt discharge" 2>/dev/null || true
    sudo pkill -9 -f "battopt calibrate" 2>/dev/null || true
    sudo pkill -9 -f "sd_watcher.sh"     2>/dev/null || true
    sudo pkill -9 -f "charge_full"       2>/dev/null || true
    sudo -n "$BAT" charge stop    >/dev/null 2>&1 || true
    sudo -n "$BAT" discharge stop >/dev/null 2>&1 || true
    sudo -n "$BAT" calibrate stop >/dev/null 2>&1 || true
}

_clear_session_locked() {
    guard_token_clear_locked || return 1
    rm -f "$HOME/.battopt-swiftbar/.sd_session"
    rm -f "$HOME/.battopt-swiftbar/.hold_override"
    rm -f "$HOME/.battopt-swiftbar/.hold_token"
    rm -f "$HOME/.battopt-swiftbar/.pre_hold_config"
}

_verify_smc_upper() {
    sudo -n "$BAT" status 2>/dev/null \
        | grep -oE 'upper limit [0-9]+' \
        | grep -oE '[0-9]+' \
        | head -1
}

intent_apply() {
    local kind="$1"; shift
    local U L T CUR V MODE GAP TOKEN
    local D="$DASH"

    guard_lock || { log "intent_apply: lock failed ($kind)"; return 1; }

    _kill_transients
    sleep 1
    _clear_session_locked || {
        log "intent_apply: clear session failed ($kind)"
        guard_unlock
        return 1
    }

    case "$kind" in
        limit)
            U="$1"; L="$2"; MODE="$3"; GAP="$4"
            CUR=$(get_pct)
            # Respect caller-provided MODE; fallback for backward compat
            if [ "$MODE" = "Hold" ]; then
                SAILING=false
                SAIL_GAP=1
            elif [ "$MODE" = "Sail" ] || [ "$MODE" = "Sailing" ]; then
                SAILING=true
                [ -n "$GAP" ] && SAIL_GAP="$GAP"
                validate_int "$SAIL_GAP" 5 30 2>/dev/null || SAIL_GAP=10
            else
                # backward compat: no MODE passed → keep legacy behavior
                SAILING=true
                SAIL_GAP=$((U - L))
                [ "$SAIL_GAP" -lt 1 ] && SAIL_GAP=1
            fi
            LAST_UPPER="$U"
            LAST_LOWER="$L"
            save_cfg
            # Discharge path if battery above target
            if [ -n "$CUR" ] && [ "$CUR" -gt "$U" ]; then
                echo "discharge" > "$D/.active_mode"
                TOKEN=$(guard_token_write_locked discharge) || { guard_unlock; return 1; }
                printf '%s\n' "$TOKEN" > "$D/.sd_session"
                nohup "$D/sd_watcher.sh" "$TOKEN" "$U" "$L" "$D/.sd_session" "$LOG" "$BAT" >/dev/null 2>&1 &
                disown
                nohup sudo -n "$BAT" discharge "$U" >/dev/null 2>&1 &
                disown
                guard_unlock
                notify "BattOpt" "Discharging ${CUR}% → ${U}%"
                return 0
            fi
            # Hold/charge path
            echo "hold" > "$D/.active_mode"
            guard_token_write_locked hold >/dev/null || { guard_unlock; return 1; }
            run_with_retry limit "$U" "$L" >> "$LOG" 2>&1
            V=$(_verify_smc_upper)
            if [ "$V" != "$U" ]; then
                log "intent_apply: limit retry (SMC=$V want=$U)"
                sleep 2
                run_with_retry limit "$U" "$L" >> "$LOG" 2>&1
                V=$(_verify_smc_upper)
            fi
            guard_token_clear_locked
            echo "idle" > "$D/.active_mode"
            guard_unlock
            if [ "$V" = "$U" ]; then
                notify "BattOpt" "Limit set ${V}% / ${L}%"
                return 0
            fi
            log "intent_apply: limit failed (SMC=$V want=$U)"
            notify "BattOpt" "Limit failed (SMC=$V)"
            return 1
            ;;

        hold_current)
            CUR=$(get_pct)
            [ -n "$CUR" ] || {
                guard_unlock
                notify "BattOpt" "Hold failed (no battery reading)"
                return 1
            }
            U="$CUR"
            L=$((CUR - 1))
            [ "$L" -lt 20 ] && L=20
            [ "$L" -ge "$U" ] && L=$((U - 1))
            echo "hold" > "$D/.active_mode"
            guard_token_write_locked hold >/dev/null || { guard_unlock; return 1; }
            run_with_retry limit "$U" "$L" >> "$LOG" 2>&1
            V=$(_verify_smc_upper)
            if [ "$V" != "$U" ]; then
                sleep 2
                run_with_retry limit "$U" "$L" >> "$LOG" 2>&1
                V=$(_verify_smc_upper)
            fi
            guard_token_clear_locked
            echo "idle" > "$D/.active_mode"
            guard_unlock
            if [ "$V" = "$U" ]; then
                notify "BattOpt" "Holding at ${V}%"
                return 0
            fi
            log "intent_apply: hold_current failed (SMC=$V want=$U)"
            notify "BattOpt" "Hold failed (SMC=$V)"
            return 1
            ;;

        sail_on|sail_off|sail_gap)
            case "$kind" in
                sail_on)
                    SAILING=true
                    [ "$LAST_LOWER" -ge "$LAST_UPPER" ] && LAST_LOWER=$((LAST_UPPER - 5))
                    [ "$LAST_LOWER" -lt 20 ] && LAST_LOWER=20
                    ;;
                sail_off)
                    SAILING=false
                    ;;
                sail_gap)
                    GAP="$1"
                    SAIL_GAP="$GAP"
                    if [ "$SAILING" = "true" ]; then
                        LAST_LOWER=$((LAST_UPPER - GAP))
                        [ "$LAST_LOWER" -lt 20 ] && LAST_LOWER=20
                    fi
                    ;;
            esac
            save_cfg
            echo "hold" > "$D/.active_mode"
            guard_token_write_locked hold >/dev/null || { guard_unlock; return 1; }
            run_with_retry limit "$LAST_UPPER" "$LAST_LOWER" >> "$LOG" 2>&1
            V=$(_verify_smc_upper)
            if [ "$V" != "$LAST_UPPER" ]; then
                sleep 2
                run_with_retry limit "$LAST_UPPER" "$LAST_LOWER" >> "$LOG" 2>&1
                V=$(_verify_smc_upper)
            fi
            guard_token_clear_locked
            echo "idle" > "$D/.active_mode"
            guard_unlock
            if [ "$V" = "$LAST_UPPER" ]; then
                notify "BattOpt" "$kind applied (SMC=$V)"
                return 0
            fi
            log "intent_apply: $kind failed (SMC=$V want=$LAST_UPPER)"
            notify "BattOpt" "$kind failed (SMC=$V)"
            return 1
            ;;

        disable_limit)
            U=100; L=99
            run_with_retry limit "$U" "$L" >> "$LOG" 2>&1
            V=$(_verify_smc_upper)
            if [ "$V" != "$U" ]; then
                sleep 2
                run_with_retry limit "$U" "$L" >> "$LOG" 2>&1
                V=$(_verify_smc_upper)
            fi
            if [ "$V" = "$U" ]; then
                LAST_UPPER=100
                LAST_LOWER=99
                SAILING=false
                SAIL_GAP=1
                save_cfg
            fi
            guard_token_clear_locked
            echo "idle" > "$D/.active_mode"
            guard_unlock
            if [ "$V" = "$U" ]; then
                notify "BattOpt" "Limits disabled (SMC=$V)"
                return 0
            fi
            log "intent_apply: disable_limit failed (SMC=$V)"
            notify "BattOpt" "Disable failed (SMC=$V)"
            return 1
            ;;

        charge_full)
            echo "charge_full" > "$D/.active_mode"
            TOKEN=$(guard_token_write_locked charge_full) || {
                echo "idle" > "$D/.active_mode"
                guard_unlock
                return 1
            }
            run_with_retry limit 100 99 >> "$LOG" 2>&1
            V=$(_verify_smc_upper)
            if [ "$V" != 100 ]; then
                sleep 2
                run_with_retry limit 100 99 >> "$LOG" 2>&1
                V=$(_verify_smc_upper)
            fi
            if [ "$V" != 100 ]; then
                guard_token_clear_locked
                echo "idle" > "$D/.active_mode"
                guard_unlock
                notify "BattOpt" "Charge Full failed (SMC=$V)"
                return 1
            fi
            nohup sudo -n "$BAT" charge 100 >/dev/null 2>&1 &
            disown
            nohup bash -c '
                B="$1"; D="$2"; L="$3"; T="$4"
                source "$D/state_guard.sh" 2>/dev/null
                P=0
                for i in $(seq 1 720); do
                    sleep 10
                    P=$(sudo -n "$B" status 2>/dev/null | grep -oE "Capacity [0-9]+" | grep -oE "[0-9]+" | head -1)
                    [ -n "$P" ] && [ "$P" -ge 99 ] && break
                done
                if [ -n "$P" ] && [ "$P" -ge 99 ] && guard_token_matches "$T" 2>/dev/null; then
                    sudo -n "$B" charge stop >/dev/null 2>&1
                    sudo -n "$B" limit 99 98 >/dev/null 2>&1
                    printf "LAST_UPPER=99\nLAST_LOWER=98\nSAILING=false\nSAIL_GAP=1\n" > "$D/config.tmp.$$" && mv "$D/config.tmp.$$" "$D/config"
                else
                    sudo -n "$B" charge stop >/dev/null 2>&1
                fi
                guard_session_end "$T" 2>/dev/null
                echo "[$(date +%H:%M:%S)] charge_full: watcher finished" >> "$L"
            ' _ "$BAT" "$D" "$LOG" "$TOKEN" >/dev/null 2>&1 &
            disown
            guard_unlock
            notify "BattOpt" "Charging to 100%"
            return 0
            ;;

        smart_discharge)
            T="$1"; L="$2"; MODE="$3"; GAP="$4"
            CUR=$(get_pct)
            if [ -z "$CUR" ] || [ "$CUR" -le "$T" ]; then
                guard_unlock
                notify "BattOpt" "Discharge not started (CUR=$CUR, T=$T)"
                return 1
            fi
            LAST_UPPER="$T"
            LAST_LOWER="$L"
            SAILING=false
            SAIL_GAP=0
            if [ "$MODE" = "Sail" ]; then
                SAILING=true
                SAIL_GAP="$GAP"
            fi
            save_cfg
            echo "discharge" > "$D/.active_mode"
            TOKEN=$(guard_token_write_locked discharge) || {
                echo "idle" > "$D/.active_mode"
                guard_unlock
                return 1
            }
            printf '%s\n' "$TOKEN" > "$D/.sd_session"
            nohup "$D/sd_watcher.sh" "$TOKEN" "$T" "$L" "$D/.sd_session" "$LOG" "$BAT" >/dev/null 2>&1 &
            disown
            nohup sudo -n "$BAT" discharge "$T" >/dev/null 2>&1 &
            disown
            guard_unlock
            notify "BattOpt" "Discharging ${CUR}% to ${T}%"
            return 0
            ;;

        calibration_start)
            echo "calibration" > "$D/.active_mode"
            TOKEN=$(guard_token_write_locked calibration) || {
                echo "idle" > "$D/.active_mode"
                guard_unlock
                return 1
            }
            nohup sudo -n "$BAT" calibrate >/dev/null 2>&1 &
            disown
            guard_unlock
            notify "BattOpt" "Calibration started"
            return 0
            ;;

        calibration_stop)
            kill_calibrate
            guard_token_clear_locked
            echo "idle" > "$D/.active_mode"
            guard_unlock
            notify "BattOpt" "Calibration stopped"
            return 0
            ;;

        *)
            log "intent_apply: unknown kind ($kind)"
            guard_unlock
            return 1
            ;;
    esac
}

# === END INTENT APPLY ===

# Fire refresh on exit (normal + error paths)
trap "sleep 1; refresh_swiftbar" EXIT

case "$1" in
    force_reset) "$FORCE" ;;
    
    sleep_mode_default)
        acquire
        rm -f "$HOME/.battopt-swiftbar/.sleep_override_ac"
        rm -f "$HOME/.battopt-swiftbar/.sleep_override_lid"
        rm -f "$HOME/.battopt-swiftbar/.sleep_override_batt"
        sudo -n /usr/bin/pmset -a disablesleep 0
        # Battery defaults
        ~/.battopt-swiftbar/power_saver.sh enforce-sleep-policy
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
        ~/.battopt-swiftbar/power_saver.sh apply-delays travel
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
        release
        intent_apply hold_current ;;

    remove_limit_hold)
        acquire; ensure_clean
        release
        intent_apply hold_current ;;

    disable_limit)
        acquire; ensure_clean
        log "disable all"
        release
        intent_apply disable_limit ;;

    charge_full)
        acquire; ensure_clean
        log "charge_full: START"
        release
        intent_apply charge_full ;;


    smart_discharge)
        acquire; ensure_clean
        CUR=$(get_pct); [ -z "$CUR" ] && { release; exit 1; }

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
            GAP=$(get_last_input SD_SAIL_GAP "$SAIL_GAP")
            validate_int "$GAP" 5 30 || GAP=10
            LOW=$((T - GAP))
            if [ "$LOW" -lt 20 ]; then
                LOW=20
            fi
        else
            GAP=0
            LOW=$((T - 1))
            if [ "$LOW" -lt 20 ]; then
                LOW=20
            fi
        fi

        release
        intent_apply smart_discharge "$T" "$LOW" "$MODE" "$GAP"
        ;;

    limit_custom)
        acquire; ensure_clean
        CUR=$(get_pct)
        DEF=$(get_last_input LIMIT_CUSTOM "")
        [ -z "$DEF" ] && DEF="${LAST_UPPER}/${LAST_LOWER}"

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

        # === STEP 2: Mode ===
        MODE=$(osascript <<AS
try
    set d to display dialog "Mode after reaching limit

After reaching ${U}%:
Hold = freeze at ${U}% only
Sailing = oscillate between ${U}% and (${U} - gap)%" buttons {"Cancel","Hold","Sailing"} default button "Sailing" with title "BattOpt"
    return button returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$MODE" = "__CANCELLED__" ] && { release; exit 0; }
        [ "$MODE" = "Cancel" ] && { release; exit 0; }

        GAP=10
        if [ "$MODE" = "Sailing" ]; then
            GSEL=$(osascript <<AS
try
    set opts to {"5","10","15","30","Custom"}
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
            [ "$GSEL" = "__CANCELLED__" ] && { release; exit 0; }
            if [ "$GSEL" = "Custom" ]; then
                GSEL=$(osascript <<AS
try
    set d to display dialog "Custom sail gap (5-30):" default answer "$(get_last_input SAIL_GAP_CUSTOM 10)" buttons {"Cancel", "OK"} default button "OK" with title "BattOpt"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
                [ "$GSEL" = "__CANCELLED__" ] && { release; exit 0; }
                validate_int "$GSEL" 5 30 || { notify "BattOpt" "Invalid gap (5-30)"; release; exit 0; }
                save_last_input SAIL_GAP_CUSTOM "$GSEL"
            fi
            validate_int "$GSEL" 5 30 || { notify "BattOpt" "Invalid gap"; release; exit 0; }
            GAP="$GSEL"
            save_last_input SD_SAIL_GAP "$GAP"
        fi

        save_last_input LIMIT_CUSTOM "$U/$L"

        # Update config BEFORE intent_apply
        if [ "$MODE" = "Hold" ]; then
            SAILING=false; SAIL_GAP=1
            LAST_LOWER=$((U - 1)); [ "$LAST_LOWER" -lt 20 ] && LAST_LOWER=20
        else
            SAILING=true; SAIL_GAP="$GAP"
            LAST_LOWER=$((U - GAP)); [ "$LAST_LOWER" -lt 20 ] && LAST_LOWER=20
        fi
        LAST_UPPER="$U"
        save_cfg
        release
        intent_apply limit "$U" "$LAST_LOWER" "$MODE" "$GAP" ;;

    sail_on)
        acquire; ensure_clean
        release
        intent_apply sail_on ;;

    sail_off)
        acquire; ensure_clean
        release
        intent_apply sail_off ;;

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
        release
        intent_apply sail_gap "$G" ;;

    calibrate)
        acquire; ensure_clean
        log "calibrate"
        release
        intent_apply calibration_start ;;

    cal_stop) acquire; log "cal_stop"; release; intent_apply calibration_stop ;;

    sched_on)  log "sched_on";  sudo -n "$BAT" schedule enable  >> "$LOG" 2>&1 ;;
    sched_off) log "sched_off"; sudo -n "$BAT" schedule disable >> "$LOG" 2>&1 ;;
    clam0) sudo -n "$BAT" clamshell 0 >> "$LOG" 2>&1 ;;
    clam1) sudo -n "$BAT" clamshell 1 >> "$LOG" 2>&1 ;;
    clam2) sudo -n "$BAT" clamshell 2 >> "$LOG" 2>&1 ;;

    shutdown)
        acquire
        if [ "$2" != "--force" ]; then
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
        fi
        log "shutdown: START"
        START_TS=$(date +%s)

        SESSION_MODE=$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')
        [ -z "$SESSION_MODE" ] && SESSION_MODE="idle"

        atomic_write "$DASH/.last_session_mode" "LAST_UPPER=$LAST_UPPER
LAST_LOWER=$LAST_LOWER
ACTIVE_MODE=$SESSION_MODE
"

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
        BUTTON=$(osascript << 'AS'
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
