#!/bin/sh
# Battery Commander — one-time setup (publish layout installer).
#
# Ships inside BatteryCommander.app/Contents/Resources/payload/ and is
# run once by "Install Battery Commander.command" (or by hand) after the
# app has been dragged to /Applications. It performs, in order:
#
#   1. state-dir scaffolding in ~/.battery-commander/ (an existing state
#      dir is NEVER overwritten: config, verification history and logs
#      are preserved byte-for-byte; only helpers/plists are refreshed)
#   2. the privileged pieces, via ONE admin (sudo) prompt: the bc-limit
#      daemon binary -> /Library/PrivilegedHelperTools/bc-limit
#      (root-owned), its LaunchDaemon plist -> /Library/LaunchDaemons/,
#      and the pmset-only sudoers rule -> /etc/sudoers.d/battery-commander
#   3. the user LaunchAgents -> ~/Library/LaunchAgents/ (loaded)
#   4. legacy SwiftBar plugin retirement (moved to backups, never deleted)
#   5. verification: a fresh daemon tick + watchdog heartbeat
#
# Re-running setup on a healthy install is safe and idempotent: it
# refreshes helpers/plists and re-verifies, changing no user state.
#
# Support claim for v1: Intel Macs (BCLM backend), verified on macOS
# Catalina 10.15. See README.md for the full support matrix.

set -u

PAYLOAD_DIR=$(cd "$(dirname "$0")" && pwd)
STATE_DIR="$HOME/.battery-commander"
LA_DIR="$HOME/Library/LaunchAgents"
DAEMON_LABEL="com.batterycommander.bclimit"
SELF_HOME=$HOME
SELF_USER=$(id -un)
SELF_UID=$(id -u)

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
[ "$(uname -s)" = "Darwin" ] || die "Battery Commander runs on macOS only."
if [ "$(uname -m)" != "x86_64" ]; then
    die "Battery Commander v1 is Intel-only (this Mac reports $(uname -m)). No changes made."
fi
[ -f "$PAYLOAD_DIR/daemon/bc-limit" ] || die "payload incomplete: daemon/bc-limit is missing."
[ -f "$PAYLOAD_DIR/daemon/$DAEMON_LABEL.plist" ] || die "payload incomplete: daemon plist is missing."
[ -f "$PAYLOAD_DIR/sudoers/battery-commander" ] || die "payload incomplete: sudoers rule is missing."
[ -d "$PAYLOAD_DIR/helpers" ] || die "payload incomplete: helpers/ is missing."
[ -d "$PAYLOAD_DIR/agents" ] || die "payload incomplete: agents/ is missing."
[ -f "$PAYLOAD_DIR/defaults/config" ] || die "payload incomplete: defaults/config is missing."

FRESH=1
[ -d "$STATE_DIR" ] && FRESH=0
if [ "$FRESH" = "1" ]; then
    say "Battery Commander setup: fresh install for $SELF_USER."
else
    say "Battery Commander setup: existing install found — refreshing helpers, preserving your state."
fi

# ------------------------------------------------- 1. state-dir scaffolding
# Done BEFORE the daemon is loaded: the daemon's log lives in the state
# dir, so the directory must exist first. Nothing existing is overwritten.
mkdir -p "$STATE_DIR" "$STATE_DIR/backups" "$STATE_DIR/verification" \
         "$STATE_DIR/reports" "$STATE_DIR/predictive_data" \
         "$STATE_DIR/icons" "$LA_DIR" || die "could not create state directories."

if [ -f "$STATE_DIR/config" ]; then
    say "Config preserved: $(grep '^LAST_UPPER=' "$STATE_DIR/config" | cut -d= -f2)/$(grep '^LAST_LOWER=' "$STATE_DIR/config" | cut -d= -f2) (existing values kept)."
else
    cp "$PAYLOAD_DIR/defaults/config" "$STATE_DIR/config" || die "could not write default config."
    say "Default config written: limit 86/85, SAILING=false."
fi
# Empty verification-store scaffolding (history files are never truncated).
[ -f "$STATE_DIR/verification/episodes.jsonl" ] || : > "$STATE_DIR/verification/episodes.jsonl"

# Helpers refresh (upgrade rule: helpers are replaced, state is not).
cp -R "$PAYLOAD_DIR/helpers/." "$STATE_DIR/" || die "could not install helper scripts."
find "$STATE_DIR" -maxdepth 1 -type f \( -name '*.sh' -o -name 'bc-status' -o -name 'powerwatch' \) -exec chmod +x {} +

# ------------------------------------------------------- 2. privileged part
# One sudo prompt. The root helper receives everything it needs as
# arguments (sudo does not preserve this user's environment).
ROOT_SCRIPT=$(mktemp /tmp/bc-setup-root.XXXXXX) || die "mktemp failed."
cat > "$ROOT_SCRIPT" <<'ROOT_EOF'
#!/bin/sh
set -eu
PAYLOAD_DIR=$1
TARGET_HOME=$2
TARGET_USER=$3
DAEMON_LABEL="com.batterycommander.bclimit"

mkdir -p /Library/PrivilegedHelperTools
install -o root -g wheel -m 0755 "$PAYLOAD_DIR/daemon/bc-limit" /Library/PrivilegedHelperTools/bc-limit
sed "s|@HOME@|$TARGET_HOME|g" "$PAYLOAD_DIR/daemon/$DAEMON_LABEL.plist" > "/Library/LaunchDaemons/$DAEMON_LABEL.plist"
chown root:wheel "/Library/LaunchDaemons/$DAEMON_LABEL.plist"
chmod 0644 "/Library/LaunchDaemons/$DAEMON_LABEL.plist"
sed "s|@USER@|$TARGET_USER|g" "$PAYLOAD_DIR/sudoers/battery-commander" > /etc/sudoers.d/battery-commander
chown root:wheel /etc/sudoers.d/battery-commander
chmod 0440 /etc/sudoers.d/battery-commander
visudo -c -f /etc/sudoers.d/battery-commander
launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
launchctl bootstrap system "/Library/LaunchDaemons/$DAEMON_LABEL.plist"
ROOT_EOF

say "Installing the privileged daemon (one admin password prompt)..."
if ! sudo /bin/sh "$ROOT_SCRIPT" "$PAYLOAD_DIR" "$SELF_HOME" "$SELF_USER"; then
    rm -f "$ROOT_SCRIPT"
    die "the admin step failed; the daemon was not (re)installed. Your state dir and helpers are in place but nothing is enforcing a limit yet — fix the error above and re-run setup."
fi
rm -f "$ROOT_SCRIPT"
say "Daemon installed: /Library/PrivilegedHelperTools/bc-limit (root-owned), plist in /Library/LaunchDaemons/."

# ------------------------------------------------------------ 3. user agents
AGENT_COUNT=0
for plist in "$PAYLOAD_DIR/agents/"*.plist; do
    base=$(basename "$plist")
    sed "s|@HOME@|$SELF_HOME|g" "$plist" > "$LA_DIR/$base" || die "could not install agent $base."
    label=${base%.plist}
    launchctl bootout "gui/$SELF_UID/$label" 2>/dev/null || true
    if ! launchctl bootstrap "gui/$SELF_UID" "$LA_DIR/$base"; then
        warn "agent $label did not load; it will be retried at next login."
    fi
    AGENT_COUNT=$((AGENT_COUNT + 1))
done
say "User agents installed and loaded: $AGENT_COUNT."

# ------------------------------------------- 4. legacy SwiftBar plugin move
LEGACY_PLUGIN="$HOME/SwiftBar/battery-commander.10s.sh"
if [ -f "$LEGACY_PLUGIN" ]; then
    DEST="$STATE_DIR/backups/battery-commander.10s.sh.retired-$(date +%Y%m%d%H%M%S)"
    mv "$LEGACY_PLUGIN" "$DEST" && say "Legacy SwiftBar plugin moved to $DEST (never deleted)."
fi

# ------------------------------------------------------------- 5. verification
DAEMON_LOG="$STATE_DIR/bc-limit-daemon.log"
WATCHDOG_LOG="$STATE_DIR/.watchdog.log"
say "Verifying (waiting for a fresh daemon tick)..."
DAEMON_OK=0
i=0
while [ "$i" -lt 15 ]; do
    if [ -f "$DAEMON_LOG" ]; then
        AGE=$(( $(date +%s) - $(stat -f %m "$DAEMON_LOG") ))
        if [ "$AGE" -lt 100 ] && tail -n 6 "$DAEMON_LOG" | grep -q 'state:'; then
            DAEMON_OK=1
            break
        fi
    fi
    i=$((i + 1))
    sleep 5
done
[ "$DAEMON_OK" = "1" ] || die "the daemon did not produce a fresh state line within ~75 s. Check $DAEMON_LOG. Setup can be re-run safely."

WATCHDOG_OK=0
if [ -f "$WATCHDOG_LOG" ]; then
    AGE=$(( $(date +%s) - $(stat -f %m "$WATCHDOG_LOG") ))
    [ "$AGE" -lt 180 ] && WATCHDOG_OK=1
fi
[ "$WATCHDOG_OK" = "1" ] || warn "watchdog heartbeat not fresh yet; it ticks every 60 s — give it a minute, then check $WATCHDOG_LOG."

if [ -x "$STATE_DIR/project_health.sh" ]; then
    HEALTH_LINE=$("$STATE_DIR/project_health.sh" 2>/dev/null | tail -n 1 || true)
    [ -n "$HEALTH_LINE" ] && say "Health check: $HEALTH_LINE"
fi

CFG_UPPER=$(grep '^LAST_UPPER=' "$STATE_DIR/config" | cut -d= -f2)
CFG_LOWER=$(grep '^LAST_LOWER=' "$STATE_DIR/config" | cut -d= -f2)
say ""
say "Setup complete. Daemon: ticking (state line fresh). Limit: $CFG_UPPER/$CFG_LOWER."
say "Open Battery Commander from /Applications — it registers itself as a login item on first launch."
say "To uninstall, run 'Uninstall Battery Commander.command' from the DMG (your state dir is kept unless you choose --purge)."
exit 0
