#!/bin/bash
# BattOpt.app Launcher — final version
DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
PLUGIN_DIR="$HOME/SwiftBar"
LOCK_FILE="$DASH/.launch.lock"
DAEMON_PLIST="/Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist"

log() { echo "[$(date '+%H:%M:%S')] BattOpt.app: $1" >> "$LOG"; }

# TASK 1: Restore persisted config on boot
BACKUP="$DASH/.last_session_config"
CFG="$DASH/config"
BAT="/usr/local/bin/battopt"
if [ -f "$BACKUP" ]; then
    log "launcher: found .last_session_config — restoring"
    cp "$BACKUP" "$CFG"
    if [ -f "$CFG" ]; then
        source "$CFG"
        sudo -n "$BAT" limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" >> "$LOG" 2>&1
        log "launcher: SMC limit restored to ${LAST_UPPER:-85}/${LAST_LOWER:-80}"
    fi
fi

if [ -f "$LOCK_FILE" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0) ))
    if [ "$LOCK_AGE" -lt 30 ]; then
        log "skipped (in progress)"
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap "rm -f '$LOCK_FILE'" EXIT

log "=== LAUNCH START ==="
START=$(date +%s)

# 1. Explicit launch: clear user_shutdown + soft flags
if [ -f "$DASH/.user_shutdown" ]; then
    log "explicit launch — clearing user_shutdown"
    rm -f "$DASH/.user_shutdown"
fi
rm -f "$DASH/.disabled" "$DASH/.paused" 2>/dev/null

# 2. Restore plugin
mkdir -p "$PLUGIN_DIR"
for f in "$DASH/disabled/"battopt.*.sh; do
    [ -f "$f" ] || continue
    mv "$f" "$PLUGIN_DIR/"
    chmod +x "$PLUGIN_DIR/$(basename "$f")"
done

# 3. Clear SwiftBar prefs
defaults delete com.ameba.SwiftBar DisabledPlugins 2>/dev/null

# 4. Restore cfg: limit_enable = 1
sudo -n /usr/local/bin/battopt-restore-cfg 2>/dev/null

# 5. Start powerwatch
if ! pgrep -f "battopt-swiftbar/powerwatch" >/dev/null 2>&1; then
    sudo -n /usr/local/bin/battopt-powerwatch-start 2>/dev/null
fi

# 6. Start daemon
if ! pgrep -f "Application Support/battopt/battopt daemon" >/dev/null 2>&1; then
    sudo -n launchctl load -w "$DAEMON_PLIST" 2>/dev/null
fi

# Poll daemon
for i in $(seq 1 24); do
    sleep 0.5
    sudo -n /usr/local/bin/battopt status >/dev/null 2>&1 && break
done

# 7. Load user agents in parallel
# Robust Agent Loading (macOS 10.15+)
GUI_DOMAIN="gui/$(id -u)"
for plist in "$HOME/Library/LaunchAgents/"com.battopt.*.plist; do
    [ -f "$plist" ] || continue
    AGENT_NAME=$(basename "$plist" .plist)
    launchctl enable "$GUI_DOMAIN/$AGENT_NAME" 2>/dev/null
    launchctl bootstrap "$GUI_DOMAIN" "$plist" 2>/dev/null
    launchctl load -w "$plist" 2>/dev/null
done

# 8. Reapply limit 85/80
if [ -f "$DASH/config" ]; then
    source "$DASH/config"
    sudo -n /usr/local/bin/battopt limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" >/dev/null 2>&1 &
fi

# 9. Launch SwiftBar
if ! pgrep -x SwiftBar >/dev/null 2>&1; then
    nohup /Applications/SwiftBar.app/Contents/MacOS/SwiftBar >/dev/null 2>&1 &
    for i in $(seq 1 10); do
        sleep 0.5
        pgrep -x SwiftBar >/dev/null 2>&1 && break
    done
else
    for pf in "$PLUGIN_DIR/"battopt.*.sh; do
        [ -f "$pf" ] && touch "$pf"
    done
fi

# 10. Notify
ICON="$DASH/icons/battopt.png"
NOTIFIER="/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"
if [ -x "$NOTIFIER" ] && [ -f "$ICON" ]; then
    "$NOTIFIER" -title BattOpt -message 'Control Center ready' -appIcon "$ICON" -sound Ping -group battopt >/dev/null 2>&1 &
fi

END=$(date +%s)
log "=== LAUNCH COMPLETE in $((END-START))s ==="
exit 0
