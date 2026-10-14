#!/bin/bash
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
DASH="$HOME/.battopt-swiftbar"
PLUGIN_DIR="$HOME/SwiftBar"
AGENT_DIR="$HOME/Library/LaunchAgents"
APP="/Applications/BattOpt.app/Contents/MacOS/BattOpt"
PLIST="com.battopt.sleepmonitor.plist"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$DASH/.install-backup/$STAMP"

sudo -v
mkdir -p "$DASH" "$PLUGIN_DIR" "$AGENT_DIR" "$BACKUP"

copy_with_backup() {
    src="$1"
    dst="$2"
    if [ -e "$dst" ]; then
        mkdir -p "$BACKUP/$(dirname "${dst#$HOME/}")"
        cp -p "$dst" "$BACKUP/$(dirname "${dst#$HOME/}")/"
    fi
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
}

# 1. Copy all daemon-helpers scripts
for src in "$ROOT"/src/daemon-helpers/*.sh; do
    [ -f "$src" ] || continue
    copy_with_backup "$src" "$DASH/$(basename "$src")"
done

# 2. Copy plugin
copy_with_backup "$ROOT/src/plugin/battopt.10s.sh" "$PLUGIN_DIR/battopt.10s.sh"

# 3. Copy plist
copy_with_backup "$ROOT/src/agents/$PLIST" "$AGENT_DIR/$PLIST"

# 4. Install launcher (with sudo)
if [ -e "$APP" ]; then
    sudo cp -p "$APP" "$BACKUP/BattOpt"
fi
sudo install -m 0755 "$ROOT/src/app/BattOpt-launcher.sh" "$APP"

# 5. Syntax check all scripts
for file in "$DASH"/*.sh "$PLUGIN_DIR/battopt.10s.sh" "$APP"; do
    [ -f "$file" ] && bash -n "$file"
done

# 6. Sudoers (only if missing)
SUDOERS_SRC="$ROOT/src/sudoers/battopt"
SUDOERS_DST="/etc/sudoers.d/battopt"
if [ -f "$SUDOERS_SRC" ] && [ ! -f "$SUDOERS_DST" ]; then
    sudo install -o root -g wheel -m 0440 "$SUDOERS_SRC" "$SUDOERS_DST"
    sudo visudo -cf "$SUDOERS_DST"
fi

# 7. Reload new plist
launchctl unload "$AGENT_DIR/$PLIST" 2>/dev/null || true
launchctl load -w "$AGENT_DIR/$PLIST"

# 8. Reload existing agents
for plist in "$AGENT_DIR"/com.battopt.*.plist; do
    [ -f "$plist" ] || continue
    [ "$plist" = "$AGENT_DIR/$PLIST" ] && continue
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load -w "$plist"
done

echo "BattOpt install complete. Backup: $BACKUP"
