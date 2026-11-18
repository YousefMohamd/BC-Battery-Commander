#!/bin/bash
# Self-Healing Daemon — runs every 5 min
# Detects and fixes common issues

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
# The state dir must exist before any log/state write below (audit
# 2026-11-11, W28 — a missing dir made every heal silently fail).
mkdir -p "$DASH" 2>/dev/null || true
LOG="$DASH/actions.log"
HEAL_LOG="$DASH/.healing.log"

log() { echo "[$(date '+%H:%M:%S')] heal: $1" >> "$HEAL_LOG"; }

# S5: Hard early exit - never undo a user-intended shutdown
if [ -f "$DASH/.user_shutdown" ]; then
    log "shutdown flag present - exiting"
    exit 0
fi

# 1-3. (RETIRED 2026-11-17 - morning cleanup) The SwiftBar relaunch,
# plugin-restore, and DisabledPlugins sections were removed: the
# SwiftBar plugin was retired at Stage C and the native app is the
# only UI. SwiftBar stays closed by owner order - this script must
# never relaunch it or resurrect the plugin.

# 4. Stale .disabled/.paused?
[ -f "$DASH/.disabled" ] && {
    log "Removing stale .disabled"
    rm -f "$DASH/.disabled"
}
[ -f "$DASH/.paused" ] && [ ! -f "$DASH/.user_shutdown" ] && {
    log "Removing stale .paused"
    rm -f "$DASH/.paused"
}

# 5. (deleted in BC) There is no battopt daemon to restart. The
# enforcer (bc-limit LaunchDaemon) is owned by the watchdog (L8)
# and the launcher — this script must not start daemons.

# 6. (deleted in BC) Drift re-apply belonged to the old stack and
# is now owned by the watchdog (single drift-corrector rule, W3).
# This script must not write limits or call bc-limit.

# 7. Trim healing log
if [ -f "$HEAL_LOG" ]; then
    SIZE=$(wc -c < "$HEAL_LOG" | tr -d ' ')
    [ "$SIZE" -gt 51200 ] && tail -100 "$HEAL_LOG" > "$HEAL_LOG.tmp" && mv "$HEAL_LOG.tmp" "$HEAL_LOG"
fi


# Auto-revert to default if AC-dependent mode active while on battery
SM_STATE=$(cat "$DASH/.sleep_mode" 2>/dev/null || echo "default")
if [ "$SM_STATE" = "presentation" ] || [ "$SM_STATE" = "download" ]; then
    if ! pmset -g batt 2>/dev/null | grep -q "AC Power"; then
        rm -f "$DASH/.sleep_override_ac"
        rm -f "$DASH/.sleep_override_lid"
        sudo -n /usr/bin/pmset -a disablesleep 0
        printf "%s\n" "default" > "$DASH/.sleep_mode.tmp.$$" && mv "$DASH/.sleep_mode.tmp.$$" "$DASH/.sleep_mode"
        log "heal: sleep_mode auto-reverted to default (AC lost)"
    fi
fi


# Validate .sleep_mode value
VALID_MODES="default presentation download travel long"
CURRENT_MODE=$(cat "$DASH/.sleep_mode" 2>/dev/null || echo "default")
if ! echo "$VALID_MODES" | grep -qw "$CURRENT_MODE"; then
    log "Corrupted .sleep_mode='$CURRENT_MODE' — resetting to default"
    printf "%s\n" "default" > "$DASH/.sleep_mode.tmp.$$" && mv "$DASH/.sleep_mode.tmp.$$" "$DASH/.sleep_mode"
    # Reset pmset to defaults
    sudo -n /usr/bin/pmset -a disablesleep 0
    # Canonical default delays (W4.3: 600/600/1800) — the old 900/900/900
    # matched no BC profile.
    sudo -n /usr/bin/pmset -b standbydelaylow 600
    sudo -n /usr/bin/pmset -b standbydelayhigh 600
    sudo -n /usr/bin/pmset -b autopoweroffdelay 1800
    sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null
fi


# Watchdog — if mode says download but disablesleep is off
if [ "$CURRENT_MODE" = "download" ] || [ "$CURRENT_MODE" = "presentation" ]; then
    if [ "$(pmset -g | awk '/SleepDisabled/{print $2}')" != "1" ]; then
        log "Mode=$CURRENT_MODE but disablesleep=0 — reverting to default"
        printf "%s\n" "default" > "$DASH/.sleep_mode.tmp.$$" && mv "$DASH/.sleep_mode.tmp.$$" "$DASH/.sleep_mode"
        sudo -n /usr/bin/pmset -c sleep 120
        sudo -n /usr/bin/pmset -c displaysleep 20
    fi
fi


# === ZOMBIE KILLER ===
# Kill stuck arm_sleep processes older than 60s. (The old second
# loop killed stuck external-notifier processes; notifications
# are app-native since the 2026-11-18 cleanup, so no notifier
# process exists to go zombie — the loop is retired.)
for pid in $(pgrep -f "arm_sleep.sh" 2>/dev/null); do
    AGE=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
    # etime format: MM:SS or HH:MM:SS
    if [ -n "$AGE" ]; then
        SEC=$(echo "$AGE" | awk -F: '{if (NF==2) print $1*60+$2; else if (NF==3) print $1*3600+$2*60+$3; else print 0}')
        if [ "$SEC" -gt 60 ] 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
            log "zombie: killed arm_sleep $pid (age ${SEC}s)"
        fi
    fi
done

# === END ZOMBIE KILLER ===




# === LAYER 7: Config Validator ===
# Validates all state files for corruption; fixes safe cases; alerts on hard cases.
validate_config() {
    local issues=0
    local cfg_invalid=0
    
    # 1. .sleep_mode must be one of known values
    local sm
    sm=$(cat "$DASH/.sleep_mode" 2>/dev/null || echo "")
    case "$sm" in
        default|presentation|download|travel|long|"") ;;
        *) log "L7: .sleep_mode corrupt ('$sm') → reset"
           printf "%s\n" "default" > "$DASH/.sleep_mode.tmp.$$" && mv "$DASH/.sleep_mode.tmp.$$" "$DASH/.sleep_mode"
           issues=$((issues+1)) ;;
    esac
    
    # 2. .current_power_mode must be one of known values
    local pm
    pm=$(cat "$DASH/.current_power_mode" 2>/dev/null || echo "")
    case "$pm" in
        fast|balanced|awake|deep|custom|"") ;;
        *) log "L7: .current_power_mode corrupt ('$pm') → reset"
           printf "%s\n" "balanced" > "$DASH/.current_power_mode.tmp.$$" && mv "$DASH/.current_power_mode.tmp.$$" "$DASH/.current_power_mode"
           issues=$((issues+1)) ;;
    esac
    
    # 3. config file must exist and define LAST_UPPER/LAST_LOWER
    if [ -f "$DASH/config" ]; then
        if ! grep -q '^LAST_UPPER=' "$DASH/config"; then
            log "L7: config missing LAST_UPPER → recreating"
            printf "LAST_UPPER=86\nLAST_LOWER=85\nSAILING=false\nSAIL_GAP=1\n" > "$DASH/.config.tmp.$$" && mv "$DASH/.config.tmp.$$" "$DASH/config"
            issues=$((issues+1))
        elif ! grep -q '^LAST_LOWER=' "$DASH/config"; then
            log "L7: config missing LAST_LOWER → recreating"
            printf "LAST_UPPER=86\nLAST_LOWER=85\nSAILING=false\nSAIL_GAP=1\n" > "$DASH/.config.tmp.$$" && mv "$DASH/.config.tmp.$$" "$DASH/config"
            issues=$((issues+1))
        fi
    else
        log "L7: config missing entirely → recreating"
        printf "LAST_UPPER=86\nLAST_LOWER=85\nSAILING=false\nSAIL_GAP=1\n" > "$DASH/.config.tmp.$$" && mv "$DASH/.config.tmp.$$" "$DASH/config"
        issues=$((issues+1))
    fi

    # 3b. config VALUES must be in the canonical ranges (M7/m9 parity,
    # consolidation 2026-11-13): LAST_UPPER 15-100, LAST_LOWER 15-99,
    # upper > lower, SAILING in {true,false}, SAIL_GAP numeric 1-30.
    # An invalid value is logged LOUDLY with its key/value and counted
    # unhealthy below — it is NEVER silently rewritten to defaults here.
    if [ -f "$DASH/config" ]; then
        local _cu _cl _cs _cg
        _cu=$(grep '^LAST_UPPER=' "$DASH/config" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
        _cl=$(grep '^LAST_LOWER=' "$DASH/config" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
        _cs=$(grep '^SAILING=' "$DASH/config" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
        _cg=$(grep '^SAIL_GAP=' "$DASH/config" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
        case "$_cu" in
            ''|*[!0-9]*) log "L7: config INVALID: LAST_UPPER='$_cu' (not numeric) - NOT auto-rewritten"; cfg_invalid=$((cfg_invalid+1)) ;;
            *) if [ "$_cu" -lt 15 ] || [ "$_cu" -gt 100 ]; then log "L7: config INVALID: LAST_UPPER='$_cu' (must be 15-100) - NOT auto-rewritten"; cfg_invalid=$((cfg_invalid+1)); fi ;;
        esac
        case "$_cl" in
            ''|*[!0-9]*) log "L7: config INVALID: LAST_LOWER='$_cl' (not numeric) - NOT auto-rewritten"; cfg_invalid=$((cfg_invalid+1)) ;;
            *) if [ "$_cl" -lt 15 ] || [ "$_cl" -gt 99 ]; then log "L7: config INVALID: LAST_LOWER='$_cl' (must be 15-99) - NOT auto-rewritten"; cfg_invalid=$((cfg_invalid+1)); fi ;;
        esac
        case "$_cu$_cl" in *[!0-9]*|'') ;; *)
            if [ "$_cu" -le "$_cl" ]; then log "L7: config INVALID: LAST_UPPER='$_cu' <= LAST_LOWER='$_cl' (upper must be > lower) - NOT auto-rewritten"; cfg_invalid=$((cfg_invalid+1)); fi ;;
        esac
        case "$_cs" in
            true|false) ;;
            *) log "L7: config INVALID: SAILING='$_cs' (must be true or false) - NOT auto-rewritten"; cfg_invalid=$((cfg_invalid+1)) ;;
        esac
        case "$_cg" in
            ''|*[!0-9]*) log "L7: config INVALID: SAIL_GAP='$_cg' (not numeric) - NOT auto-rewritten"; cfg_invalid=$((cfg_invalid+1)) ;;
            *) if [ "$_cg" -lt 1 ] || [ "$_cg" -gt 30 ]; then log "L7: config INVALID: SAIL_GAP='$_cg' (must be 1-30) - NOT auto-rewritten"; cfg_invalid=$((cfg_invalid+1)); fi ;;
        esac
    fi
    
    # 4. Last update of critical dirs — enforce existence
    for d in reports predictive_data backups; do
        [ ! -d "$DASH/$d" ] && {
            mkdir -p "$DASH/$d"
            log "L7: created missing dir $d"
            issues=$((issues+1))
        }
    done
    
    # 5. Log result
    if [ "$issues" -gt 0 ]; then
        log "L7: auto-fixed $issues config issues"
    fi
    if [ "$cfg_invalid" -gt 0 ]; then
        log "L7: config validation FAILED - $cfg_invalid invalid value(s) left untouched (see above); config is NOT healthy"
    fi
}

validate_config
# === END LAYER 7 ===
exit 0
