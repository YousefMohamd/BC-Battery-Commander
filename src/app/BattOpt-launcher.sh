#!/bin/bash

set -u

DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
PLUGIN_DIR="$HOME/SwiftBar"
LOCK_FILE="$DASH/.launch.lock"
DAEMON_PLIST="/Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist"
BAT="/usr/local/bin/battopt"
NOTIFIER="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
ICON="$DASH/icons/battopt.png"

mkdir -p "$DASH" "$PLUGIN_DIR"

log() {
    echo "[$(date '+%H:%M:%S')] BattOpt.app: $1" >> "$LOG"
}

if [ -f "$LOCK_FILE" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0) ))

    if [ "$LOCK_AGE" -lt 30 ]; then
        log "skipped: launch already in progress"
        exit 0
    fi

    log "removing stale launch lock (${LOCK_AGE}s old)"
    rm -f "$LOCK_FILE"
fi

echo "$$" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

log "=== LAUNCH START ==="
START_TIME=$(date +%s)

if [ -f "$DASH/.user_shutdown" ]; then
    log "clearing user shutdown flag"
    rm -f "$DASH/.user_shutdown"
fi

rm -f "$DASH/.disabled" "$DASH/.paused"

mkdir -p "$DASH/disabled"

for plugin in "$DASH/disabled"/battopt.*.sh; do
    [ -f "$plugin" ] || continue

    mv "$plugin" "$PLUGIN_DIR/"
    chmod 755 "$PLUGIN_DIR/$(basename "$plugin")"
    log "restored plugin: $(basename "$plugin")"
done

defaults delete com.ameba.SwiftBar DisabledPlugins 2>/dev/null || true

if [ -x /usr/local/bin/battopt-restore-cfg ]; then
    sudo -n /usr/local/bin/battopt-restore-cfg 2>/dev/null || \
        log "warning: could not restore BattOpt configuration"
fi

if ! pgrep -f "battopt-swiftbar/powerwatch" >/dev/null 2>&1; then
    if [ -x /usr/local/bin/battopt-powerwatch-start ]; then
        sudo -n /usr/local/bin/battopt-powerwatch-start 2>/dev/null || \
            log "warning: could not start powerwatch"
    fi
fi

if ! pgrep -f "Application Support/battopt/battopt daemon" >/dev/null 2>&1; then
    if [ -f "$DAEMON_PLIST" ]; then
        sudo -n launchctl load -w "$DAEMON_PLIST" 2>/dev/null || \
            log "warning: could not load BattOpt daemon"
    else
        log "warning: daemon plist not found: $DAEMON_PLIST"
    fi
fi

DAEMON_READY=0
for _ in $(seq 1 24); do
    sleep 0.5

    if sudo -n "$BAT" status >/dev/null 2>&1; then
        DAEMON_READY=1
        break
    fi
done

if [ "$DAEMON_READY" -eq 1 ]; then
    log "daemon is responding"
else
    log "warning: daemon did not respond during startup polling"
fi

for plist in "$HOME/Library/LaunchAgents"/com.battopt.*.plist; do
    [ -f "$plist" ] || continue

    launchctl load "$plist" 2>/dev/null &
done
wait

if [ -f "$DASH/config" ]; then
    LAST_UPPER=85
    LAST_LOWER=80
    SAILING=true
    SAIL_GAP=10

    source "$DASH/config"

    sudo -n "$BAT" limit \
        "${LAST_UPPER:-85}" \
        "${LAST_LOWER:-80}" >/dev/null 2>&1 &
fi

if ! pgrep -x SwiftBar >/dev/null 2>&1; then
    if [ -x /Applications/SwiftBar.app/Contents/MacOS/SwiftBar ]; then
        nohup /Applications/SwiftBar.app/Contents/MacOS/SwiftBar \
            >/dev/null 2>&1 &
    else
        log "warning: SwiftBar executable not found"
    fi

    for _ in $(seq 1 10); do
        sleep 0.5

        if pgrep -x SwiftBar >/dev/null 2>&1; then
            break
        fi
    done
else
    for plugin in "$PLUGIN_DIR"/battopt.*.sh; do
        [ -f "$plugin" ] || continue
        touch "$plugin"
    done
fi

if [ -x "$NOTIFIER" ] && [ -f "$ICON" ]; then
    "$NOTIFIER" \
        -title BattOpt \
        -message "Control Center ready" \
        -appIcon "$ICON" \
        -sound Ping \
        -group battopt >/dev/null 2>&1 &
fi

END_TIME=$(date +%s)
log "=== LAUNCH COMPLETE in $((END_TIME - START_TIME))s ==="

exit 0
