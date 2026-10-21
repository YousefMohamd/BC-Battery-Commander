#!/bin/bash
# Self-Healing Daemon — runs every 5 min
# Detects and fixes common issues

LOG="$HOME/.battopt-swiftbar/actions.log"
HEAL_LOG="$HOME/.battopt-swiftbar/.healing.log"

log() { echo "[$(date '+%H:%M:%S')] heal: $1" >> "$HEAL_LOG"; }

# 1. SwiftBar running?
if ! pgrep -x SwiftBar >/dev/null 2>&1; then
    log "SwiftBar down — relaunching"
    ~/.battopt-swiftbar/launch_swiftbar.sh
fi

# 2. Plugin in correct place?
if [ ! -f "$HOME/SwiftBar/battopt.10s.sh" ]; then
    # Check if it's in disabled
    if [ -f "$HOME/.battopt-swiftbar/disabled/battopt.10s.sh" ]; then
        # Only restore if user didn't explicitly shut down
        if [ ! -f "$HOME/.battopt-swiftbar/.user_shutdown" ]; then
            mkdir -p "$HOME/SwiftBar"
            mv "$HOME/.battopt-swiftbar/disabled/battopt.10s.sh" "$HOME/SwiftBar/"
            chmod +x "$HOME/SwiftBar/battopt.10s.sh"
            log "Plugin restored from disabled/"
        fi
    fi
fi

# 3. DisabledPlugins cleared?
DIS=$(defaults read com.ameba.SwiftBar DisabledPlugins 2>/dev/null | grep -c "battopt" 2>/dev/null | head -1 | tr -d ' \n')
DIS=${DIS:-0}
[ -z "$DIS" ] && DIS=0
if [ "$DIS" -gt 0 ] 2>/dev/null; then
    log "SwiftBar DisabledPlugins — clearing"
    defaults delete com.ameba.SwiftBar DisabledPlugins 2>/dev/null
    touch "$HOME/SwiftBar/battopt.10s.sh" 2>/dev/null
fi

# 4. Stale .disabled/.paused?
[ -f "$HOME/.battopt-swiftbar/.disabled" ] && {
    log "Removing stale .disabled"
    rm -f "$HOME/.battopt-swiftbar/.disabled"
}
[ -f "$HOME/.battopt-swiftbar/.paused" ] && [ ! -f "$HOME/.battopt-swiftbar/.user_shutdown" ] && {
    log "Removing stale .paused"
    rm -f "$HOME/.battopt-swiftbar/.paused"
}

# 5. Daemon running?
if [ ! -f "$HOME/.battopt-swiftbar/.user_shutdown" ]; then
    if ! pgrep -f "battopt daemon" >/dev/null 2>&1; then
        log "Daemon down — starting"
        sudo -n /usr/local/bin/battopt-daemon-start 2>/dev/null
    fi
fi

# 6. Limit applied?
STATUS=$(sudo -n battopt status 2>/dev/null)
if echo "$STATUS" | grep -q "Capacity"; then
    if echo "$STATUS" | grep -qE "Charge limit is suspended|Charge limit: disabled|Active Limit: disabled" || ! echo "$STATUS" | grep -qE "upper limit 8[0-9]"; then
        source "$HOME/.battopt-swiftbar/config" 2>/dev/null
        log "Limit missing — reapplying ${LAST_UPPER:-85}/${LAST_LOWER:-80}"
        sudo -n /usr/local/bin/battopt limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
    fi
fi

# 7. Trim healing log
if [ -f "$HEAL_LOG" ]; then
    SIZE=$(wc -c < "$HEAL_LOG" | tr -d ' ')
    [ "$SIZE" -gt 51200 ] && tail -100 "$HEAL_LOG" > "$HEAL_LOG.tmp" && mv "$HEAL_LOG.tmp" "$HEAL_LOG"
fi


# Auto-revert to default if AC-dependent mode active while on battery
SM_STATE=$(cat "$HOME/.battopt-swiftbar/.sleep_mode" 2>/dev/null || echo "default")
if [ "$SM_STATE" = "presentation" ] || [ "$SM_STATE" = "download" ]; then
    if ! pmset -g batt 2>/dev/null | grep -q "AC Power"; then
        rm -f "$HOME/.battopt-swiftbar/.sleep_override_ac"
        rm -f "$HOME/.battopt-swiftbar/.sleep_override_lid"
        sudo -n /usr/bin/pmset -a disablesleep 0
        echo "default" > "$HOME/.battopt-swiftbar/.sleep_mode"
        log "heal: sleep_mode auto-reverted to default (AC lost)"
    fi
fi


# Validate .sleep_mode value
VALID_MODES="default presentation download travel"
CURRENT_MODE=$(cat "$HOME/.battopt-swiftbar/.sleep_mode" 2>/dev/null || echo "default")
if ! echo "$VALID_MODES" | grep -qw "$CURRENT_MODE"; then
    log "Corrupted .sleep_mode='$CURRENT_MODE' — resetting to default"
    echo "default" > "$HOME/.battopt-swiftbar/.sleep_mode"
    # Reset pmset to defaults
    sudo -n /usr/bin/pmset -a disablesleep 0
    sudo -n /usr/bin/pmset -b standbydelaylow 900
    sudo -n /usr/bin/pmset -b standbydelayhigh 900
    sudo -n /usr/bin/pmset -b autopoweroffdelay 900
    sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null
fi


# Watchdog — if mode says download but disablesleep is off
if [ "$CURRENT_MODE" = "download" ] || [ "$CURRENT_MODE" = "presentation" ]; then
    if [ "$(pmset -g | awk '/SleepDisabled/{print $2}')" != "1" ]; then
        log "Mode=$CURRENT_MODE but disablesleep=0 — reverting to default"
        echo "default" > "$HOME/.battopt-swiftbar/.sleep_mode"
        sudo -n /usr/bin/pmset -c sleep 120
        sudo -n /usr/bin/pmset -c displaysleep 20
    fi
fi


# === ZOMBIE KILLER ===
# Kill stuck arm_sleep and terminal-notifier processes older than 60s
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

for pid in $(pgrep -f "terminal-notifier.*BattOpt" 2>/dev/null); do
    AGE=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$AGE" ]; then
        SEC=$(echo "$AGE" | awk -F: '{if (NF==2) print $1*60+$2; else if (NF==3) print $1*3600+$2*60+$3; else print 0}')
        if [ "$SEC" -gt 30 ] 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
            log "zombie: killed notifier $pid"
        fi
    fi
done
# === END ZOMBIE KILLER ===




# === LAYER 7: Config Validator ===
# Validates all state files for corruption; fixes safe cases; alerts on hard cases.
validate_config() {
    local issues=0
    
    # 1. .sleep_mode must be one of known values
    local sm
    sm=$(cat "$HOME/.battopt-swiftbar/.sleep_mode" 2>/dev/null || echo "")
    case "$sm" in
        default|presentation|download|travel|"") ;;
        *) log "L7: .sleep_mode corrupt ('$sm') → reset"
           echo "default" > "$HOME/.battopt-swiftbar/.sleep_mode"
           issues=$((issues+1)) ;;
    esac
    
    # 2. .current_power_mode must be one of known values
    local pm
    pm=$(cat "$HOME/.battopt-swiftbar/.current_power_mode" 2>/dev/null || echo "")
    case "$pm" in
        fast|balanced|awake|deep|custom|"") ;;
        *) log "L7: .current_power_mode corrupt ('$pm') → reset"
           echo "balanced" > "$HOME/.battopt-swiftbar/.current_power_mode"
           issues=$((issues+1)) ;;
    esac
    
    # 3. config file must exist and define LAST_UPPER/LAST_LOWER
    if [ -f "$HOME/.battopt-swiftbar/config" ]; then
        if ! grep -q '^LAST_UPPER=' "$HOME/.battopt-swiftbar/config"; then
            log "L7: config missing LAST_UPPER → recreating"
            cat > "$HOME/.battopt-swiftbar/config" <<'CFG'
LAST_UPPER=85
LAST_LOWER=80
SAILING=true
SAIL_GAP=5
CFG
            issues=$((issues+1))
        fi
    else
        log "L7: config missing entirely → recreating"
        cat > "$HOME/.battopt-swiftbar/config" <<'CFG'
LAST_UPPER=85
LAST_LOWER=80
SAILING=true
SAIL_GAP=5
CFG
        issues=$((issues+1))
    fi
    
    # 4. Last update of critical dirs — enforce existence
    for d in reports predictive_data backups; do
        [ ! -d "$HOME/.battopt-swiftbar/$d" ] && {
            mkdir -p "$HOME/.battopt-swiftbar/$d"
            log "L7: created missing dir $d"
            issues=$((issues+1))
        }
    done
    
    # 5. Log result
    if [ "$issues" -gt 0 ]; then
        log "L7: auto-fixed $issues config issues"
    fi
}

validate_config
# === END LAYER 7 ===
exit 0
