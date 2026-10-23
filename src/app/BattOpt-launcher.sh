#!/bin/bash
# BattOpt.app Launcher — final version
DASH="$HOME/.battopt-swiftbar"
BAT="/usr/local/bin/battopt"
LOG="$DASH/actions.log"
PLUGIN_DIR="$HOME/SwiftBar"
LOCK_FILE="$DASH/.launch.lock"
DAEMON_PLIST="/Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist"

mkdir -p "$DASH" "$PLUGIN_DIR"

log() { echo "[$(date '+%H:%M:%S')] BattOpt.app: $1" >> "$LOG"; }


# Wait for battopt daemon to respond (up to 15s)
wait_for_daemon() {
    local waited=0
    while [ "$waited" -lt 15 ]; do
        if sudo -n "$BAT" status >/dev/null 2>&1; then
            log "daemon ready after ${waited}s"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    log "WARN: daemon not ready after 15s"
    return 1
}

log "=== LAUNCH START ==="
START_TIME=$(date +%s)

# 1. Force clear any shutdown flags
rm -f "$DASH/.user_shutdown" "$DASH/.disabled" "$DASH/.paused" 2>/dev/null

# 2. Restore plugin
for plugin in "$DASH/disabled"/battopt.*.sh; do
    [ -f "$plugin" ] || continue
    mv "$plugin" "$PLUGIN_DIR/"
    chmod 755 "$PLUGIN_DIR/$(basename "$plugin")"
    log "restored plugin: $(basename "$plugin")"
done

# 3. Start powerwatch
if ! pgrep -f "battopt-swiftbar/powerwatch" >/dev/null 2>&1; then
    sudo -n /usr/local/bin/battopt-powerwatch-start 2>/dev/null
fi

# 4. Start daemon
if ! pgrep -f "Application Support/battopt/battopt daemon" >/dev/null 2>&1; then
    sudo -n launchctl load -w "$DAEMON_PLIST" 2>/dev/null
fi

# 5. FORCE RELOAD ALL AGENTS (the fix for the 0 agents bug)
for plist in "$HOME/Library/LaunchAgents/"com.battopt.*.plist; do
    [ -f "$plist" ] || continue
    launchctl unload -w "$plist" 2>/dev/null || true
    launchctl load -w "$plist" 2>/dev/null || true
done
log "Reloaded all agents."

# 6. Restore the saved session state
LAST_SESSION="$DASH/.last_session_mode"
SESSION_MODE=""
LAST_UPPER=""
LAST_LOWER=""

valid_limit() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 20 ] && [ "$1" -le 100 ]
}

if [ -f "$LAST_SESSION" ]; then
    SESSION_MODE=$(grep '^ACTIVE_MODE=' "$LAST_SESSION" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]')
    LAST_UPPER=$(grep '^LAST_UPPER=' "$LAST_SESSION" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]')
    LAST_LOWER=$(grep '^LAST_LOWER=' "$LAST_SESSION" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]')
else
    SESSION_MODE="idle"
fi

if ! valid_limit "$LAST_UPPER" || ! valid_limit "$LAST_LOWER"; then
    if [ -f "$DASH/config" ]; then
        source "$DASH/config"
    fi
fi

if ! valid_limit "$LAST_UPPER"; then
    LAST_UPPER=85
fi
if ! valid_limit "$LAST_LOWER"; then
    LAST_LOWER=80
fi

case "$SESSION_MODE" in
    hold|idle)
        wait_for_daemon
        echo "$SESSION_MODE" > "$DASH/.active_mode"
        if sudo -n "$BAT" limit "$LAST_UPPER" "$LAST_LOWER" >/dev/null 2>&1; then
            log "restored ${SESSION_MODE}: limit $LAST_UPPER/$LAST_LOWER"
        else
            log "WARN: ${SESSION_MODE}: limit FAILED $LAST_UPPER/$LAST_LOWER"
        fi
        ;;
    discharge)
        if ! wait_for_daemon; then
            log "ERROR: discharge restore skipped — daemon did not become ready"
            echo "idle" > "$DASH/.active_mode"
        else
            echo "discharge" > "$DASH/.active_mode"
            if ! sudo -n "$BAT" limit "$LAST_UPPER" "$LAST_LOWER" >/dev/null 2>&1; then
                log "ERROR: discharge restore failed to set limit $LAST_UPPER/$LAST_LOWER"
                echo "idle" > "$DASH/.active_mode"
            else
                VERIFY_UPPER=$(sudo -n "$BAT" status 2>/dev/null | grep -oE 'upper limit [0-9]+' | grep -oE '[0-9]+' | head -1)
                if [ "$VERIFY_UPPER" != "$LAST_UPPER" ]; then
                    sleep 2
                    sudo -n "$BAT" limit "$LAST_UPPER" "$LAST_LOWER" >/dev/null 2>&1
                    VERIFY_UPPER=$(sudo -n "$BAT" status 2>/dev/null | grep -oE 'upper limit [0-9]+' | grep -oE '[0-9]+' | head -1)
                fi
                if [ "$VERIFY_UPPER" != "$LAST_UPPER" ]; then
                    log "ERROR: discharge restore verified SMC=$VERIFY_UPPER expected=$LAST_UPPER"
                    echo "idle" > "$DASH/.active_mode"
                else
                    log "discharge restore: limit verified $LAST_UPPER/$LAST_LOWER"
                    sudo -n "$BAT" discharge "$LAST_UPPER" >> "$LOG" 2>&1
                fi
            fi
        fi
        ;;
    *)
        log "unknown saved session mode: ${SESSION_MODE:-missing}; no battery operation started"
        ;;
esac

# Refresh UI after applying limits
sleep 2
touch "$PLUGIN_DIR/battopt.10s.sh"

# 7. Launch SwiftBar
if ! pgrep -x SwiftBar >/dev/null 2>&1; then
    nohup /Applications/SwiftBar.app/Contents/MacOS/SwiftBar >/dev/null 2>&1 &
fi

END_TIME=$(date +%s)
log "=== LAUNCH COMPLETE in $((END_TIME - START_TIME))s ==="
exit 0
