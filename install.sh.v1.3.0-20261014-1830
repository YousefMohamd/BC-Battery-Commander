#!/bin/bash
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.battopt-swiftbar"

echo "BattOpt Installer"
echo "================"

[ ! -x /usr/local/bin/battopt ] && {
    echo "Installing battopt CLI..."
    curl -sSL "https://raw.githubusercontent.com/js4jiang5/BattOpt/main/install.sh" | bash
} || echo "battopt CLI: OK"

mkdir -p "$DEST/icons" "$DEST/.notify" "$HOME/SwiftBar"

cp "$SRC/icons/"*.png "$DEST/icons/" 2>/dev/null || true
cp "$SRC/icons/"*.icns "$DEST/icons/" 2>/dev/null || true

cp "$SRC/daemon-helpers/dispatch.sh" "$DEST/"
cp "$SRC/daemon-helpers/force_reset.sh" "$DEST/"
cp "$SRC/daemon-helpers/power_saver.sh" "$DEST/"
chmod +x "$DEST/"*.sh

sudo cp "$SRC/daemon-helpers/battopt-daemon-start" /usr/local/bin/ 2>/dev/null || true
sudo cp "$SRC/daemon-helpers/battopt-daemon-stop" /usr/local/bin/ 2>/dev/null || true
sudo cp "$SRC/daemon-helpers/battopt-daemon-restart" /usr/local/bin/ 2>/dev/null || true
sudo cp "$SRC/daemon-helpers/battopt-trial-renew" /usr/local/bin/ 2>/dev/null || true
sudo chmod +x /usr/local/bin/battopt-daemon-* /usr/local/bin/battopt-trial-renew 2>/dev/null || true

cp "$SRC/swiftbar-plugin/battopt.15s.sh" "$HOME/SwiftBar/"
chmod +x "$HOME/SwiftBar/battopt.15s.sh"
rm -f "$DEST/.disabled"

[ -d "$SRC/BattOpt.app" ] && {
    sudo rm -rf /Applications/BattOpt.app
    sudo cp -R "$SRC/BattOpt.app" /Applications/
    sudo xattr -rd com.apple.quarantine /Applications/BattOpt.app 2>/dev/null || true
}

[ -d "$SRC/bin/terminal-notifier.app" ] && [ ! -d /Applications/terminal-notifier.app ] && {
    sudo cp -R "$SRC/bin/terminal-notifier.app" /Applications/
    sudo xattr -rd com.apple.quarantine /Applications/terminal-notifier.app 2>/dev/null || true
}

[ ! -d /Applications/SwiftBar.app ] && {
    echo "SwiftBar missing. Download from https://github.com/swiftbar/SwiftBar/releases"
}

USER_NAME=$(whoami)

sudo tee /etc/sudoers.d/battopt-nopasswd > /dev/null << EOF
$USER_NAME ALL=(root) NOPASSWD: /usr/local/bin/battopt
$USER_NAME ALL=(root) NOPASSWD: /usr/local/bin/battopt-daemon-start
$USER_NAME ALL=(root) NOPASSWD: /usr/local/bin/battopt-daemon-stop
$USER_NAME ALL=(root) NOPASSWD: /usr/local/bin/battopt-daemon-restart
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pkill
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset
EOF

sudo chmod 0440 /etc/sudoers.d/battopt-nopasswd

sudo cp "$SRC/daemon-helpers/500.battopt-renew" /etc/periodic/weekly/ 2>/dev/null || true
sudo chmod +x /etc/periodic/weekly/500.battopt-renew 2>/dev/null || true

sudo launchctl load -w /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist 2>/dev/null || true

echo ""
echo "Installation complete."
echo "Open /Applications/BattOpt.app"
