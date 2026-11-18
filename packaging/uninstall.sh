#!/bin/sh
# Battery Commander — uninstaller.
#
# Ships in the DMG root as "Uninstall Battery Commander.command" (and in
# the app payload). Returns the Mac to stock behaviour, provably, in
# this order — and ABORTS rather than strand a held limit:
#
#   1. RELEASE FIRST: write ~/.battery-commander/.tool_closed (the
#      FR-007 contract) and wait for the daemon's own verified release
#      line ("RELEASE OK: BCLM=100 verified by read-back") in the daemon
#      log. A live discharge session is disengaged by the same path.
#   2. Only after the release is verified is anything removed: the
#      LaunchDaemon + its root binary, the sudoers rule, the user
#      agents, the login item, and the app itself.
#   3. The state dir is KEPT by default (config + verification history
#      make a reinstall seamless; with the daemon gone nothing reads
#      it). Pass --purge to remove it as the final step.
#
# If the release cannot be verified, nothing is removed, the
# .tool_closed flag is taken back (so enforcement resumes), and the
# user is told the limit is still held and why.

set -u

STATE_DIR="$HOME/.battery-commander"
LA_DIR="$HOME/Library/LaunchAgents"
DAEMON_LABEL="com.batterycommander.bclimit"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
DAEMON_BIN="/Library/PrivilegedHelperTools/bc-limit"
DAEMON_LOG="$STATE_DIR/bc-limit-daemon.log"
SELF_UID=$(id -u)
APP_PATH="/Applications/BatteryCommander.app"

PURGE=0
case "${1:-}" in
    --purge) PURGE=1 ;;
    "") ;;
    *) printf 'Usage: %s [--purge]\n' "$0" >&2; exit 2 ;;
esac

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------ installed?
DAEMON_FILES=0
if [ -f "$DAEMON_PLIST" ] || [ -f "$DAEMON_BIN" ]; then
    DAEMON_FILES=1
fi
AGENTS_FOUND=$(find "$LA_DIR" -maxdepth 1 -name 'com.batterycommander.*.plist' 2>/dev/null | wc -l | tr -d ' ')
if [ "$DAEMON_FILES" = "0" ] && [ "$AGENTS_FOUND" = "0" ] && [ ! -d "$APP_PATH" ]; then
    say "Battery Commander does not appear to be installed (no daemon, no agents, no app)."
    if [ "$PURGE" = "1" ] && [ -d "$STATE_DIR" ]; then
        rm -rf "$STATE_DIR" && say "State dir purged: $STATE_DIR"
    else
        [ -d "$STATE_DIR" ] && say "State dir kept at $STATE_DIR (re-run with --purge to remove it)."
    fi
    exit 0
fi

# ------------------------------------------------------------ 1. release
DAEMON_LOADED=0
if launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    DAEMON_LOADED=1
fi

if [ "$DAEMON_LOADED" = "1" ]; then
    [ -d "$STATE_DIR" ] || die "daemon is loaded but the state dir is missing; cannot request a release. Nothing removed."
    LOG_SIZE=0
    [ -f "$DAEMON_LOG" ] && LOG_SIZE=$(stat -f %z "$DAEMON_LOG")
    : > "$STATE_DIR/.tool_closed"
    say "Release requested (.tool_closed written). Waiting for the daemon's verified release..."
    RELEASED=0
    i=0
    while [ "$i" -lt 18 ]; do
        if [ -f "$DAEMON_LOG" ]; then
            if tail -c +"$((LOG_SIZE + 1))" "$DAEMON_LOG" 2>/dev/null | grep -q 'RELEASE OK'; then
                RELEASED=1
                break
            fi
        fi
        i=$((i + 1))
        sleep 5
    done
    if [ "$RELEASED" != "1" ]; then
        rm -f "$STATE_DIR/.tool_closed"
        die "the daemon did not verify a release (BCLM=100 read-back) within ~90 s, so NOTHING was removed and enforcement has been resumed. The charge limit is still held. Check $DAEMON_LOG, then re-run the uninstaller."
    fi
    say "Release verified: BCLM=100 confirmed by the daemon's read-back."
elif [ "$DAEMON_FILES" = "1" ]; then
    die "the daemon files exist but the daemon is not loaded, so a limit release cannot be verified. NOTHING was removed. Run setup once (to load the daemon), then re-run the uninstaller."
else
    say "No daemon installed — no limit can be held. Removing the remaining pieces."
fi

# ------------------------------------------------------------- 2. removal
if [ "$DAEMON_FILES" = "1" ]; then
    ROOT_SCRIPT=$(mktemp /tmp/bc-uninstall-root.XXXXXX) || die "mktemp failed."
    cat > "$ROOT_SCRIPT" <<'ROOT_EOF'
#!/bin/sh
DAEMON_LABEL="com.batterycommander.bclimit"
launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$DAEMON_LABEL.plist"
rm -f /Library/PrivilegedHelperTools/bc-limit
rm -f /etc/sudoers.d/battery-commander
ROOT_EOF
    say "Removing the privileged pieces (one admin password prompt)..."
    if ! sudo /bin/sh "$ROOT_SCRIPT"; then
        rm -f "$ROOT_SCRIPT"
        die "the admin removal step failed. The limit was already released (stock charging), but daemon files may remain — re-run the uninstaller."
    fi
    rm -f "$ROOT_SCRIPT"
    say "Daemon, plist and sudoers rule removed."
fi

for plist in "$LA_DIR"/com.batterycommander.*.plist; do
    [ -f "$plist" ] || continue
    base=$(basename "$plist")
    label=${base%.plist}
    launchctl bootout "gui/$SELF_UID/$label" 2>/dev/null || true
    rm -f "$plist"
done
say "User agents removed."

osascript -e 'tell application "System Events" to delete login item "Battery Commander"' >/dev/null 2>&1 || true
osascript -e 'tell application "System Events" to delete login item "BatteryCommander"' >/dev/null 2>&1 || true

if [ -d "$APP_PATH" ]; then
    if ! rm -rf "$APP_PATH" 2>/dev/null; then
        sudo rm -rf "$APP_PATH" || warn "could not remove $APP_PATH — drag it to the Trash manually."
    fi
    [ -d "$APP_PATH" ] || say "App removed from /Applications."
fi

# ------------------------------------------------------- 3. state dir fate
rm -f "$STATE_DIR/.tool_closed" 2>/dev/null || true
if [ "$PURGE" = "1" ]; then
    rm -rf "$STATE_DIR" && say "State dir purged: $STATE_DIR"
else
    [ -d "$STATE_DIR" ] && say "State dir kept at $STATE_DIR (config + verification history). Re-run with --purge to remove it."
fi

say ""
say "Uninstall complete. No daemon, no agents, no sudoers rule, no login item."
say "The battery now charges exactly as stock macOS — no limit is held."
exit 0
