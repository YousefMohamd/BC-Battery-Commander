#!/bin/bash
# force_reset.sh — BC recovery (W6 rewrite).
#
# The old version was entirely battopt-based (BAT reads, sudo pkill,
# battopt-daemon-start/restart, the buddha-path plist, `sudo -n battopt
# status`). This BC version never calls the closed-source binary, never
# uses sudo, never writes BCLM and never loads a daemon. It:
#   1. re-verifies the readable state (BCLM via bc-status, config,
#      enforcer log freshness as the daemon-loaded proxy);
#   2. clears stale guard/session state;
#   3. re-applies the configured limit INLINE (atomic config write +
#      read-back verify — the same steps as dispatch bc_apply_limit).
#      It must NOT call `dispatch.sh reapply_limit`: the caller (dispatch
#      `force_reset`) already holds .op.lock, so a nested dispatch would
#      fail its acquire and Force Reset always failed (audit 2026-11-11,
#      CRITICAL). Only the config is written; the enforcer enforces.
#
# Called from dispatch `force_reset` (guard lock held by the caller).
# Exit 0 = recovery done, 1 = recovery failed (see actions.log).

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
BC_BUILD_DIR="${BC_BUILD_DIR:-$HOME/Projects/BattOpt-CC-Release/battopt-project/bc-build}"
REPO="$HOME/Projects/BattOpt-CC-Release"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') force_reset: $*" >> "$LOG"
}

# 1. Re-verify readable state.
BC_OUT=""
[ -x "$BC_BUILD_DIR/bc-status" ] && BC_OUT=$("$BC_BUILD_DIR/bc-status" 2>/dev/null)
BCLM_VAL=$(echo "$BC_OUT" | grep '^BCLM:' | grep -oE '[0-9]+' | head -1)
PCT=$(echo "$BC_OUT" | grep '^Capacity:' | grep -oE '[0-9]+' | head -1)
if [ -z "$BCLM_VAL" ]; then
    log "BCLM unreadable — aborting recovery (state unknown)"
    exit 1
fi
log "state: BCLM=$BCLM_VAL pct=${PCT:-?}%"

# Config (KEY=value parse, never source) — canonical 86/85 defaults.
# SAILING/SAIL_GAP are preserved so the inline reapply below does not
# silently drop them.
UPPER=86
LOWER=85
SAILING=false
SAIL_GAP=1
if [ -f "$DASH/config" ]; then
    while IFS='=' read -r _k _v; do
        case "$_k" in
            LAST_UPPER) UPPER="$_v" ;;
            LAST_LOWER) LOWER="$_v" ;;
            SAILING) SAILING="$_v" ;;
            SAIL_GAP) SAIL_GAP="$_v" ;;
        esac
    done < "$DASH/config"
fi
case "$UPPER" in ''|*[!0-9]*) UPPER=86 ;; esac
case "$LOWER" in ''|*[!0-9]*) LOWER=85 ;; esac

# Enforcer daemon: direct query — `launchctl print system/<label>` works
# from a user shell (verified 2026-11-11); `launchctl list` cannot see a
# system daemon. The log-mtime proxy it replaces could not tell a loaded
# daemon from a stale log.
if launchctl print system/com.batterycommander.bclimit >/dev/null 2>&1; then
    log "enforcer daemon loaded"
else
    log "WARN: enforcer daemon not loaded (Phase C gate)"
fi

# 2. Clear stale guard/session state.
rm -f "$DASH/.guard_lock" "$DASH/.sd_session" "$DASH/.layer4b_hold" 2>/dev/null
log "stale guard/session state cleared"

# 3. Re-apply the configured limit INLINE (config write only — the
# enforcer applies it on its next 60 s run). Mirrors dispatch
# bc_apply_limit: validate, refuse to write if the state is unreadable
# (BCLM was verified in step 1; % is checked here), write atomically,
# verify by re-reading. No nested dispatch call — see the header.
if [ -z "$PCT" ]; then
    log "no battery reading — config NOT written (recovery failed)"
    exit 1
fi
printf 'LAST_UPPER=%s\nLAST_LOWER=%s\nSAILING=%s\nSAIL_GAP=%s\n' \
    "$UPPER" "$LOWER" "$SAILING" "$SAIL_GAP" > "$DASH/config.tmp.$$" \
    && mv "$DASH/config.tmp.$$" "$DASH/config" || {
    log "config write failed — recovery failed"
    exit 1
}
_verify_up=""
_verify_lo=""
if [ -f "$DASH/config" ]; then
    while IFS='=' read -r _k _v; do
        case "$_k" in
            LAST_UPPER) _verify_up="$_v" ;;
            LAST_LOWER) _verify_lo="$_v" ;;
        esac
    done < "$DASH/config"
fi
if [ "$_verify_up" = "$UPPER" ] && [ "$_verify_lo" = "$LOWER" ]; then
    log "recovery done — limit $UPPER/$LOWER re-applied (pct=$PCT% BCLM=$BCLM_VAL)"
    exit 0
fi
log "reapply verify failed after config write $UPPER/$LOWER (read back ${_verify_up:-?}/${_verify_lo:-?})"
exit 1
