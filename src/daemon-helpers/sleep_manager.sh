#!/bin/bash
# sleep_manager.sh — Layer 13
# Adaptive pmset tuning based on battery + lid state.
# Portable across Macs (detects capabilities).

# BC state dir: ~/.battery-commander/ is the ONLY live state dir
# (consolidation 2026-11-13, M2: the old-dir fallback is retired — the
# pre-migration dir is a kept, inert backup and must never be read or
# written as a live target). BC_DASH overrides (tests / dry-runs).
if [ -n "${BC_DASH:-}" ]; then
    DASH="$BC_DASH"
elif [ -d "$HOME/.battery-commander" ]; then
    DASH="$HOME/.battery-commander"
else
    echo "ERROR: Battery Commander state dir missing - ~/.battery-commander not found; refusing to run (old-dir fallback retired)" >&2
    exit 1
fi
LOG="$DASH/.sleep_manager.log"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }
# Guard: respect shutdown
if [ -f "$DASH/.user_shutdown" ]; then
    log "shutdown flag present - skipping sleep_manager"
    exit 0
fi


# ── Detect current state ──
IOREG=$(ioreg -rn AppleSmartBattery 2>/dev/null)
EXT=$(echo "$IOREG" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
CLAMSHELL=$(ioreg -r -k AppleClamshellState 2>/dev/null | grep -oE '"AppleClamshellState" = [A-Za-z]+' | awk '{print $3}')

# Some Macs report clamshell differently
[ -z "$CLAMSHELL" ] && CLAMSHELL=$(ioreg -r -k AppleClamshellState 2>/dev/null | grep -oE 'AppleClamshellState" = [A-Za-z]+' | awk -F'= ' '{print $2}' | head -1)

# ── Determine profile ──
PROFILE_FILE="$DASH/.sleep_profile"
CURRENT_PROFILE=""
[ -f "$PROFILE_FILE" ] && CURRENT_PROFILE=$(cat "$PROFILE_FILE")

# Profile is by power source only (W4.3: long/travel removed, only
# "default" exists in power_saver.sh; clamshell dropped, decision 4).
# sleep_manager only RECORDS the profile name — it does not apply pmset.
# Validate EXT before acting: it must be Yes or No. Anything else (empty,
# garbage) means the ioreg parse failed — log and skip, never record a
# wrong profile (audit 2026-11-11, W11).
if [ "$EXT" != "Yes" ] && [ "$EXT" != "No" ]; then
    log "ExternalConnected unreadable ('${EXT:-empty}') — skipping (profile unchanged)"
    exit 0
fi

NEW_PROFILE=""
if [ "$EXT" = "No" ]; then
    NEW_PROFILE="active_battery"
else
    NEW_PROFILE="active_ac"
fi

log "profile: $CURRENT_PROFILE → $NEW_PROFILE (Ext=$EXT Clamshell=$CLAMSHELL)"

# ── Record the profile (profiler-only; no pmset is applied here) ──
log "  recorded $NEW_PROFILE profile (profiler-only — no pmset applied)"

printf '%s\n' "$NEW_PROFILE" > "$PROFILE_FILE.tmp.$$" && mv "$PROFILE_FILE.tmp.$$" "$PROFILE_FILE"
log "  profile saved: $NEW_PROFILE"
exit 0
