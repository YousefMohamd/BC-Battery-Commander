#!/bin/bash
# Ensure limit is applied — runs after daemon restart (Battery Commander)
# W4.4: this is now a READINESS gate only. It confirms the SMC path is
# ready (BCLM readable) and logs the configured limit. It does NOT apply
# limits and does NOT correct drift — the single bc-watchdog.sh owns ALL
# drift correction (W3); ensure_limit must never reapply. The old
# `battopt status` / `battopt limit` calls (3 sites) and the "daemon
# ready" wait keyed on `battopt status` are gone.
# Called by the watchdog's consolidated fold (every 600 s) from the live
# state dir. Its plist is `.disabled` (not scheduled directly).
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
CONFIG="$DASH/config"
LOG="$DASH/actions.log"
BC_BUILD_DIR="${BC_BUILD_DIR:-}"
BC_CANDIDATES="$BC_BUILD_DIR/bc-candidates"

log() { echo "[$(date '+%H:%M:%S')] ensure_limit: $1" >> "$LOG"; }

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
case "$LAST_UPPER" in ''|*[!0-9]*) LAST_UPPER=86 ;; esac
case "$LAST_LOWER" in ''|*[!0-9]*) LAST_LOWER=85 ;; esac

# bc_read_bclm — print the BCLM value (10 = hold, 100 = charging allowed),
# or nothing if it cannot be read. Read-only; never writes.
# (Same helper as dispatch.sh W1; bc-candidates prints
# "BCLM: size=1 type=ui8 bytes=0a value=10".)
bc_read_bclm() {
    local _bin="$BC_CANDIDATES" _out _v
    if [ -x "$_bin" ]; then
        _out=$("$_bin" 2>/dev/null) || _out=""
        _v=$(printf '%s\n' "$_out" | grep '^BCLM:' | grep -oE 'value=[0-9]+' | grep -oE '[0-9]+' | head -1)
        [ -n "$_v" ] && printf '%s' "$_v" && return 0
    fi
    # Fallback (2026-11-19 status-path fix): bc-candidates is a build-tree
    # binary with no installed location; bc-status (state dir) reports
    # the same BCLM read-only.
    _v=$("$DASH/bc-status" 2>/dev/null | grep '^BCLM:' | grep -oE '[0-9]+' | head -1)
    [ -n "$_v" ] && printf '%s' "$_v" && return 0
    return 1
}

# === ACTIVE SESSION GUARD ===
# Skip if ANY session is active (charge_full, discharge, hold, calibration)
if [ -f "$DASH/state_guard.sh" ]; then
    source "$DASH/state_guard.sh" || exit 1
    if guard_session_active; then
        ACTIVE=$(cat "$DASH/.active_mode" 2>/dev/null)
        log "active session ($ACTIVE) — skipping"
        exit 0
    fi
fi
# Also skip on legacy .sd_session (belt-and-suspenders)
if [ -f "$DASH/.sd_session" ]; then
    SD_ID=$(cat "$DASH/.sd_session" 2>/dev/null)
    if [ -n "$SD_ID" ] && [ "$SD_ID" != "none" ]; then
        log "SD session active ($SD_ID) — skipping"
        exit 0
    fi
fi
# === END GUARD ===

if [ -f "$DASH/.apg_paused" ]; then
    log "APG thermal pause - skipping"
    exit 0
fi

# SMC readiness check (replaces the old "daemon ready" wait, which was
# keyed on `battopt status` succeeding). Try to read BCLM for up to 10 s;
# if it reads, the SMC path is ready and the enforcer can work.
_ready=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    if _bclm=$(bc_read_bclm 2>/dev/null); then
        _ready=1
        break
    fi
    sleep 1
done

if [ "$_ready" -ne 1 ]; then
    log "BCLM unreadable after 10 s — SMC path not ready"
    exit 1
fi

# Readiness confirmed. The configured limit is reported for diagnostics;
# drift correction (if BCLM disagrees with the config) is the watchdog's
# job, not this script's — no reapply happens here.
log "SMC path ready (BCLM=${_bclm}); configured limit $LAST_UPPER/$LAST_LOWER; drift correction is the watchdog's job"

exit 0
