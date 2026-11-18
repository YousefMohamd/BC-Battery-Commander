#!/bin/bash
# ac_watcher.sh — detect AC state transitions and reapply intent (Battery Commander)
# Runs every 10 seconds via LaunchAgent.
# W4.2: the one `battopt limit` call is replaced with a BC reapply (config
# write + enforcer signal — never `bc-limit --write` from the watcher, only
# the LaunchDaemon-run enforcer writes BCLM; the watcher is unprivileged).
# .ac_state write is atomic; unused DISPATCH deleted; dead throttle-helper
# source line deleted (the file does not exist); EXT validated before acting.
# No battopt, no sudo, no SMC write.

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
LOG="$DASH/actions.log"
STATE_FILE="$DASH/.ac_state"
CONFIG="$DASH/config"
BC_BUILD_DIR="${BC_BUILD_DIR:-$HOME/Projects/BattOpt-CC-Release/battopt-project/bc-build}"
BC_CANDIDATES="$BC_BUILD_DIR/bc-candidates"

source "$DASH/state_guard.sh" || exit 1

if [ -e "$DASH/.user_shutdown" ]; then
    exit 0
fi

log() { echo "[$(date '+%H:%M:%S')] ac_watcher: $1" >> "$LOG"; }

# atomic_write <file> <content> — tmp+mv (same helper as dispatch.sh W1).
atomic_write() {
    local file="$1" content="$2"
    local tmp="${file}.tmp.$$"
    printf '%s' "$content" > "$tmp" && mv "$tmp" "$file"
}

# read_config — (re-)parse the canonical config as KEY=value into the
# globals. Never `source` a data file (code execution from a data file).
# Defaults (86/85) are used ONLY when no config file exists.
LAST_UPPER=86
LAST_LOWER=85
SAILING=false
SAIL_GAP=1
read_config() {
    local _cfg_key _cfg_val
    if [ -f "$CONFIG" ]; then
        while IFS='=' read -r _cfg_key _cfg_val; do
            case "$_cfg_key" in
                LAST_UPPER) LAST_UPPER="$_cfg_val" ;;
                LAST_LOWER) LAST_LOWER="$_cfg_val" ;;
                SAILING) SAILING="$_cfg_val" ;;
                SAIL_GAP) SAIL_GAP="$_cfg_val" ;;
            esac
        done < "$CONFIG"
    fi
}
read_config

# bc_reapply_limit — the BC reapply (W4.2). Ensures the canonical config
# holds the configured limit (writes defaults atomically ONLY if the file
# is missing), then leaves enforcement to the enforcer: bc-limit (run by
# the root LaunchDaemon every 60 s) reads the config and applies BCLM.
# An existing but invalid config is NEVER overwritten with defaults —
# that would silently destroy a custom limit (audit 2026-11-11, W5);
# self_healing L7 recreates a truly broken config. The watcher never
# writes BCLM and never calls `bc-limit --write`.
bc_reapply_limit() {
    local _valid=1
    case "$LAST_UPPER" in ''|*[!0-9]*) _valid=0 ;; esac
    case "$LAST_LOWER" in ''|*[!0-9]*) _valid=0 ;; esac
    if [ ! -f "$CONFIG" ]; then
        LAST_UPPER=86
        LAST_LOWER=85
        SAILING=false
        SAIL_GAP=1
        atomic_write "$CONFIG" "$(printf 'LAST_UPPER=%s\nLAST_LOWER=%s\nSAILING=%s\nSAIL_GAP=%s\n' "$LAST_UPPER" "$LAST_LOWER" "$SAILING" "$SAIL_GAP")"
        log "reapply: config missing — wrote defaults $LAST_UPPER/$LAST_LOWER"
    elif [ "$_valid" -eq 0 ]; then
        log "reapply: config invalid — NOT overwriting (self_healing L7 recreates a broken config)"
        return 0
    fi
    log "reapply: limit $LAST_UPPER/$LAST_LOWER in config; enforcer applies on its next run"
}

# Read current AC state
IOREG=$(ioreg -rn AppleSmartBattery 2>/dev/null)
EXT=$(echo "$IOREG" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
_AUDIT_NCR=$(echo "$IOREG" | grep -oE '"NotChargingReason"=[0-9]+' | grep -oE '[0-9]+' | head -1)
# Validate EXT before acting: it must be Yes or No. Anything else (empty,
# garbage) means the parse failed — log and skip, never act on it.
if [ "$EXT" != "Yes" ] && [ "$EXT" != "No" ]; then
    log "unexpected ExternalConnected value '${EXT:-empty}' — skipping"
    exit 0
fi

# Read previous state
PREV=""
[ -f "$STATE_FILE" ] && PREV=$(cat "$STATE_FILE" 2>/dev/null | tr -d '[:space:]')

# Save new state (atomic)
atomic_write "$STATE_FILE" "$EXT"

# Detect transitions
if [ "$PREV" = "No" ] && [ "$EXT" = "Yes" ]; then
    # Respect active session — do NOT override charge_full / discharge / calibration
    ACTIVE_MODE=$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')
    [ -z "$ACTIVE_MODE" ] && ACTIVE_MODE="idle"
    # H1: clear LAYER4b auto-hold on AC reconnect (user hold has no marker)
    if [ -f "$DASH/.layer4b_hold" ]; then
        if [ "$ACTIVE_MODE" = "hold" ]; then
            rm -f "$DASH/.layer4b_hold"
            atomic_write "$DASH/.active_mode" "idle"
            log "AC CONNECTED - clearing LAYER4b hold, resuming to limit"
            ACTIVE_MODE="idle"
        fi
    fi
    if guard_session_active; then
        log "AC CONNECTED — skipping (active_mode=$ACTIVE_MODE) (NCR=${_AUDIT_NCR:-?})"
        exit 0
    fi
    if [ -f "$DASH/.apg_paused" ]; then
        log "AC CONNECTED - skipping (APG thermal pause) (NCR=${_AUDIT_NCR:-?})"
        exit 0
    fi
    log "AC CONNECTED — reapplying intent (NCR=${_AUDIT_NCR:-?})"
    # Reapply limit via the BC backend (config write + enforcer signal).
    bc_reapply_limit
elif [ "$PREV" = "Yes" ] && [ "$EXT" = "No" ]; then
    log "AC DISCONNECTED — sailing continues on battery (NCR=${_AUDIT_NCR:-?})"
fi
