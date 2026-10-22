#!/bin/bash
# BattOpt.app Launcher — final version
DASH="$HOME/.battopt-swiftbar"
LOG="$DASH/actions.log"
PLUGIN_DIR="$HOME/SwiftBar"
LOCK_FILE="$DASH/.launch.lock"
DAEMON_PLIST="/Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist"

mkdir -p "$DASH" "$PLUGIN_DIR"

log() { echo "[$(date '+%H:%M:%S')] BattOpt.app: $1" >> "$LOG"; }

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

# 6. Reapply limit
if [ -f "$DASH/config" ]; then
    source "$DASH/config"
    sudo -n /usr/local/bin/battopt limit "${LAST_UPPER:-85}" "${LAST_LOWER:-80}" >/dev/null 2>&1 &
fi

# 7. Launch SwiftBar
if ! pgrep -x SwiftBar >/dev/null 2>&1; then
    nohup /Applications/SwiftBar.app/Contents/MacOS/SwiftBar >/dev/null 2>&1 &
fi

END_TIME=$(date +%s)
log "=== LAUNCH COMPLETE in $((END_TIME - START_TIME))s ==="
exit 0
