#!/bin/bash
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
DASH="$HOME/.battopt-swiftbar"
PLUGIN_DIR="$HOME/SwiftBar"
AGENT_DIR="$HOME/Library/LaunchAgents"
APP_BUNDLE="/Applications/BattOpt.app"
APP_LAUNCHER="$APP_BUNDLE/Contents/Resources/BattOpt-launcher.sh"
PLIST="com.battopt.sleepmonitor.plist"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$DASH/.install-backup/$STAMP"

sudo -v

CURRENT_USER="$(id -un)"

if [ "$CURRENT_USER" != "Yousef" ]; then
    echo "WARNING: this installation is configured for user Yousef; current user is $CURRENT_USER" >&2
fi

if [ ! -x /usr/local/bin/battopt ]; then
    echo "ERROR: vendor binary missing or not executable: /usr/local/bin/battopt" >&2
    exit 1
fi

if [ ! -d /Applications/SwiftBar.app ]; then
    echo "WARNING: SwiftBar.app is not installed at /Applications/SwiftBar.app" >&2
fi
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
    chmod 0755 "$dst"
}

# 1. Copy all daemon-helpers scripts
for src in "$ROOT"/src/daemon-helpers/*.sh; do
    [ -f "$src" ] || continue
    copy_with_backup "$src" "$DASH/$(basename "$src")"
done

# 1b. Install root helpers required by user-facing actions.
ROOT_HELPERS="
battopt-daemon-start
battopt-daemon-stop
battopt-daemon-restart
battopt-trial-renew
battopt-release-cfg
battopt-restore-cfg
battopt-powerwatch-start
battopt-powerwatch-stop
"

for name in $ROOT_HELPERS; do
    src="$ROOT/src/daemon-helpers/$name"
    dst="/usr/local/bin/$name"

    [ -f "$src" ] || {
        echo "Missing required root helper: $src" >&2
        exit 1
    }

    if [ -e "$dst" ]; then
        sudo cp -p "$dst" "$BACKUP/root-bin-$name"
    fi

    sudo install -m 0755 "$src" "$dst"
done

# 2. Copy plugin
copy_with_backup "$ROOT/src/plugin/battopt.10s.sh" "$PLUGIN_DIR/battopt.10s.sh"

# 3. Copy plist
copy_with_backup "$ROOT/src/agents/$PLIST" "$AGENT_DIR/$PLIST"

# 4. Install or build the complete BattOpt.app bundle.
if [ -d "$APP_BUNDLE" ]; then
    if [ -e "$APP_LAUNCHER" ]; then
        sudo cp -p "$APP_LAUNCHER" "$BACKUP/BattOpt-launcher.sh"
    fi
    sudo install -m 0755 \
        "$ROOT/src/app/BattOpt-launcher.sh" \
        "$APP_LAUNCHER"
else
    "$ROOT/src/app/build-app.sh" --install
fi

# 5. Syntax check installed shell scripts.
for file in "$DASH"/*.sh "$PLUGIN_DIR/battopt.10s.sh"; do
    [ -f "$file" ] && bash -n "$file"
done

for name in $ROOT_HELPERS; do
    bash -n "/usr/local/bin/$name"
done

# 6. Sudoers: validate first, back up, then install.
SUDOERS_SRC="$ROOT/src/sudoers/battopt"
SUDOERS_DST="/etc/sudoers.d/battopt"
SUDOERS_TMP="/tmp/battopt-sudoers.$$"

[ -f "$SUDOERS_SRC" ] || {
    echo "Missing sudoers source: $SUDOERS_SRC" >&2
    exit 1
}

sudo install -o root -g wheel -m 0440 "$SUDOERS_SRC" "$SUDOERS_TMP"

if ! sudo visudo -cf "$SUDOERS_TMP"; then
    sudo rm -f "$SUDOERS_TMP"
    echo "ERROR: sudoers validation failed; existing sudoers not changed" >&2
    exit 1
fi

if [ -e "$SUDOERS_DST" ]; then
    sudo cp -p "$SUDOERS_DST" "$BACKUP/sudoers.battopt"
else
    : > "$BACKUP/sudoers.battopt.absent"
fi

sudo install -o root -g wheel -m 0440 "$SUDOERS_TMP" "$SUDOERS_DST"
sudo rm -f "$SUDOERS_TMP"

sudo visudo -cf "$SUDOERS_DST"

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
