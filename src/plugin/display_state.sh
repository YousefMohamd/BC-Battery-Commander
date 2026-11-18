#!/bin/bash
# display_state.sh - the SOLE display-state decider for Battery Commander
# (read-only, no state writes). Reads hardware + mode once, decides ICON +
# colours in one table. The plugin calls this and parses its KEY=value
# output with an allow-list (never eval).
#
# Inputs (environment): DISPLAY_MODE, TEMP_INT, PCT_IN, LIMIT_IN, BCLM_IN.
#   BCLM_IN is the hold-state indicator from bc-status (10 = hold,
#   100 = not holding). BCLM is NOT the limit % — the limit lives in config.
# Output (KEY=value, one per line):
#   DISPLAY_MODE=... ICON=... STATE_COLOR=color=... FINAL_COLOR=color=...
#   DISCHARGE_STATUS=... (discharge build 2026-11-13: one menu status
#   line while a discharge session file exists; empty when none)
#   CALIBRATION_STATUS=... (calibrate build 2026-11-14: one menu
#   status line while a calibration run file exists; empty when none)
# Exit 1 (no output) if ioreg data is missing, so the plugin uses its
# minimal safe default.
#
# Icon/colour table (audit §1, unchanged):
#   discharge            🔋 #8A9AAB
#   on battery           🔴 #E8A0A0
#   hold on AC           🔌 white (#FFFFFF)
#   charging on AC       ⚡ grey (#707070)
#   temp >= 42 C         red (#FF3B30); temp >= 38 C orange (#FF9500)
#
# Grey rule (W2.3 — the one documented rule): grey whenever IsCharging=Yes.
# (The old plugin fallback used grey only when ChargingCurrent > 50; that
# rule is dropped. Charging is charging regardless of the current.)
#
# Hold rule (W2.2): BCLM=10 AND ExternalConnected=Yes AND IsCharging=No
# is the authoritative hold. NCR=14 is only a secondary hint when BCLM is
# unavailable (bc-status down) — it must never be the hold signal on its own.
# Discharge rule (W2.2): there is no BC discharge process to pgrep in v1
# (no forced-discharge mechanism yet). A discharge mode survives only while
# an active session token exists (.active_token); otherwise it demotes to
# hold. There is no auto-promote to discharge from PCT > limit.
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

MODE_IN="${DISPLAY_MODE:-}"
TEMP_IN="${TEMP_INT:-}"
BCLM_IN="${BCLM_IN:-}"
IOREG_DATA=$(ioreg -rn AppleSmartBattery 2>/dev/null)
[ -z "$IOREG_DATA" ] && exit 1
ICON_EXT=$(echo "$IOREG_DATA" | grep -oE '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
ICON_ISCHG=$(echo "$IOREG_DATA" | grep -oE '"IsCharging" = [A-Za-z]+' | awk '{print $3}')
ICON_NCR=$(echo "$IOREG_DATA" | grep -oE '"NotChargingReason"=[0-9]+' | grep -oE '[0-9]+' | head -1)
[ -z "$ICON_EXT" ] && exit 1
[ -z "$ICON_ISCHG" ] && exit 1
[ -z "$ICON_NCR" ] && ICON_NCR=0
DISPLAY_MODE="$MODE_IN"
# Authoritative hold: BCLM=10 on AC, not charging.
if [ "$BCLM_IN" = "10" ] && [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ] && \
   [ "$DISPLAY_MODE" != "discharge" ] && [ "$DISPLAY_MODE" != "calibration" ]; then
    DISPLAY_MODE="hold"
elif [ -z "$BCLM_IN" ] && [ "$ICON_NCR" = "14" ] && [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ] && \
   [ "$DISPLAY_MODE" != "discharge" ] && [ "$DISPLAY_MODE" != "calibration" ]; then
    # Secondary hint only (BCLM unreadable). See the hold rule above.
    DISPLAY_MODE="hold"
fi
if [ "$DISPLAY_MODE" = "discharge" ]; then
    # No BC discharge process to pgrep in v1 — the session token is the
    # authority. Demote to hold only when no token remains.
    if [ ! -s "$DASH/.active_token" ]; then
        DISPLAY_MODE="hold"
    fi
fi
# Discharge-mode classification (icon fix, 2026-11-16): a live
# discharge session that is actually DRAINING is the tool's
# discharge mode (battery symbol), not plain battery use (red
# circle). Two draining shapes: (1) bc-limit holds the manager
# discharge mode on AC — the engage marker's STARTED matches the
# session's (EXT reads No because the manager dropped the
# adapter path; reading that flip as battery use was the
# defect); (2) the session drains on battery — EXT=No and the
# monitor's state for THIS session is armed/active. An armed
# session parked on AC is not draining (plug stands); battery
# use with no session keeps the red circle.
DS_ACTIVE=0
if [ -f "$DASH/.discharge_session" ]; then
    _DS_SESS_STARTED=$(grep '^STARTED=' "$DASH/.discharge_session" 2>/dev/null | tail -1 | cut -d= -f2)
    if [ -n "$_DS_SESS_STARTED" ]; then
        _DS_MARK_STARTED=""
        if [ -f "$DASH/.bc-limit-acengage" ]; then
            _DS_MARK_STARTED=$(grep '^STARTED=' "$DASH/.bc-limit-acengage" 2>/dev/null | tail -1 | cut -d= -f2)
        fi
        if [ -n "$_DS_MARK_STARTED" ] && [ "$_DS_MARK_STARTED" = "$_DS_SESS_STARTED" ]; then
            DS_ACTIVE=1
        elif [ "$ICON_EXT" = "No" ] && [ -f "$DASH/.discharge_state" ]; then
            _DS_MON_STARTED=$(grep '^SESSION_STARTED=' "$DASH/.discharge_state" 2>/dev/null | tail -1 | cut -d= -f2)
            _DS_MON_PHASE=$(grep '^PHASE=' "$DASH/.discharge_state" 2>/dev/null | tail -1 | cut -d= -f2)
            if [ "$_DS_MON_STARTED" = "$_DS_SESS_STARTED" ] && \
               { [ "$_DS_MON_PHASE" = "armed" ] || [ "$_DS_MON_PHASE" = "active" ]; }; then
                DS_ACTIVE=1
            fi
        fi
    fi
fi
if [ "$DISPLAY_MODE" = "discharge" ] || [ "$DS_ACTIVE" = "1" ]; then
    ICON="🔋"
elif [ "$ICON_EXT" = "No" ] && [ "$ICON_ISCHG" = "No" ]; then
    ICON="🔴"
elif [ "$DISPLAY_MODE" = "charge_full" ] || [ "$DISPLAY_MODE" = "calibration" ]; then
    ICON="⚡"
elif [ "$ICON_ISCHG" = "Yes" ]; then
    ICON="⚡"
elif [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
    ICON="🔌"
else
    ICON="🔴"
fi
if [ "$ICON_ISCHG" = "Yes" ]; then
    STATE_COLOR="color=#707070"
elif [ "$ICON_EXT" = "Yes" ] && [ "$ICON_ISCHG" = "No" ]; then
    STATE_COLOR="color=#FFFFFF"
else
    STATE_COLOR="color=#E8A0A0"
fi
if [ "$DISPLAY_MODE" = "discharge" ] || [ "$DS_ACTIVE" = "1" ]; then
    FINAL_COLOR="color=#8A9AAB"
elif [ -n "$TEMP_IN" ] && [ "$TEMP_IN" -ge 42 ] 2>/dev/null; then
    FINAL_COLOR="color=#FF3B30"
elif [ -n "$TEMP_IN" ] && [ "$TEMP_IN" -ge 38 ] 2>/dev/null; then
    FINAL_COLOR="color=#FF9500"
else
    FINAL_COLOR="$STATE_COLOR"
fi
# Discharge session status line (discharge build 2026-11-13, design §7):
# read-only — the session file is the authority; the plugin renders
# DISCHARGE_STATUS verbatim when non-empty. The real session file wins
# over the shadow one (shadow = T2 observation mode, zero charging
# effect, labelled as such so it is never mistaken for a real session).
DISCHARGE_STATUS=""
_DS_FILE=""; _DS_SHADOW=0
if [ -f "$DASH/.discharge_session" ]; then
    _DS_FILE="$DASH/.discharge_session"
elif [ -f "$DASH/.discharge_session.shadow" ]; then
    _DS_FILE="$DASH/.discharge_session.shadow"; _DS_SHADOW=1
fi
if [ -n "$_DS_FILE" ]; then
    _DS_TARGET=$(grep '^TARGET=' "$_DS_FILE" 2>/dev/null | tail -1 | cut -d= -f2 | sed 's/^0*//')
    case "$_DS_TARGET" in ''|*[!0-9]*) _DS_TARGET="" ;; esac
    if [ -n "$_DS_TARGET" ] && [ "$_DS_TARGET" -ge 20 ] && [ "$_DS_TARGET" -le 99 ]; then
        _DS_STARTED=$(grep '^STARTED=' "$_DS_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
        _AC_STARTED=""
        if [ -f "$DASH/.bc-limit-acengage" ]; then
            _AC_STARTED=$(grep '^STARTED=' "$DASH/.bc-limit-acengage" 2>/dev/null | tail -1 | cut -d= -f2)
        fi
        if [ "$_DS_SHADOW" = "1" ]; then
            if [ "$ICON_EXT" = "Yes" ]; then
                DISCHARGE_STATUS="Shadow discharge to ${_DS_TARGET}% — parked on AC (log only)"
            else
                DISCHARGE_STATUS="Shadow discharge to ${_DS_TARGET}% — on battery (log only)"
            fi
        elif [ -n "$_AC_STARTED" ] && [ "$_AC_STARTED" = "$_DS_STARTED" ]; then
            # bc-limit holds the manager discharge mode for this
            # session: the pack drains with the cable attached
            # (EXT reads No because the adapter path is dropped).
            DISCHARGE_STATUS="Discharge to ${_DS_TARGET}% — draining on AC (discharge mode)"
        elif [ "$ICON_EXT" = "Yes" ]; then
            DISCHARGE_STATUS="Discharge to ${_DS_TARGET}% — parked on AC (drains on battery)"
            # State-aware wording (full-fix 2026-11-15): an armed
            # session that is thermally blocked, or that already
            # saw battery power, must not render identically to a
            # healthy parked one — on 2026-11-15 a user session sat
            # blocked for over an hour behind the plain parked line.
            # APG_BLOCK (monitor state): 1 = blocked (thermal for
            # user/calibrate, any pause for corrective), 2 =
            # load-bypassed (not a wait). SEEN_BATT: the monitor
            # latched a battery-power observation this session.
            _DS_MODE=$(grep '^MODE=' "$_DS_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
            _DS_PHASE=""; _DS_BLOCK=0; _DS_SEEN=0
            if [ -f "$DASH/.discharge_state" ]; then
                _DS_PHASE=$(grep '^PHASE=' "$DASH/.discharge_state" 2>/dev/null | tail -1 | cut -d= -f2)
                _DS_BLOCK=$(grep '^APG_BLOCK=' "$DASH/.discharge_state" 2>/dev/null | tail -1 | cut -d= -f2)
                _DS_SEEN=$(grep '^SEEN_BATT=' "$DASH/.discharge_state" 2>/dev/null | tail -1 | cut -d= -f2)
                case "$_DS_BLOCK" in ''|*[!0-9]*) _DS_BLOCK=0 ;; esac
                case "$_DS_SEEN" in ''|*[!0-9]*) _DS_SEEN=0 ;; esac
            fi
            if [ "$_DS_BLOCK" = "1" ] && [ "$_DS_MODE" != "corrective" ]; then
                DISCHARGE_STATUS="Discharge to ${_DS_TARGET}% — parked on AC (waiting: battery hot)"
            elif [ "$_DS_PHASE" = "armed" ] && [ "$_DS_SEEN" = "1" ]; then
                DISCHARGE_STATUS="Discharge to ${_DS_TARGET}% — parked on AC (was on battery; unplug to drain)"
            fi
        else
            DISCHARGE_STATUS="Discharging to ${_DS_TARGET}% — on battery"
            _DS_MODE=$(grep '^MODE=' "$_DS_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
            _DS_BLOCK=0
            if [ -f "$DASH/.discharge_state" ]; then
                _DS_BLOCK=$(grep '^APG_BLOCK=' "$DASH/.discharge_state" 2>/dev/null | tail -1 | cut -d= -f2)
                case "$_DS_BLOCK" in ''|*[!0-9]*) _DS_BLOCK=0 ;; esac
            fi
            if [ "$_DS_BLOCK" = "1" ] && [ "$_DS_MODE" != "corrective" ]; then
                DISCHARGE_STATUS="Discharge to ${_DS_TARGET}% — on battery (waiting: battery hot)"
            fi
        fi
    fi
fi
# Calibration run status line (calibrate build 2026-11-14):
# read-only — the run file (owned by the watchdog's supervisor) is
# the authority; the plugin renders CALIBRATION_STATUS verbatim.
CALIBRATION_STATUS=""
if [ -f "$DASH/.calibration_run" ]; then
    _CAL_LEG=$(grep '^LEG=' "$DASH/.calibration_run" 2>/dev/null | tail -1 | cut -d= -f2)
    _CAL_FLOOR=$(grep '^FLOOR=' "$DASH/.calibration_run" 2>/dev/null | tail -1 | cut -d= -f2 | sed 's/^0*//')
    _CAL_WAITING=$(grep '^WAITING=' "$DASH/.calibration_run" 2>/dev/null | tail -1 | cut -d= -f2)
    _CAL_AWAIT=$(grep '^AWAIT=' "$DASH/.calibration_run" 2>/dev/null | tail -1 | cut -d= -f2)
    case "$_CAL_FLOOR" in ''|*[!0-9]*) _CAL_FLOOR="?" ;; esac
    if [ "$_CAL_WAITING" = "1" ]; then
        CALIBRATION_STATUS="Calibration paused at ${PCT_IN:-?}% — tap Resume Calibration"
    elif [ "$_CAL_AWAIT" = "apg" ]; then
        CALIBRATION_STATUS="Calibration: waiting — battery too hot"
    else
        case "$_CAL_LEG" in
            L0)  CALIBRATION_STATUS="Calibration starting…" ;;
            L1)  CALIBRATION_STATUS="Calibrating: charging to 100%" ;;
            L1R) CALIBRATION_STATUS="Calibrating: resting at full (1 h)" ;;
            L2)
                if [ "$_CAL_AWAIT" = "unplug" ]; then
                    CALIBRATION_STATUS="Calibration: unplug to drain to ${_CAL_FLOOR}%"
                else
                    CALIBRATION_STATUS="Calibrating: draining to ${_CAL_FLOOR}%"
                fi
                ;;
            L3)
                if [ "$_CAL_AWAIT" = "ac" ]; then
                    CALIBRATION_STATUS="Calibration: plug in — resting at ${_CAL_FLOOR}%"
                else
                    CALIBRATION_STATUS="Calibrating: resting at the floor (${_CAL_FLOOR}%)"
                fi
                ;;
            L4)  CALIBRATION_STATUS="Calibrating: recharging to 100%" ;;
            L5)  CALIBRATION_STATUS="Calibrating: finishing — restoring your limit" ;;
            *)   CALIBRATION_STATUS="Calibration running" ;;
        esac
    fi
fi
printf 'DISPLAY_MODE=%s\nICON=%s\nSTATE_COLOR=%s\nFINAL_COLOR=%s\nDISCHARGE_STATUS=%s\nCALIBRATION_STATUS=%s\n' "$DISPLAY_MODE" "$ICON" "$STATE_COLOR" "$FINAL_COLOR" "$DISCHARGE_STATUS" "$CALIBRATION_STATUS"
exit 0

