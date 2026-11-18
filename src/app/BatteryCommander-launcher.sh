#!/bin/bash
# Battery Commander (BC) Launcher (W5.1)
# The single launcher. Starts the menu UI (SwiftBar plugin) and checks the
# enforcer (bc-limit via the root LaunchDaemon). Verifies they started and
# reports failure visibly. Never silently.
#
# BC rules: no battopt binary, no sudo, no launchctl load (loading the
# enforcer daemon is the Phase C gate - the launcher NEVER auto-loads it),
# notifications are app-native (queue for BatteryCommander.app to post;
# final cleanup 2026-11-18), no trial-renew helpers. Config is parsed
# as KEY=value, never sourced.
# Defaults are the canonical 86/85 (never the stale 85/80).
#
# BC state dir: ~/.battery-commander/ (state-dir migration completed
# 2026-11-10; the old-dir fallback was retired in the 2026-11-13
# consolidation, M2 - DASH is ALWAYS the new dir).
DASH="$HOME/.battery-commander"
LOG="$DASH/actions.log"
PLUGIN_DIR="$HOME/SwiftBar"
PLUGIN_NAME="battery-commander.10s.sh"
LOCK_FILE="$DASH/.launch.lock"
DAEMON_LABEL="com.batterycommander.bclimit"
WATCHDOG_LABEL="com.batterycommander.watchdog"
POWERWATCH_LABEL="com.batterycommander.powerwatch"

mkdir -p "$DASH" "$PLUGIN_DIR"

log() { echo "[$(date '+%H:%M:%S')] Battery Commander (BC): $1" >> "$LOG"; }

# Notification (final cleanup 2026-11-18): app-native transport —
# append one title<TAB>body line to the queue; BatteryCommander.app
# posts it itself via UNUserNotificationCenter. (This script is the
# retired pre-Stage-C launcher, kept as the porting source for
# Housekeeping.swift; its notify is converted for consistency so
# no product file references an external notifier.)
notify() {
    local title="$1" msg="$2"
    local _t _b
    _t=$(printf '%s' "$title" | tr '\n\t' '  ')
    _b=$(printf '%s' "$msg" | tr '\n\t' '  ')
    printf '%s\t%s\n' "$_t" "$_b" >> "$DASH/.notify_queue" 2>/dev/null || true
    log "NOTIFY: $title - $msg"
}

# Read a KEY=value config file into shell vars (never `source` a data file).
# Sets LAST_UPPER, LAST_LOWER, SAILING, SAIL_GAP (defaults 86/85/false/1).
read_config() {
    LAST_UPPER=86
    LAST_LOWER=85
    SAILING=false
    SAIL_GAP=1
    local cfg="$DASH/config"
    [ -f "$cfg" ] || return 0
    local key val
    while IFS='=' read -r key val; do
        case "$key" in
            LAST_UPPER) LAST_UPPER="$val" ;;
            LAST_LOWER) LAST_LOWER="$val" ;;
            SAILING) SAILING="$val" ;;
            SAIL_GAP) SAIL_GAP="$val" ;;
        esac
    done < "$cfg"
}

valid_limit() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 15 ] && [ "$1" -le 100 ]
}

# Check whether a launchd label is loaded (user domain). Returns 0 if loaded.
daemon_loaded() {
    launchctl list "$1" >/dev/null 2>&1
}

# Check whether the SYSTEM enforcer daemon is running. `launchctl list`
# (user domain) cannot see a system daemon, so the daemon log's mtime
# is the proxy: the daemon writes to it on every 60 s run. Returns 0
# if the log was written in the last 180 s. NOTE: a failing daemon
# still refreshes the log (bc-limit prints ERRORs to stdout), so the
# caller must also scan the tail for ERROR (see step 3).
daemon_running_system() {
    local _log="$DASH/bc-limit-daemon.log"
    [ -f "$_log" ] || return 1
    local _age=$(( $(date +%s) - $(stat -f %m "$_log" 2>/dev/null || echo 0) ))
    [ "$_age" -lt 180 ]
}

# Read BCLM via bc-status (read-only). Prints the value or nothing.
# bc-status is deployed to the state dir at deploy time (W6). No hardcoded
# repo path: the launcher must not assume where the repo lives.
read_bclm() {
    if [ -x "$DASH/bc-status" ]; then
        "$DASH/bc-status" 2>/dev/null | grep '^BCLM:' | awk '{print $2}' | head -1
        return 0
    fi
    return 1
}

LOCK_DIR="${LOCK_FILE}.dir"
if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    trap 'rm -rf "$LOCK_DIR"' EXIT
else
    _lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$_lock_pid" ] && kill -0 "$_lock_pid" 2>/dev/null; then
        log "another launcher (PID $_lock_pid) is already running - exiting"
        exit 0
    fi
    log "WARN: stale launch lock (PID ${_lock_pid:-unknown} not running) - taking over"
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        trap 'rm -rf "$LOCK_DIR"' EXIT
    else
        log "WARN: could not take launch lock - continuing without it"
    fi
fi

log "=== LAUNCH START ==="
START_TIME=$(date +%s)

# 1. Force clear any shutdown flags
rm -f "$DASH/.user_shutdown" "$DASH/.disabled" "$DASH/.paused" 2>/dev/null

# 2. Restore plugin (BC name only)
for plugin in "$DASH/disabled"/battery-commander.*.sh; do
    [ -f "$plugin" ] || continue
    mv "$plugin" "$PLUGIN_DIR/"
    chmod 755 "$PLUGIN_DIR/$(basename "$plugin")"
    log "restored plugin: $(basename "$plugin")"
done

# 3. Check the enforcer (bc-limit LaunchDaemon). NEVER auto-load it:
#    loading is the Phase C gate. Log + notify if it is not loaded.
if daemon_running_system; then
    if tail -20 "$DASH/bc-limit-daemon.log" 2>/dev/null | grep -q 'ERROR'; then
        log "WARN: enforcer $DAEMON_LABEL log is fresh but shows ERRORs - enforcement may be failing (check $DASH/bc-limit-daemon.log)"
        notify "Battery Commander (BC)" "Enforcer is reporting errors - charge limit may not be enforcing. Check bc-limit-daemon.log."
    else
        log "enforcer $DAEMON_LABEL is running (daemon log fresh)"
    fi
else
    log "WARN: enforcer $DAEMON_LABEL is NOT running (Phase C gate - hold will not enforce)"
    notify "Battery Commander (BC)" "Enforcer not running - charge limit will not enforce until the daemon is loaded (Phase C)."
fi

# 4. Check powerwatch (user LaunchAgent). It is managed by launchctl;
#    there is no start helper script in BC. Log if it is not loaded.
if daemon_loaded "$POWERWATCH_LABEL"; then
    log "powerwatch $POWERWATCH_LABEL is loaded"
else
    log "WARN: powerwatch $POWERWATCH_LABEL is NOT loaded (sleep/wake events will not fire)"
fi

# 5. Check the watchdog agent (wired at deploy, W6). Log only.
if daemon_loaded "$WATCHDOG_LABEL"; then
    log "watchdog $WATCHDOG_LABEL is loaded"
else
    log "watchdog $WATCHDOG_LABEL is not loaded (expected before deploy)"
fi

# 6. Restore the saved session state (config is authoritative).
read_config
if ! valid_limit "$LAST_UPPER"; then LAST_UPPER=86; fi
if ! valid_limit "$LAST_LOWER"; then LAST_LOWER=85; fi
if [ "$LAST_LOWER" -ge "$LAST_UPPER" ]; then LAST_LOWER=$((LAST_UPPER - 1)); fi

LAST_SESSION="$DASH/.last_session_mode"
SESSION_MODE="idle"
if [ -f "$LAST_SESSION" ]; then
    SESSION_MODE=$(grep '^ACTIVE_MODE=' "$LAST_SESSION" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]')
    [ -n "$SESSION_MODE" ] || SESSION_MODE="idle"
fi
log "config limits: ${LAST_UPPER}/${LAST_LOWER} (authoritative); last_session mode: ${SESSION_MODE:-none}"

# 7. Reconciler: determine correct state from hardware (ioreg, not the daemon).
BATT_IOREG=$(ioreg -rn AppleSmartBattery 2>/dev/null)
CUR_CAP=$(echo "$BATT_IOREG" | grep -oE '"CurrentCapacity" = [0-9]+' | awk '{print $3}')
MAX_CAP=$(echo "$BATT_IOREG" | grep -oE '"MaxCapacity" = [0-9]+' | awk '{print $3}')

if [ -n "$CUR_CAP" ] && [ -n "$MAX_CAP" ] && [ "$MAX_CAP" -gt 0 ] 2>/dev/null; then
    CURRENT_PCT=$(( (CUR_CAP * 100 + MAX_CAP / 2) / MAX_CAP ))
else
    CURRENT_PCT=""
fi

# Apply the saved limits via the BC backend (dispatch reapply_limit writes
# the canonical config atomically; the enforcer applies BCLM on its next
# 60 s run when loaded). Never call bc-limit --write from here.
if [ -x "$DASH/dispatch.sh" ]; then
    "$DASH/dispatch.sh" reapply_limit >/dev/null 2>&1
    log "reapplied configured limit ${LAST_UPPER}/${LAST_LOWER} via dispatch"
else
    log "WARN: dispatch.sh not found in $DASH - cannot reapply limit"
fi

if [ -z "$CURRENT_PCT" ]; then
    # Can't read battery - apply limits only, stay safe
    log "WARN: could not read battery %; applying limits only"
    rm -f "$DASH/.charge_target"  # hold = no target
    echo "hold" > "$DASH/.active_mode"

elif [ "$CURRENT_PCT" -lt "$LAST_LOWER" ]; then
    # Below lower limit -> charge to LAST_UPPER (enforcer: BCLM=100 until
    # UPPER, then BCLM=10). No separate force-charge command in BC v1.
    echo "$LAST_UPPER" > "$DASH/.charge_target"
    echo "charge_full" > "$DASH/.active_mode"
    log "Reconciler: PCT=${CURRENT_PCT}% < LOWER=${LAST_LOWER}% - starting charge to ${LAST_UPPER}%"

else
    # At or above lower bound -> hold. The enforcer holds at UPPER via
    # BCLM=10; natural drain brings a battery above upper back into the
    # band. Launch must never actively discharge - that is an explicit
    # user action (smart_discharge) per BC design.
    rm -f "$DASH/.charge_target"  # hold = no target
    echo "hold" > "$DASH/.active_mode"
    log "Reconciler: PCT=${CURRENT_PCT}% >= LOWER=${LAST_LOWER}% - holding (no discharge)"
fi

# Verify the enforcer state via a BCLM read (read-only). If BCLM disagrees
# with the expected state, log + notify; the enforcer applies it on its
# next 60 s run. Never retry with a battopt call.
sleep 2
BCLM_NOW=$(read_bclm)
if [ -n "$BCLM_NOW" ]; then
    log "BCLM read-back: $BCLM_NOW (expected 10 when holding, 100 when charging)"
    if [ -n "$CURRENT_PCT" ] && [ "$CURRENT_PCT" -ge "$LAST_UPPER" ] && [ "$BCLM_NOW" != "10" ]; then
        log "WARN: BCLM=$BCLM_NOW but PCT=${CURRENT_PCT}% >= UPPER=${LAST_UPPER}% (charging not held - enforcer will correct on its next run)"
        notify "Battery Commander (BC)" "Battery ${CURRENT_PCT}% is above the ${LAST_UPPER}% limit but charging is not held (BCLM=${BCLM_NOW})."
    elif [ -n "$CURRENT_PCT" ] && [ "$CURRENT_PCT" -lt "$LAST_LOWER" ] && [ "$BCLM_NOW" != "100" ]; then
        log "WARN: BCLM=$BCLM_NOW but PCT=${CURRENT_PCT}% < LOWER=${LAST_LOWER}% (charging not enabled - enforcer will correct on its next run)"
        notify "Battery Commander (BC)" "Battery ${CURRENT_PCT}% is below the ${LAST_LOWER}% limit but charging is not enabled (BCLM=${BCLM_NOW})."
    fi
else
    log "WARN: BCLM unreadable (bc-status not found) - enforcer state unverified"
fi

# Post-shutdown overshoot reconciliation: if we relaunched into PCT > UPPER
# (charging ran unrestricted while the tool was off), assert idle so the
# watchdog owns the discharge decision - do NOT claim "hold" for a state
# that is already above the enforced limit.
if [ -n "$CURRENT_PCT" ] && [ "$CURRENT_PCT" -gt "$LAST_UPPER" ]; then
    log "Reconciler: PCT=${CURRENT_PCT}% > UPPER=${LAST_UPPER}% post-launch - asserting idle for watchdog"
    rm -f "$DASH/.charge_target"  # overshoot is not a charge intent
    echo "idle" > "$DASH/.active_mode"
fi

# Refresh UI after applying limits
sleep 2
touch "$PLUGIN_DIR/$PLUGIN_NAME" 2>/dev/null || true

# 8. Launch SwiftBar
if ! pgrep -x SwiftBar >/dev/null 2>&1; then
    if [ -d "/Applications/SwiftBar.app" ]; then
        nohup /Applications/SwiftBar.app/Contents/MacOS/SwiftBar >/dev/null 2>&1 &
        log "SwiftBar launched"
    else
        log "WARN: SwiftBar.app not found - menu UI will not render"
        notify "Battery Commander (BC)" "SwiftBar.app not found - the menu will not render."
    fi
fi

# 9. Verify the UI started: the plugin file must exist in SwiftBar dir.
if [ -f "$PLUGIN_DIR/$PLUGIN_NAME" ]; then
    log "plugin $PLUGIN_NAME present in $PLUGIN_DIR"
else
    log "WARN: plugin $PLUGIN_NAME NOT in $PLUGIN_DIR - menu will not render"
    notify "Battery Commander (BC)" "Plugin $PLUGIN_NAME is not installed in SwiftBar - the menu will not render."
fi

END_TIME=$(date +%s)
log "=== LAUNCH COMPLETE in $((END_TIME - START_TIME))s ==="
exit 0
