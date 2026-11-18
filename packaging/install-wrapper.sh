#!/bin/sh
# Battery Commander — DMG install launcher.
#
# Ships in the DMG root as "Install Battery Commander.command".
# Double-click it after dragging BatteryCommander.app to /Applications
# (if the app has not been dragged yet, the copy on this DMG is used as
# the payload source — the bytes are identical). It runs the one-time
# setup from the app bundle's payload: see payload/setup.sh for exactly
# what it does. One admin password prompt; safe to re-run.

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
SETUP=""
for cand in \
    "/Applications/BatteryCommander.app/Contents/Resources/payload/setup.sh" \
    "$DIR/BatteryCommander.app/Contents/Resources/payload/setup.sh"
do
    if [ -f "$cand" ]; then
        SETUP=$cand
        break
    fi
done

if [ -z "$SETUP" ]; then
    printf '%s\n' "Could not find BatteryCommander.app (looked in /Applications and next to this file)."
    printf '%s\n' "Drag BatteryCommander.app to /Applications first, then run this again."
    printf '%s\n' "Press Return to close this window."
    read -r _
    exit 1
fi

exec /bin/sh "$SETUP"
