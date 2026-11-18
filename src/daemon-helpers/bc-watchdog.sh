#!/bin/bash
#
# bc-watchdog.sh — Battery Commander single watchdog (W3).
#
# Replaces, in one script (design §5, tasks W3.1–W3.5):
#   * guardian.sh            (state machine: layers 1, 2b, 3/3a, 4, 4b, heartbeat)
#   * enforce_watchdog.sh    (escalation ladder COUNT 1/4/8/16)
#   * charge_upper_watcher.sh (no separate watcher; its exits fold into the
#     enforcer + this watchdog's mode reconciliation)
#   * consolidated_checks.sh (the 10-minute fan-out to sailing_tracker,
#     adaptive, ensure_limit, system_guard — folded in, time-gated)
#   * guardian's inlined LAYER 8 daemon watchdog (NOT the dead
#     daemon_watchdog.sh file — W0 correction C2).
#
# Run interval: 60 s (one LaunchAgent tick). The interval is stated here so
# the ladder's COUNT->time mapping is verifiable (W3.4):
#   COUNT 1  = first violating tick (reapply)
#   COUNT 4  = 240 s of continuous violation (daemon check + reapply)
#   COUNT 8  = 480 s of continuous violation (corrective-discharge gate)
#   COUNT 16 = 960 s of continuous violation (CRITICAL notify, cap 3/episode)
# Sub-cadences (time-gated, survive missed ticks):
#   guardian layers: every tick (60 s; guardian was 120 s — the reads are
#     cheap and the extra frequency is harmless)
#   consolidated children: every 600 s (their original cadence)
#   heartbeat: every tick, to .watchdog.log only (not actions.log)
#
# Single ownership (W3): this script is the ONLY drift corrector. No other
# component corrects config<->BCLM drift. (ensure_limit.sh and
# self_healing.sh still contain drift-reapply code today; their BC fixes
# (W4.4 / later) must DROP it — this watchdog owns drift from W3 onward.
# Until those fixes land, the watchdog is not installed, so there is no
# live overlap.)
#
# BC rules — this script NEVER:
#   * calls battopt (any subcommand) or parses battopt output
#   * runs sudo (unprivileged; only the root LaunchDaemon writes BCLM)
#   * writes BCLM or calls `bc-limit --write` (only the LaunchDaemon-run
#     enforcer writes BCLM; this script writes CONFIG only, via
#     bc_reapply_limit, and the enforcer picks it up within 60 s)
#   * auto-loads the LaunchDaemon (loading is the Phase C gate; if the
#     daemon is not loaded this script logs + notifies, nothing more)
#   * auto-resets or calls force_reset (W2.6 rule: log + notify only)
#   * spawns sd_watcher.sh or charge_upper_watcher.sh (no BC discharge
#     mechanism in v1; the corrective action is hold-and-wait)
#   * sources a data file or evals output (config is parsed as KEY=value)
#
# Protection layers (design §5 — all gate the CORRECTIVE DISCHARGE, never
# the BCLM=10 hold reapply; the hold is always allowed, it is the safe action):
#   (a) Overshoot UPPER+2: the corrective discharge fires only at
#       PCT > UPPER+2. The hold reapply fires at any PCT > UPPER.
#   (b) APG guard: a thermal pause (.apg_paused) suppresses the corrective
#       discharge. It never suppresses the hold reapply.
#   (c) Prepare warning: unchanged, lives in arm_sleep.sh (W4.1), not here.
#   (d) Post-wake delay: 120 s (design range 60-120 s), discharge-only.
#       Post-wake % readings are briefly unreliable; 120 s is the
#       conservative end of the approved range.
#
# APG (Adaptive Power Governor) — fresh classification, never the stale file:
#   .apg_state is frozen "green" since Oct 10 and the old governor is inert
#   (its battopt-status input is dead; zero apg: log lines ever). On the
#   first BC run this script treats APG state as UNKNOWN: it does NOT read
#   the stale .apg_state as a previous state, classifies fresh from
#   bc-status TempBatteryPack + sysctl load, writes .apg_state + the
#   .bc_apg_init marker, and logs the establishment. Later runs read the
#   previous state from .apg_state (written by this script) with the
#   original hysteresis. Temp source: TempBatteryPack (the old governor's
#   TEMP came from battopt status — most likely a battery sensor, TB0T is
#   the unproven candidate; the pack temp is the closest BC equivalent).
#   If the temp is unreadable, no classification is made (state stays
#   unknown) — the old governor exited early on missing TEMP too.
#   NOTE: bc-limit does NOT read .apg_paused (verified in bc-limit.c) —
#   the pause marker gates this watchdog's corrective discharge and the
#   other components that check it (ac_watcher, ensure_limit,
#   self_healing). A full enforcer-side thermal pause (hold below UPPER
#   while hot) needs bc-limit to read .apg_paused — flagged for W6.
#
# Post-wake delay — wake-age source:
#   Primary: $DASH/.last_wake (epoch seconds, written by powerwatch on
#   wake — W5.2 landed in C and the file exists, verified 2026-11-11).
#   Fallback: a single `pmset -g log` scan for the last Wake line,
#   ONLY when a corrective discharge is actually being contemplated
#   (PCT > UPPER+2, AC present, not APG-paused) — never on the hot path.
#   Fail-open (WAKE_AGE=999999) if no Wake line is found or the date parse
#   fails, and log it (design §5).
#
# Throttle: the old Layer 15 battery-mode throttle (.throttle_helper.sh)
# never existed — the source lines are deleted, not ported. There is no
# throttle layer in this watchdog (v1). If battery back-off is wanted
# later, specify it inside this file, never as a hidden sourced helper.
#
# State files this script owns (writes):
#   .watchdog.log .enforce_state .enforce_last_discharge
#   .enforce_last_critical .enforce_crit_count .enforce_hb
#   .drift_state .daemon_check_state .bc_apg_init .overshoot_state
#   .watchdog_consolidated_last .notify_apg .notify_drift .notify_daemon
#   .bclm_unreadable_last .wake_age_unknown_last .watchdog_prev_pct
#   .apg_state .apg_paused .apg_pause_reason (APG classifier)
#   .discharge_state .discharge_cooldown discharge.log (discharge
#   session monitor, D2 — plus deleting the supervised session file)
#   .charge_target (clears it when done/stale), .active_mode (atomic
#   reconcile only), .hold_since, .layer4b_hold, .sd_session + .active_token
#   (stale/phantom cleanup only)
# It READS (never writes): config, BCLM, ioreg, bc-status, .apg_off,
# .user_shutdown, the consolidated children (invokes, does not edit).
#
# Deploy note: this file is built, not installed. It needs ONE LaunchAgent
# (60 s, label com.batterycommander.watchdog) and the three old plists
# (guardian 120 s, enforce 15 s, consolidated 600 s) disabled — that wiring
# is W6 (agent relabel), not W3. The live system still runs the old
# watchdogs until deploy.
#
# Cadence note for the reader: PCT uses the FLOOR formula (CUR*100/MAX)
# — same as dispatch's get_pct() and the enforcer bc-limit (M8,
# consolidation 2026-11-13). The enforcer (bc-limit) is the authority,
# this script only observes.

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
# The state dir must exist before any log/state write below (audit
# 2026-11-11, W28 — a missing dir made log() fail silently on every tick).
mkdir -p "$DASH" 2>/dev/null || true
BC_BUILD_DIR="${BC_BUILD_DIR:-$HOME/Projects/BattOpt-CC-Release/battopt-project/bc-build}"
BC_LIMIT="$BC_BUILD_DIR/bc-limit"
BC_STATUS="$BC_BUILD_DIR/bc-status"
BC_CANDIDATES="$BC_BUILD_DIR/bc-candidates"
LOG="$DASH/actions.log"
WLOG="$DASH/.watchdog.log"
CFG="$DASH/config"
# Notifications are app-native (final cleanup 2026-11-18): this
# script only appends to $DASH/.notify_queue via _notify_queue;
# BatteryCommander.app posts them itself. No external notifier
# path exists in the product anymore (the old NOTIFIER variable
# is gone).

# Run interval in seconds (see the header: COUNT->time mapping).
BC_WATCHDOG_INTERVAL=60
# Protection-layer constants (design §5).
POST_WAKE_DELAY_S=120
DRIFT_ALERT_AFTER_S=300
DISCHARGE_COOLDOWN_S=300
CRIT_COOLDOWN_S=300
CONSOLIDATED_EVERY_S=600

ENFORCE_STATE="$DASH/.enforce_state"
ENFORCE_LAST_DISCH="$DASH/.enforce_last_discharge"
ENFORCE_LAST_CRIT="$DASH/.enforce_last_critical"
ENFORCE_CRIT_COUNT="$DASH/.enforce_crit_count"
ENFORCE_HB="$DASH/.enforce_hb"
DRIFT_STATE="$DASH/.drift_state"
DAEMON_CHECK_STATE="$DASH/.daemon_check_state"
BC_APG_INIT="$DASH/.bc_apg_init"
OVERSHOOT_STATE="$DASH/.overshoot_state"
CONSOLIDATED_LAST="$DASH/.watchdog_consolidated_last"
APG_STATE="$DASH/.apg_state"
APG_PAUSED="$DASH/.apg_paused"
APG_PAUSE_REASON="$DASH/.apg_pause_reason"
APG_OFF="$DASH/.apg_off"
PREV_PCT="$DASH/.watchdog_prev_pct"
PREV_CUR="$DASH/.watchdog_prev_cur"
OVERSHOOT_NOTIFY_MARKER="$DASH/.notify/overshoot_episode"

# Guard: respect shutdown (same as guardian / enforce_watchdog).
if [ -e "$DASH/.user_shutdown" ]; then
    exit 0
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] watchdog: $1" >> "$LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$WLOG"
    # Rotate actions.log at 100 KB, keep the last 500 lines (the
    # cleanup_logs.sh pattern; same as dispatch's log()). Best-effort.
    local _log_size
    _log_size=$(stat -f %z "$LOG" 2>/dev/null || echo 0)
    if [ "${_log_size:-0}" -gt 102400 ]; then
        tail -500 "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv "$LOG.tmp.$$" "$LOG" 2>/dev/null || rm -f "$LOG.tmp.$$" 2>/dev/null
    fi
}

# _is_quiet_hour — 1 if the hour is in quiet hours (23:00-08:00), else 0.
# Non-critical notifications are suppressed in quiet hours (the plugin's
# discipline); critical ones bypass it.
_is_quiet_hour() {
    local _h
    _h=$(date +%H 2>/dev/null || echo 12)
    case "$_h" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$_h" -ge 23 ] || [ "$_h" -lt 8 ]; then return 0; fi
    return 1
}

# _notify_queue <title> <body> [sound] — app-native notification
# transport (final cleanup 2026-11-18, owner order): append ONE
# title<TAB>body[<TAB>sound] line to $DASH/.notify_queue;
# BatteryCommander.app drains the queue on its 10 s refresh
# cadence and posts each line itself via UNUserNotificationCenter
# (the app name + icon are automatic). The optional sound field
# maps in the app: "Basso" -> the Basso system sound, "default"
# -> the default sound, absent -> silent. Tabs/newlines in the
# text are flattened so one call is always exactly one line.
_notify_queue() {
    local _t _b _s
    _t=$(printf '%s' "$1" | tr '\n\t' '  ')
    _b=$(printf '%s' "$2" | tr '\n\t' '  ')
    _s=$(printf '%s' "${3:-}" | tr '\n\t' '  ')
    if [ -n "$_s" ]; then
        printf '%s\t%s\t%s\n' "$_t" "$_b" "$_s" >> "$DASH/.notify_queue" 2>/dev/null || true
    else
        printf '%s\t%s\n' "$_t" "$_b" >> "$DASH/.notify_queue" 2>/dev/null || true
    fi
}

# notify_ratelimited <key> <cooldown_s> <critical:0|1> <title> <message>
# Best-effort desktop notification, at most once per <cooldown_s> per key.
# Non-critical notifications are skipped in quiet hours (logged only).
# The per-key last-notify epoch lives in $DASH/.notify_<key>.
notify_ratelimited() {
    local _key="$1" _cool="$2" _crit="$3" _title="$4" _msg="$5"
    local _now _last_file _last=0
    _now=$(date +%s 2>/dev/null || echo 0)
    _last_file="$DASH/.notify_${_key}"
    [ -f "$_last_file" ] && _last=$(cat "$_last_file" 2>/dev/null || echo 0)
    case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
    [ $(( _now - _last )) -lt "$_cool" ] && return 0
    if [ "$_crit" != "1" ] && _is_quiet_hour; then
        return 0
    fi
    _notify_queue "$_title" "$_msg"
    echo "$_now" > "$_last_file" 2>/dev/null || true
}

# Shared session guard (state_guard.sh provides guard_session_active,
# guard_token, guard_session_begin; the watchdog sources the live copy,
# same as guardian did).
if [ -f "$DASH/state_guard.sh" ]; then
    # shellcheck disable=SC1091
    source "$DASH/state_guard.sh" || exit 1
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] watchdog: state_guard.sh missing — exiting" >> "$WLOG"
    exit 1
fi

# _transient_session_active — 0 if a TRANSIENT session owns the state
# (discharge / charge_full / calibration). Hold is NOT transient: it is the
# steady state, so the ladder and the daemon-load reapply must NOT skip on
# hold. The old check (guard_session_active, which includes hold) left the
# ladder dead for hours of normal holding — a stuck-charging fault could
# never escalate (audit 2026-11-11, M3). The transient modes are the ones
# where a violation is EXPECTED (charging past UPPER is the point of
# charge_full), so only they skip the ladder.
_transient_session_active() {
    case "$MODE" in
        discharge|charge_full|calibration) return 0 ;;
        *) return 1 ;;
    esac
}

# _daemon_loaded — 0 if the BC enforcer LaunchDaemon is loaded. Uses
# `launchctl print system/<label>`: a user shell CANNOT see a system
# daemon with `launchctl list` (verified 2026-11-11 — the old check
# always reported "not loaded"), but `print system/` works.
_daemon_loaded() {
    launchctl print system/com.batterycommander.bclimit >/dev/null 2>&1
}

# read_config — (re-)parse the canonical config as KEY=value into the
# globals. Never `source` a data file. (Same function as dispatch W1.1.)
read_config() {
    local _cfg_key _cfg_val
    if [ -f "$CFG" ]; then
        while IFS='=' read -r _cfg_key _cfg_val; do
            case "$_cfg_key" in
                LAST_UPPER) LAST_UPPER="$_cfg_val" ;;
                LAST_LOWER) LAST_LOWER="$_cfg_val" ;;
                SAILING) SAILING="$_cfg_val" ;;
                SAIL_GAP) SAIL_GAP="$_cfg_val" ;;
                DISCHARGE_MAX_MINUTES) DISCHARGE_MAX_MINUTES="$_cfg_val" ;;
                DISCHARGE_PARK_TIMEOUT_MIN) DISCHARGE_PARK_TIMEOUT_MIN="$_cfg_val" ;;
                DISCHARGE_FLIP_COOLDOWN_MIN) DISCHARGE_FLIP_COOLDOWN_MIN="$_cfg_val" ;;
                DISCHARGE_FLOOR_ABS) DISCHARGE_FLOOR_ABS="$_cfg_val" ;;
                DISCHARGE_CONFIRM_TICKS) DISCHARGE_CONFIRM_TICKS="$_cfg_val" ;;
            esac
        done < "$CFG"
    fi
}

# Defaults — used ONLY when no config file exists. They match the live
# config (86/85, SAILING=false, SAIL_GAP=1); see design §3.5.
LAST_UPPER=86
LAST_LOWER=85
SAILING=false
SAIL_GAP=1
# Discharge tunables (discharge-design §4.3) — safe defaults; the
# config may override them, invalid values fall back to the default.
DISCHARGE_MAX_MINUTES=240
DISCHARGE_PARK_TIMEOUT_MIN=30
DISCHARGE_FLIP_COOLDOWN_MIN=30
DISCHARGE_FLOOR_ABS=20
DISCHARGE_CONFIRM_TICKS=2
read_config
if [ ! -f "$CFG" ]; then
    log "config missing — using defaults 86/85 (self_healing recreates it; check its 85/80 fallback)"
fi
case "$LAST_UPPER" in ''|*[!0-9]*) LAST_UPPER=86 ;; esac
case "$LAST_LOWER" in ''|*[!0-9]*) LAST_LOWER=85 ;; esac

# atomic_write <file> <content> — tmp+mv (no partial writes).
atomic_write() {
    local file="$1" content="$2"
    local tmp="${file}.tmp.$$"
    printf '%s' "$content" > "$tmp" && mv "$tmp" "$file"
}

# validate_int <value> <min> <max> — 0 if an integer in range.
validate_int() {
    local v="$1" min="$2" max="$3"
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    [ "$v" -ge "$min" ] && [ "$v" -le "$max" ] || return 1
    return 0
}

# Discharge tunables: fall back to defaults on any invalid value.
validate_int "$DISCHARGE_MAX_MINUTES" 1 10080 || DISCHARGE_MAX_MINUTES=240
validate_int "$DISCHARGE_PARK_TIMEOUT_MIN" 1 1440 || DISCHARGE_PARK_TIMEOUT_MIN=30
validate_int "$DISCHARGE_FLIP_COOLDOWN_MIN" 0 1440 || DISCHARGE_FLIP_COOLDOWN_MIN=30
validate_int "$DISCHARGE_FLOOR_ABS" 1 99 || DISCHARGE_FLOOR_ABS=20
validate_int "$DISCHARGE_CONFIRM_TICKS" 1 10 || DISCHARGE_CONFIRM_TICKS=2

# save_cfg — write the canonical config atomically from the globals.
# The config is parsed as KEY=value; it is never sourced.
save_cfg() {
    atomic_write "$CFG" "LAST_UPPER=$LAST_UPPER
LAST_LOWER=$LAST_LOWER
SAILING=$SAILING
SAIL_GAP=$SAIL_GAP
"
}

# === Read-only status sources (no sudo, no battopt) ===
#   %      — ioreg (CurrentCapacity*100/MaxCapacity, floor — M8 parity)
#   BCLM   — bc-candidates (read-only SMC reader)
#   temp   — bc-status TempBatteryPack (Key: value)
#   load   — sysctl vm.loadavg
#   limits — the canonical config (KEY=value), never BCLM.

# read_snapshot — one ioreg call per tick; parses PCT, EXT, ISCHG, NCR,
# CUR, MAX into globals. Returns 1 if ioreg yields nothing usable.
read_snapshot() {
    local _snap
    _snap=$(ioreg -rn AppleSmartBattery 2>/dev/null) || return 1
    [ -n "$_snap" ] || return 1
    CUR=$(printf '%s\n' "$_snap" | grep -E '"CurrentCapacity" = [0-9]+' | grep -oE '[0-9]+' | head -1)
    MAX=$(printf '%s\n' "$_snap" | grep -E '"MaxCapacity" = [0-9]+' | grep -oE '[0-9]+' | head -1)
    EXT=$(printf '%s\n' "$_snap" | grep -E '"ExternalConnected" = [A-Za-z]+' | awk '{print $3}')
    ISCHG=$(printf '%s\n' "$_snap" | grep -E '"IsCharging" = [A-Za-z]+' | awk '{print $3}')
    AMP=$(printf '%s\n' "$_snap" | grep -E '"Amperage" = [0-9]+' | grep -oE '[0-9]+' | head -1)
    NCR=$(printf '%s\n' "$_snap" | grep -oE '"NotChargingReason"=[0-9]+' | grep -oE '[0-9]+' | head -1)
    [ -n "$CUR" ] && [ -n "$MAX" ] && [ "$MAX" -gt 0 ] 2>/dev/null || return 1
    PCT=$(( CUR * 100 / MAX ))
    # Amperage is an unsigned 64-bit wrap when negative; only the sign is
    # used (C2 confirmation), so collapse any wrapped value to -1.
    case "$AMP" in ''|*[!0-9]*) AMP="" ;; *) [ "$AMP" -gt 1000000 ] && AMP=-1 ;; esac
    [ -z "$NCR" ] && NCR="?"
    [ -z "$EXT" ] && EXT="?"
    [ -z "$ISCHG" ] && ISCHG="?"
    return 0
}

# bc_read_bclm — print the BCLM value (10 = hold, 100 = charging allowed),
# or nothing if it cannot be read. Read-only; never writes.
# (Same function as dispatch W1.1.)
bc_read_bclm() {
    local _bin="$BC_CANDIDATES" _out _v
    [ -x "$_bin" ] || return 1
    _out=$("$_bin" 2>/dev/null) || return 1
    _v=$(printf '%s\n' "$_out" | grep '^BCLM:' | grep -oE 'value=[0-9]+' | grep -oE '[0-9]+' | head -1)
    [ -n "$_v" ] && printf '%s' "$_v" && return 0
    return 1
}

# bc_status_value <Key> — print the value for Key from bc-status output
# (format is "Key: value" with units, e.g. "Capacity: 85.9%").
# Returns 1 if bc-status is missing or the key is absent.
# (Same function as dispatch W1.1.)
bc_status_value() {
    local _key="$1" _out _line
    [ -x "$BC_STATUS" ] || return 1
    _out=$("$BC_STATUS" 2>/dev/null) || return 1
    _line=$(printf '%s\n' "$_out" | grep "^${_key}:" | head -1) || return 1
    [ -n "$_line" ] || return 1
    printf '%s' "${_line#*: }" | tr -d '[:space:]'
}

# _bc_backend — the selected enforcement backend (cached per run).
# From `bc-limit --probe` (read-only). "unknown" if the probe cannot run.
# (Same function as dispatch W1.1.)
_bc_backend() {
    [ -n "${_BC_BACKEND:-}" ] && { printf '%s' "$_BC_BACKEND"; return 0; }
    if [ -x "$BC_LIMIT" ]; then
        _BC_BACKEND=$("$BC_LIMIT" --probe 2>/dev/null | grep -oE 'backend=[a-z0-9]+' | head -1 | cut -d= -f2)
    fi
    [ -n "${_BC_BACKEND:-}" ] || _BC_BACKEND="unknown"
    printf '%s' "$_BC_BACKEND"
}

# _bc_verify <UPPER> <LOWER> — verifies the BC backend state after a config
# write: (1) the canonical config reads back the requested limits (the
# limit % lives in the config, never in the SMC — the config read-back IS
# the verification); (2) BCLM + % are readable. Single retry (sleep 2,
# retry once). (Same helper as dispatch W1.1.)
_bc_verify() {
    local _u="$1" _l="$2" _try _cu _cl _pct _bclm
    for _try in 1 2; do
        _cu=""; _cl=""; _pct=""; _bclm=""
        if [ -f "$CFG" ]; then
            _cu=$(grep '^LAST_UPPER=' "$CFG" 2>/dev/null | cut -d= -f2-)
            _cl=$(grep '^LAST_LOWER=' "$CFG" 2>/dev/null | cut -d= -f2-)
        fi
        _pct=$(get_pct_watchdog) || true
        _bclm=$(bc_read_bclm) || true
        if [ "$_cu" = "$_u" ] && [ "$_cl" = "$_l" ] && [ -n "$_pct" ] && [ -n "$_bclm" ]; then
            return 0
        fi
        [ "$_try" = "1" ] && sleep 2
    done
    return 1
}

# get_pct_watchdog — battery % from the already-read snapshot (no extra
# ioreg call). Falls back to a fresh ioreg read if no snapshot exists.
get_pct_watchdog() {
    if [ -n "${PCT:-}" ]; then
        printf '%s' "$PCT"
        return 0
    fi
    read_snapshot >/dev/null 2>&1 && printf '%s' "$PCT" || return 1
}

# bc_reapply_limit <UPPER> <LOWER> — the watchdog's reapply (mirrors
# dispatch's bc_apply_limit, W1.1; the two must stay in sync).
# Steps: (1) validate U/L; (2) read current state (BCLM, %) — fail BEFORE
# any write if the state is unreadable; (3) write the config atomically
# (only after that verification); (4) verify by re-reading (_bc_verify).
# The enforcer picks the new config up on its next 60 s run. Returns 0 on
# success, 1 on failure (config NOT written on failure).
# NOTE: when the config already holds the requested limits, the write is a
# rewrite of identical values — harmless, and it proves the config path is
# writable. The enforcer does the actual BCLM write, not this script.
bc_reapply_limit() {
    local _u="$1" _l="$2" _pct _bclm
    validate_int "$_u" 50 100 || { log "bc_reapply_limit: invalid upper ($_u)"; return 1; }
    validate_int "$_l" 20 99 || { log "bc_reapply_limit: invalid lower ($_l)"; return 1; }
    [ "$_l" -lt "$_u" ] || { log "bc_reapply_limit: lower ($_l) must be below upper ($_u)"; return 1; }
    _pct=$(get_pct_watchdog) || true
    _bclm=$(bc_read_bclm) || true
    if [ -z "$_pct" ]; then
        log "bc_reapply_limit: no battery reading — config NOT written"
        return 1
    fi
    if [ -z "$_bclm" ]; then
        log "bc_reapply_limit: BCLM unreadable — config NOT written (enforcer state unknown)"
        return 1
    fi
    LAST_UPPER="$_u"
    LAST_LOWER="$_l"
    save_cfg
    if _bc_verify "$_u" "$_l"; then
        log "bc_reapply_limit: config written $_u/$_l (pct=$_pct BCLM=$_bclm) — enforcer picks it up within 60s"
        _REAPPLIED_THIS_TICK=1
        return 0
    fi
    log "bc_reapply_limit: verify failed after config write $_u/$_l (pct=$_pct BCLM=$_bclm)"
    return 1
}

# wake_age — seconds since the last full Wake. Prints the age (or 999999
# fail-open). Primary: $DASH/.last_wake (epoch, written by powerwatch on
# wake — W5.2 must add that write; the file does not exist today).
# Fallback: one `pmset -g log` scan for the last Wake line. This function
# is called ONLY when a corrective discharge is actually being contemplated
# (PCT > UPPER+2, AC present, not APG-paused) — never on the hot path.
# Fail-open (999999) if no Wake line is found or the date parse fails.
wake_age() {
    local _lw _now _age
    _now=$(date +%s 2>/dev/null || echo 0)
    if [ -f "$DASH/.last_wake" ]; then
        _lw=$(cat "$DASH/.last_wake" 2>/dev/null || echo "")
        case "$_lw" in ''|*[!0-9]*) ;; *)
            _age=$(( _now - _lw ))
            [ "$_age" -lt 0 ] && _age=999999
            printf '%s' "$_age"
            return 0
            ;;
        esac
    fi
    local _line _ts _epoch _now2 _wlast=0
    _line=$(pmset -g log 2>/dev/null | awk '$4=="Wake" && $5=="Wake"' | tail -1)
    if [ -n "$_line" ]; then
        _ts=$(printf '%s' "$_line" | awk '{print $1" "$2" "$3}')
        _epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$_ts" "+%s" 2>/dev/null)
        if [ -n "$_epoch" ]; then
            _age=$(( _now - _epoch ))
            [ "$_age" -lt 0 ] && _age=999999
            printf '%s' "$_age"
            return 0
        fi
    fi
    # Fail-open (999999), logged at most once per hour so a missing Wake
    # line does not spam the log on every overshoot tick.
    _now2=$(date +%s 2>/dev/null || echo 0)
    [ -f "$DASH/.wake_age_unknown_last" ] && _wlast=$(cat "$DASH/.wake_age_unknown_last" 2>/dev/null || echo 0)
    case "$_wlast" in ''|*[!0-9]*) _wlast=0 ;; esac
    if [ $(( _now2 - _wlast )) -ge 3600 ]; then
        log "wake_age: no Wake line found or date parse failed — fail-open (999999)"
        echo "$_now2" > "$DASH/.wake_age_unknown_last"
    fi
    printf '999999'
}

# === APG (Adaptive Power Governor) — fresh classification ===
# Thresholds + hysteresis are the old adaptive_governor.sh values,
# unchanged (red: temp >42 or load >6; yellow: temp >=38 or load >=4).
# Temp: bc-status TempBatteryPack. Load: sysctl vm.loadavg field 2.
# The classifier runs every tick; it ACTS only on a state change (or on
# first-run establishment). Yellow/red touch .apg_paused; green removes it.
# APG state values: green | yellow | red | unknown (unknown = no temp
# reading; nothing is touched and no state is written).

# _apg_reason_sync <temp-int-or-empty> — maintain .apg_pause_reason
# next to .apg_paused (apggate, 2026-11-16). bc-limit v1.4+ reads
# the reason to gate ONLY its resume suppression: a load-only pause
# must not block a user-initiated charge (owner's rule, 2026-11-15),
# while a thermal pause keeps full force. Reason semantics:
#   thermal — battery temp >= 38 C (the APG yellow temp threshold),
#             or temp unavailable (fail safe: an unknown temp
#             counts as thermal, exactly like _disch_apg_thermal);
#   load    — paused with a present temp below 38 C, i.e. the pause
#             is held by CPU load / hysteresis alone.
# Written atomically on EVERY tick while the pause exists (the
# reason can flip without an APG state change — e.g. temp drifting
# across 38 C inside a load-held yellow); removed whenever the
# pause is gone. .apg_paused itself stays a pure existence flag —
# every other consumer keeps testing existence only.
_apg_reason_sync() {
    if [ -f "$APG_PAUSED" ]; then
        if [ -n "$1" ] && [ "$1" -lt 38 ] 2>/dev/null; then
            atomic_write "$APG_PAUSE_REASON" "load
"
        else
            atomic_write "$APG_PAUSE_REASON" "thermal
"
        fi
    else
        rm -f "$APG_PAUSE_REASON" 2>/dev/null || true
    fi
}

apg_classify() {
    local _raw_temp _temp _temp_int _load _load_int
    local _prev _new _first_run=0

    # The off-switch: a deliberate user opt-out. Skip silently (the
    # heartbeat line still records APG=off). Clear a stale .apg_paused:
    # an opt-out must not leave a thermal pause suppressing discharge
    # forever (audit 2026-11-11, W3).
    if [ -f "$APG_OFF" ]; then
        APG="off"
        rm -f "$APG_PAUSED" 2>/dev/null || true
        _apg_reason_sync ""
        return 0
    fi

    _raw_temp=$(bc_status_value "TempBatteryPack") || _raw_temp=""
    _temp=$(printf '%s' "$_raw_temp" | tr -dc '0-9.')
    case "$_temp" in ''|*[!0-9.]*) _temp="" ;; esac
    if [ -z "$_temp" ]; then
        # No temp reading: no classification (the old governor exited early
        # on missing TEMP too). State stays unknown; .apg_paused is left
        # exactly as it is — an unknown thermal state must not silently
        # clear or set the pause marker.
        APG="unknown"
        _apg_reason_sync ""
        return 0
    fi
    _temp_int=${_temp%.*}
    case "$_temp_int" in ''|*[!0-9]*) _temp_int=0 ;; esac

    _load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
    _load_int=${_load%.*}
    case "$_load_int" in ''|*[!0-9]*) _load_int=0 ;; esac

    # Previous state: ONLY from a file this watchdog wrote (the .bc_apg_init
    # marker proves it). The stale pre-BC .apg_state ("green" since Oct 10)
    # is never trusted as a previous state.
    if [ -f "$BC_APG_INIT" ] && [ -f "$APG_STATE" ]; then
        _prev=$(cat "$APG_STATE" 2>/dev/null | tr -d '[:space:]')
        case "$_prev" in green|yellow|red) ;; *) _prev="unknown" ;; esac
    else
        _prev="unknown"
        _first_run=1
    fi

    # Classify from current readings.
    if [ "$_temp_int" -gt 42 ] || [ "$_load_int" -gt 6 ]; then
        _new="red"
    elif [ "$_temp_int" -ge 38 ] || [ "$_load_int" -ge 4 ]; then
        _new="yellow"
    else
        _new="green"
    fi

    # Hysteresis (old governor's rules) — skipped on first-run establishment
    # (there is no previous state to transition from).
    if [ "$_first_run" = "0" ]; then
        # Red -> Green: must pass through Yellow unless cooled by 2C.
        if [ "$_prev" = "red" ] && [ "$_new" = "green" ]; then
            if [ "$_temp_int" -gt 40 ] || [ "$_load_int" -gt 5 ]; then
                _new="yellow"
            fi
        fi
        # Yellow -> Green: must cool 1C below threshold.
        if [ "$_prev" = "yellow" ] && [ "$_new" = "green" ]; then
            if [ "$_temp_int" -ge 37 ] || [ "$_load_int" -ge 3 ]; then
                _new="yellow"
            fi
        fi
    fi

    APG="$_new"
    APG_TEMP="$_temp"
    APG_LOAD="$_load"

    # Act only on a change (or on first-run establishment).
    if [ "$_first_run" = "1" ] || [ "$_new" != "$_prev" ]; then
        case "$_new" in
            green)
                if [ -f "$APG_PAUSED" ]; then
                    rm -f "$APG_PAUSED"
                fi
                if [ "$_first_run" = "1" ]; then
                    log "APG: state established fresh GREEN (T=${_temp}C L=${_load}) — stale .apg_state ignored"
                else
                    log "APG: state GREEN (T=${_temp}C L=${_load}) — charging resumed"
                    # (notification policy 2026-11-11: APG is automatic — log only, no notify)
                fi
                ;;
            yellow)
                touch "$APG_PAUSED"
                log "APG: state YELLOW (T=${_temp}C L=${_load}) — corrective discharge suppressed"
                # (notification policy 2026-11-11: YELLOW is the normal protective state — log only)
                ;;
            red)
                touch "$APG_PAUSED"
                log "APG: state RED (T=${_temp}C L=${_load}) — corrective discharge suppressed"
                # (notification policy 2026-11-11: RED is handled by the guard; thermal alerts come from plugin temp_critical — log only)
                ;;
        esac
        printf '%s\n' "$_new" > "$APG_STATE"
        touch "$BC_APG_INIT"
    fi
    _apg_reason_sync "$_temp_int"
    return 0
}

# heartbeat — one line per tick to .watchdog.log ONLY (not actions.log).
# Same fields as guardian's heartbeat, with BCLM + backend + APG instead
# of the SMC limit values (there is no SMC limit % in BC).
heartbeat() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] heartbeat: PCT=$PCT BCLM=${BCLM:-?} cfg=$LAST_UPPER/$LAST_LOWER NCR=${NCR:-?} EXT=${EXT:-?} IsChg=${ISCHG:-?} mode=${MODE:-?} APG=${APG:-?} backend=${BACKEND:-?}" >> "$WLOG"
}

# === Guardian sections (ported from guardian.sh) ===
# The actuators are BC now: BCLM read (not battopt status), config write
# (not battopt limit), no discharge process in v1 (hold-and-wait).

SESSION_FILE="$DASH/.sd_session"

# _set_overshoot_state / _clear_overshoot_state — the overshoot episode
# marker ($DASH/.overshoot_state, "EPOCH|PCT"). One log line per episode.
_set_overshoot_state() {
    if [ ! -f "$OVERSHOOT_STATE" ]; then
        atomic_write "$OVERSHOOT_STATE" "$(date +%s)|$PCT
"
    fi
}
_clear_overshoot_state() {
    rm -f "$OVERSHOOT_STATE" 2>/dev/null || true
}

# _reconcile_mode_after_discharge <tag> — clear the discharge session and
# set .active_mode to hold (if BCLM=10 + AC + not charging) or idle.
# Atomic .active_mode write (tmp+mv, guardian L3a pattern). The mode
# write is a state reconciliation, not a session mutation (same class as
# guardian's direct .active_mode writes in L2b/L4b).
_reconcile_mode_after_discharge() {
    local _tag="$1"
    rm -f "$SESSION_FILE" "$DASH/.active_token"
    if [ "${BCLM:-}" = "10" ] && [ "$EXT" = "Yes" ] && [ "$ISCHG" = "No" ]; then
        atomic_write "$DASH/.active_mode" "hold
"
        MODE="hold"
        date +%s > "$DASH/.hold_since" 2>/dev/null || true
        log "$_tag: mode -> hold"
    else
        atomic_write "$DASH/.active_mode" "idle
"
        MODE="idle"
        log "$_tag: mode -> idle"
    fi
}

# ============================================================
# STAY AWAKE (ON BATTERY) GUARD (final cleanup 2026-11-18)
# The toggle (dispatch stay_awake_batt_toggle) owns the marker
# $DASH/.stay_awake_batt (content SINCE=<epoch>) and the initial
# pmset -b disablesleep 1 write. This section owns the ongoing
# truth, in priority order:
#   1. SUPERSEDED — .sleep_mode changed after the toggle was
#      turned on: the mode's own posture governs. Stand down
#      (marker removed); clear the battery bit too, UNLESS the
#      new mode is an AC stay-awake mode (download/presentation
#      set disablesleep themselves).
#   2. PACK PROTECTION — on battery at <=20%: auto-revert
#      (pmset -b disablesleep 0, marker removed, owner notified).
#   3. DRIFT — the effective SleepDisabled reads 0 while the
#      marker stands (cleared externally): re-assert. Catalina
#      stores disablesleep as one system-wide value (probed
#      2026-11-18), so the effective read is the truth on any
#      power source; rule 2 stays battery-only (it protects the
#      pack while draining).
# ============================================================
section_stay_awake_batt() {
    local _marker="$DASH/.stay_awake_batt"
    [ -f "$_marker" ] || return 0
    local _mode_file="$DASH/.sleep_mode"
    # 1. Superseded by a later Sleep Mode change?
    if [ -f "$_mode_file" ] && [ "$_mode_file" -nt "$_marker" ]; then
        local _mode
        _mode=$(cat "$_mode_file" 2>/dev/null | tr -d '[:space:]')
        rm -f "$_marker"
        case "$_mode" in
            download|presentation)
                log "STAY_AWAKE_BATT: superseded by sleep_mode=$_mode — marker cleared (the mode owns disablesleep)"
                ;;
            *)
                sudo -n /usr/bin/pmset -b disablesleep 0 >/dev/null 2>&1 || true
                log "STAY_AWAKE_BATT: superseded by sleep_mode=${_mode:-default} — OFF (battery disablesleep=0)"
                ;;
        esac
        return 0
    fi
    # 2. Pack protection at <=20% (battery only — the pack only
    # drains there).
    if [ "$EXT" != "Yes" ] && [ -n "$PCT" ] && [ "$PCT" -le 20 ] 2>/dev/null; then
        sudo -n /usr/bin/pmset -b disablesleep 0 >/dev/null 2>&1 || true
        rm -f "$_marker"
        log "STAY_AWAKE_BATT: auto-revert at ${PCT}% (<=20%) — OFF, normal sleep restored"
        notify_ratelimited stay_awake_batt 3600 1 "Battery Commander (BC)" "Stay Awake (On Battery) auto-OFF at ${PCT}% — normal sleep restored to protect the battery"
        return 0
    fi
    # 3. Re-assert if the setting was cleared externally (the
    # effective value is the stored value — see the header note).
    local _eff
    _eff=$(pmset -g 2>/dev/null | awk '/SleepDisabled/{print $2}')
    if [ "$_eff" != "1" ]; then
        if sudo -n /usr/bin/pmset -b disablesleep 1 >/dev/null 2>&1; then
            log "STAY_AWAKE_BATT: battery disablesleep had been cleared externally — re-asserted ON"
        else
            log "STAY_AWAKE_BATT: re-assert FAILED (pmset error)"
        fi
    fi
}

# LAYER 1: Session Guard — clean stale sessions (>7200 s). A non-empty
# token means the session is owned — do not clean (guardian's rule).
section_l1_stale_session() {
    local _age _token
    [ -f "$SESSION_FILE" ] || return 0
    _age=$(( $(date +%s) - $(stat -f %m "$SESSION_FILE" 2>/dev/null || echo 0) ))
    [ "$_age" -gt 7200 ] || return 0
    _token=$(guard_token 2>/dev/null || echo "")
    [ -z "$_token" ] || return 0
    log "LAYER1: stale session (${_age}s) — cleaning"
    rm -f "$SESSION_FILE" "$DASH/.active_token"
    # No discharge process exists in BC v1, so there is nothing to end.
    # A stale sd_watcher (pre-BC residue) is ended if one is running.
    pkill -9 -f "sd_watcher" 2>/dev/null || true
    atomic_write "$DASH/.active_mode" "idle
"
    MODE="idle"
}

# LAYER 2: Overshoot Guard — PCT > UPPER + 2% (design §5 layer a).
# The corrective discharge is gated by the APG guard (b) and the
# post-wake delay (d). In v1 there is no forced-discharge mechanism, so
# the action is hold-and-wait: the enforcer holds BCLM=10 and the battery
# drains naturally. This section detects + logs the episode; the drift
# section owns the BCLM correction.
# _l2_overshoot_confirmed_notify — C2 (consolidation 2026-11-13): an
# overshoot is CONFIRMED when the battery is demonstrably still charging
# above the limit: IsCharging=Yes, OR Amperage > 0, OR CurrentCapacity
# rose vs the previous tick while the previous tick was already above
# UPPER+2. A gauge re-estimate alone (e.g. 86% -> 93% while holding,
# IsCharging=No, no capacity rise) is NOT confirmed and stays log-only.
# On the first confirmed tick of an episode: create the episode marker
# ($DASH/.notify/overshoot_episode) and fire ONE notification through
# notify_ratelimited (critical: bypasses quiet hours). The marker is
# removed when PCT <= UPPER (episode over).
_l2_overshoot_confirmed_notify() {
    local _confirmed=0
    [ "$ISCHG" = "Yes" ] && _confirmed=1
    if [ -n "${AMP:-}" ] && [ "$AMP" -gt 0 ] 2>/dev/null; then _confirmed=1; fi
    if [ -n "${PREV_CUR_VAL:-}" ] && [ -n "${PREV_TICK_PCT:-}" ] && [ "$CUR" -gt "$PREV_CUR_VAL" ] 2>/dev/null && [ "$PREV_TICK_PCT" -gt "$_overshoot" ] 2>/dev/null; then _confirmed=1; fi
    [ "$_confirmed" -eq 1 ] || return 0
    if [ ! -f "$OVERSHOOT_NOTIFY_MARKER" ]; then
        mkdir -p "$DASH/.notify" 2>/dev/null || true
        echo "$(date +%s)|$PCT" > "$OVERSHOOT_NOTIFY_MARKER" 2>/dev/null || true
        log "LAYER2: overshoot CONFIRMED (PCT=$PCT > UPPER+2=$_overshoot, IsChg=$ISCHG Amp=${AMP:-?}) - notifying (once per episode)"
        notify_ratelimited "overshoot_episode" 0 1 "Battery Commander" "Battery ${PCT}% — above the ${LAST_UPPER}% limit (confirmed charging overshoot)"
    fi
}

section_l2_overshoot() {
    local _overshoot _wake_age
    _overshoot=$((LAST_UPPER + 2))
    # L18: skip if charge_full / discharge / calibration is active.
    # (Still clear a stale overshoot episode if the battery is back
    # below the threshold — the state file must not outlive the episode.)
    case "$MODE" in
        charge_full|discharge|calibration)
            [ "$PCT" -le "$_overshoot" ] && _clear_overshoot_state
            return 0
            ;;
    esac
    # Only when on AC (a corrective discharge only makes sense with the
    # charger attached).
    if [ "$EXT" != "Yes" ]; then
        _clear_overshoot_state
        return 0
    fi
    if [ "$PCT" -gt "$_overshoot" ]; then
        _l2_overshoot_confirmed_notify
        # APG guard (layer b): a thermal pause suppresses the corrective
        # discharge. It never suppresses the hold reapply (the drift
        # section still corrects BCLM).
        if [ -f "$APG_PAUSED" ]; then
            log "LAYER2: overshoot (PCT=$PCT > UPPER+2=$_overshoot) — corrective discharge suppressed (APG thermal pause)"
            _set_overshoot_state
            return 0
        fi
        # Post-wake delay (layer d): 120 s, discharge-only. wake_age()
        # scans pmset -g log only here (gated, never on the hot path).
        _wake_age=$(wake_age)
        if [ "$_wake_age" -lt "$POST_WAKE_DELAY_S" ] && [ "$PCT" -lt 95 ]; then
            log "LAYER2: overshoot (PCT=$PCT) — corrective discharge suppressed (post-wake delay ${_wake_age}s < ${POST_WAKE_DELAY_S}s)"
            _set_overshoot_state
            return 0
        fi
        if [ ! -f "$OVERSHOOT_STATE" ]; then
            if [ "$ISCHG" = "Yes" ]; then
                log "LAYER2: overshoot detected (PCT=$PCT > UPPER+2=$_overshoot) — charging above the limit; the ladder owns the correction"
            else
                log "LAYER2: overshoot detected (PCT=$PCT > UPPER+2=$_overshoot) — starting a corrective discharge session (v1.6-ac on-AC actuator)"
                _guardian_start_corrective watchdog-layer2 || true
            fi
        fi
        _set_overshoot_state
    else
        _clear_overshoot_state
        # C2: the notification episode ends when PCT is back at/below UPPER.
        [ "$PCT" -le "$LAST_UPPER" ] && rm -f "$OVERSHOOT_NOTIFY_MARKER" 2>/dev/null || true
    fi
}

# LAYER 2b: Stop discharge at UPPER. No discharge process exists in BC v1,
# so this reconciles a stale discharge MODE: if the mode says discharge
# but the battery is back at/below UPPER, the (natural) discharge is
# complete — clear the session and return to hold or idle.
section_l2b_discharge_complete() {
    [ "$MODE" = "discharge" ] || return 0
    [ -n "$PCT" ] && [ "$PCT" -le "$LAST_UPPER" ] || return 0
    log "L2b: discharge complete (PCT=$PCT <= UPPER=$LAST_UPPER) — reconciling mode"
    _reconcile_mode_after_discharge "L2b"
}

# LAYER 3: Config is source of truth + LAYER 3a silent-hold detection +
# LAYER 10 SMC<->config drift — MERGED into the single drift corrector.
# (The design maps both L9 and L10 to this BCLM drift check; there is one
# drift section, one state file, one alert path.)
# Expected BCLM from config + %: PCT>=UPPER -> 10 (hold); PCT<=LOWER ->
# 100 (resume); in-band -> no expectation (either state is legitimate).
# Actions: (1) if the config is wrong, fix it (bc_reapply_limit) — that is
# the BC "reapply"; the enforcer does the actual BCLM write within 60 s.
# (2) if BCLM disagrees for >300 s, log + notify (the enforcer is stuck
# or not loaded; the daemon check + ladder escalate from here).
# A session mode (discharge/charge_full/calibration) skips the reapply and
# the alert — the session owns the state. The APG pause never suppresses
# the hold reapply (holding is safe during a thermal pause).
section_l3_drift() {
    local _expected _first _age
    if [ "$PCT" -ge "$LAST_UPPER" ]; then
        _expected="10"
    elif [ "$PCT" -le "$LAST_LOWER" ]; then
        _expected="100"
    else
        _expected=""
    fi

    # LAYER 3a: silent-hold detection. BCLM=10 + AC + not charging +
    # PCT>=UPPER + mode idle + no session -> the enforcer is holding but
    # the mode file still says idle. Correct it (atomic write).
    # BCLM=10 is the authoritative hold signal; NCR=14 is NOT used.
    if [ "${BCLM:-}" = "10" ] && [ "$EXT" = "Yes" ] && [ "$ISCHG" = "No" ] \
        && [ "$MODE" = "idle" ] && [ ! -f "$SESSION_FILE" ] \
        && [ "$PCT" -ge "$LAST_UPPER" ]; then
        log "LAYER3a: silent hold detected (BCLM=10, pct=$PCT >= UPPER=$LAST_UPPER, mode=idle) — correcting"
        atomic_write "$DASH/.active_mode" "hold
"
        MODE="hold"
        date +%s > "$DASH/.hold_since" 2>/dev/null || true
    fi

    # .hold_since maintenance (guardian L3): hold -> ensure the file
    # exists; otherwise remove it.
    if [ "$MODE" = "hold" ]; then
        [ -f "$DASH/.hold_since" ] || date +%s > "$DASH/.hold_since" 2>/dev/null || true
    else
        rm -f "$DASH/.hold_since" 2>/dev/null || true
    fi

    # Drift: BCLM disagrees with the expected state (in-band: no drift).
    # BCLM unreadable: the comparison is meaningless — skip (the main
    # block already logged it, rate-limited).
    if [ "${BCLM_UNREADABLE:-0}" = "1" ]; then
        return 0
    fi
    if [ -z "$_expected" ] || [ "${BCLM:-}" = "$_expected" ]; then
        if [ -f "$DRIFT_STATE" ]; then
            log "LAYER3: drift cleared (BCLM=${BCLM:-?} pct=$PCT cfg=$LAST_UPPER/$LAST_LOWER)"
            rm -f "$DRIFT_STATE"
        fi
        return 0
    fi

    # Track first sighting; stay silent while the enforcer has its 60 s
    # window (plus margin) to apply the config.
    if [ ! -f "$DRIFT_STATE" ]; then
        atomic_write "$DRIFT_STATE" "$(date +%s)|${BCLM:-?}|$PCT
"
        log "LAYER3: drift detected (BCLM=${BCLM:-?} expected=$_expected pct=$PCT cfg=$LAST_UPPER/$LAST_LOWER) — waiting up to ${DRIFT_ALERT_AFTER_S}s for the enforcer"
        return 0
    fi
    _first=$(cut -d'|' -f1 "$DRIFT_STATE" 2>/dev/null || echo 0)
    case "$_first" in ''|*[!0-9]*) _first=0 ;; esac
    _age=$(( $(date +%s) - _first ))
    [ "$_age" -gt "$DRIFT_ALERT_AFTER_S" ] || return 0

    # Drift persisted >300 s. A session owns the state — skip.
    case "$MODE" in
        discharge|charge_full|calibration)
            log "LAYER3: drift BCLM=${BCLM:-?} expected=$_expected but active=$MODE — skip (session owns state)"
            return 0
            ;;
    esac
    # A live discharge session owns the state (v1.6-ac): the
    # reapply rewrites the config's byte form, and the monitor's
    # config-signature check would read that as a supersede and
    # kill the session mid-drain (sessions routinely run below
    # LOWER, where this layer expects BCLM=100).
    if [ -f "$DISCHARGE_SESSION_REAL" ]; then
        log "LAYER3: drift persists ${_age}s (BCLM=${BCLM:-?} expected=$_expected pct=$PCT) — skip (discharge session owns state)"
        return 0
    fi
    log "LAYER3: drift persists ${_age}s (BCLM=${BCLM:-?} expected=$_expected pct=$PCT) — reapplying config"
    bc_reapply_limit "$LAST_UPPER" "$LAST_LOWER" || log "LAYER3: reapply failed — enforcer has not picked it up; see the daemon check"
    notify_ratelimited "drift" 3600 0 "Battery Commander" "Charge limit drift: BCLM=${BCLM:-?} but config says $LAST_UPPER/$LAST_LOWER (${_age}s). Check the enforcer."
}

# LAYER 4: Process Guard — orphan discharge mode. No session file, but the
# mode says discharge: the mode is orphaned. No BC discharge process
# exists in v1, so there is nothing to end — reconcile the mode. The
# 120 s staleness gate (on the .active_mode mtime) avoids racing a
# just-set mode from a fresh user intent.
section_l4_orphan() {
    local _mode_age
    [ -f "$SESSION_FILE" ] && return 0
    [ "$MODE" = "discharge" ] || return 0
    _mode_age=$(( $(date +%s) - $(stat -f %m "$DASH/.active_mode" 2>/dev/null || echo 0) ))
    [ "$_mode_age" -gt 120 ] || return 0
    log "LAYER4: orphan discharge mode (no session, ${_mode_age}s old) — reconciling"
    _reconcile_mode_after_discharge "LAYER4"
}

# LAYER 4b: Phantom session cleanup / AC-disconnect recovery. (Ported
# verbatim in structure; the `pgrep battopt discharge` check is gone —
# no discharge process exists in BC v1, so "no discharge running" is
# always true and the session is judged by its age alone.)
#   * AC present, no discharge, mode=discharge -> genuine fault -> idle.
#   * AC absent,  no discharge, mode=discharge -> interrupted -> hold
#     (+ .hold_since + .layer4b_hold). On AC reconnect LAYER2
#     re-discharges if PCT > UPPER; if PCT <= UPPER the limit resumes.
#   * Any other mode with a stale .sd_session -> clear the session file.
section_l4b_phantom() {
    local _age _am _ac
    [ -f "$SESSION_FILE" ] || return 0
    _age=$(( $(date +%s) - $(stat -f %m "$SESSION_FILE" 2>/dev/null || echo 0) ))
    [ "$_age" -gt 60 ] || return 0
    _am=$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')
    _ac="no"
    [ "$EXT" = "Yes" ] && _ac="yes"
    if [ "$_am" = "discharge" ] && [ "$_ac" = "no" ]; then
        log "LAYER4b: discharge interrupted by AC disconnect (${_age}s) — transitioning to hold"
        rm -f "$SESSION_FILE" "$DASH/.active_token"
        atomic_write "$DASH/.active_mode" "hold
"
        MODE="hold"
        date +%s > "$DASH/.hold_since" 2>/dev/null || true
        date +%s > "$DASH/.layer4b_hold" 2>/dev/null || true
    else
        log "LAYER4b: phantom session (${_age}s, mode=${_am:-idle}, AC=${_ac}, no discharge) — clearing"
        rm -f "$SESSION_FILE"
        if [ "$_am" = "discharge" ]; then
            rm -f "$DASH/.active_token"
            atomic_write "$DASH/.active_mode" "idle
"
            MODE="idle"
        fi
    fi
}

# === LAYER 8: BC LaunchDaemon check ===
# Ported from guardian's INLINED daemon_watchdog() (not the dead
# daemon_watchdog.sh file — W0 correction C2). Verifies the BC enforcer
# LaunchDaemon (com.batterycommander.bclimit) is loaded. If it is not
# loaded: log + notify (rate-limited). NEVER auto-load it — loading is
# the Phase C gate. If it just became loaded, reapply the config once
# (guarded) so the enforcer picks it up.
# Loaded-state check: _daemon_loaded() (`launchctl print system/` —
# `launchctl list` cannot see a system daemon from a user shell).
section_l8_daemon_check() {
    local _state _last _now
    _now=$(date +%s 2>/dev/null || echo 0)
    if _daemon_loaded; then
        # Loaded.
        if [ -f "$DAEMON_CHECK_STATE" ]; then
            _state=$(cut -d'|' -f1 "$DAEMON_CHECK_STATE" 2>/dev/null || echo "")
            if [ "$_state" = "NOT_LOADED" ]; then
                log "L8: enforcer LaunchDaemon com.batterycommander.bclimit is loaded now — reapplying config"
                rm -f "$DAEMON_CHECK_STATE"
                if ! _transient_session_active; then
                    if [ "$_REAPPLIED_THIS_TICK" != "1" ]; then
                        bc_reapply_limit "$LAST_UPPER" "$LAST_LOWER" || log "L8: reapply failed after daemon load"
                    fi
                fi
            fi
        fi
        return 0
    fi
    # Not loaded (expected until Phase C — not an error, but worth one
    # notification per episode + an hourly log line).
    if [ -f "$DAEMON_CHECK_STATE" ]; then
        _last=$(cut -d'|' -f2 "$DAEMON_CHECK_STATE" 2>/dev/null || echo 0)
        case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
        if [ $(( _now - _last )) -ge 3600 ]; then
            log "L8: enforcer LaunchDaemon com.batterycommander.bclimit not loaded (expected until Phase C) — no auto-load"
            atomic_write "$DAEMON_CHECK_STATE" "NOT_LOADED|$_now
"
        fi
    else
        log "L8: enforcer LaunchDaemon com.batterycommander.bclimit not loaded (expected until Phase C) — no auto-load"
        atomic_write "$DAEMON_CHECK_STATE" "NOT_LOADED|$_now
"
        notify_ratelimited "daemon" 3600 0 "Battery Commander" "Charge-limit enforcer is not loaded yet (Phase C). Monitoring only."
    fi
    return 0
}

# === Enforce ladder (ported from enforce_watchdog.sh) ===
# Violation = EXT=Yes AND IsChg=Yes AND PCT > UPPER.
# Healthy tick: reset the escalation counter + both cooldowns + the
# notifier cap (same as the original).
# The counter state is saved (atomically) IMMEDIATELY after incrementing —
# the audit's fix: the count must advance even if a rung's action fails
# (the original exited 1 before saving state on a failed reapply).

# _guardian_start_corrective <starter-tag> — the guardian's real
# corrective discharge (v1.6-ac): create a MODE=corrective session
# (the ordinary session contract) targeting the configured UPPER,
# with .active_mode=discharge so the ladder and the drift layer
# defer to it exactly as they do for user sessions (a config
# reapply mid-session would flip the config byte form and the
# monitor would read it as a supersede). The discharge monitor
# supervises the session like any other, and bc-limit engages
# the on-AC discharge-mode actuator for it; corrective overshoot
# entries keep the second-signal gate in both the monitor and
# bc-limit, so a bare gauge drift still cannot start a drain.
# Returns: 0 = session created, 2 = a session already exists,
# 1 = blocked (shadow mode, AC-flip cooldown, or no valid
# target at UPPER=100).
_guardian_start_corrective() {
    local _tag="$1" _now _until
    _now=$(date +%s)
    [ -f "$DISCHARGE_SESSION_REAL" ] && return 2
    [ -f "$DISCHARGE_SHADOW_FLAG" ] && return 1
    [ "$LAST_UPPER" -le 99 ] || return 1
    if [ -f "$DISCHARGE_COOLDOWN_FILE" ]; then
        _until=$(grep '^UNTIL=' "$DISCHARGE_COOLDOWN_FILE" 2>/dev/null | cut -d= -f2)
        case "$_until" in ''|*[!0-9]*) _until=0 ;; esac
        [ "$_until" -gt "$_now" ] && return 1
    fi
    atomic_write "$DISCHARGE_SESSION_REAL" "MODE=corrective
TARGET=$LAST_UPPER
STARTED=$_now
STARTER=$_tag
" || return 1
    atomic_write "$DASH/.active_mode" "discharge
" || true
    MODE="discharge"
    log "GUARDIAN: corrective discharge session started (target=${LAST_UPPER}% pct=$PCT starter=$_tag) — bc-limit engages the on-AC actuator"
    return 0
}

# _ladder_discharge_gate <COUNT> <NOW> — COUNT >= 8 rung. Gates, in order:
# (a) 300 s cooldown, (b) the APG guard (ADDED — the original lacked it),
# (c) the post-wake delay (ADDED — the original lacked it),
# (d) the UPPER+2 threshold (ADDED — the original fired at any PCT > UPPER).
# A gated rung logs its suppression (at most once per cooldown window) and
# sets the cooldown. All gates pass = start a corrective session
# (v1.6-ac; _guardian_start_corrective above).
_ladder_discharge_gate() {
    local _count="$1" _now="$2" _last_disch=0 _overshoot _wake_age
    [ -f "$ENFORCE_LAST_DISCH" ] && _last_disch=$(cat "$ENFORCE_LAST_DISCH" 2>/dev/null || echo 0)
    case "$_last_disch" in ''|*[!0-9]*) _last_disch=0 ;; esac
    [ $(( _now - _last_disch )) -ge "$DISCHARGE_COOLDOWN_S" ] || return 0
    _overshoot=$((LAST_UPPER + 2))
    # (d) UPPER+2 threshold.
    if [ "$PCT" -le "$_overshoot" ]; then
        log "ladder: COUNT=$_count — corrective discharge below +2 threshold (PCT=$PCT <= UPPER+2=$_overshoot) — holding"
        echo "$_now" > "$ENFORCE_LAST_DISCH"
        return 0
    fi
    # (b) APG guard.
    if [ -f "$APG_PAUSED" ]; then
        log "ladder: COUNT=$_count — corrective discharge suppressed (APG thermal pause)"
        echo "$_now" > "$ENFORCE_LAST_DISCH"
        return 0
    fi
    # (c) Post-wake delay.
    _wake_age=$(wake_age)
    if [ "$_wake_age" -lt "$POST_WAKE_DELAY_S" ] && [ "$PCT" -lt 95 ]; then
        log "ladder: COUNT=$_count — corrective discharge suppressed (post-wake delay ${_wake_age}s < ${POST_WAKE_DELAY_S}s)"
        echo "$_now" > "$ENFORCE_LAST_DISCH"
        return 0
    fi
    # All gates pass. v1: hold-and-wait.
    log "ladder: COUNT=$_count — corrective discharge to ${LAST_UPPER}% (PCT=$PCT > UPPER+2=$_overshoot)"
    if [ "$_REAPPLIED_THIS_TICK" != "1" ]; then
        bc_reapply_limit "$LAST_UPPER" "$LAST_LOWER" || log "ladder: reapply failed (COUNT=$_count discharge gate)"
    fi
    _guardian_start_corrective watchdog-ladder
    if [ $? -eq 1 ]; then
        log "ladder: corrective session not started (AC-flip cooldown, shadow mode, or UPPER=100)"
    fi
    echo "$_now" > "$ENFORCE_LAST_DISCH"
}

# _ladder_critical <COUNT> <NOW> — COUNT >= 16 rung. CRITICAL notify
# (app-native queue with the Basso sound field, cap 3 per episode,
# 300 s cooldown; the cap file is cleared by the healthy path).
# Reworded to Battery Commander. Critical notifications bypass
# quiet hours.
_ladder_critical() {
    local _count="$1" _now="$2" _last_crit=0 _notify_count=0
    [ -f "$ENFORCE_LAST_CRIT" ] && _last_crit=$(cat "$ENFORCE_LAST_CRIT" 2>/dev/null || echo 0)
    case "$_last_crit" in ''|*[!0-9]*) _last_crit=0 ;; esac
    [ $(( _now - _last_crit )) -ge "$CRIT_COOLDOWN_S" ] || return 0
    log "CRITICAL: enforcement failed — possible enforcer fault (COUNT=$_count)"
    [ -f "$ENFORCE_CRIT_COUNT" ] && _notify_count=$(cat "$ENFORCE_CRIT_COUNT" 2>/dev/null || echo 0)
    case "$_notify_count" in ''|*[!0-9]*) _notify_count=0 ;; esac
    if [ "$_notify_count" -lt 3 ]; then
        _notify_queue "Battery Commander — CRITICAL" \
            "Charge limit not enforced. Battery at ${PCT}% > ${LAST_UPPER}%. Check the enforcer." \
            "Basso"
        _notify_count=$(( _notify_count + 1 ))
        echo "$_notify_count" > "$ENFORCE_CRIT_COUNT"
    else
        log "CRITICAL: notification suppressed by cap (${_notify_count}/3)"
    fi
    echo "$_now" > "$ENFORCE_LAST_CRIT"
}

section_ladder() {
    local _count=0 _last_ts _now _elapsed
    # A TRANSIENT session owns the state — skip the ladder
    # (enforce_watchdog's early exit, scoped to the ladder only; the other
    # sections still run). Hold does NOT skip: see _transient_session_active.
    if _transient_session_active; then
        return 0
    fi
    _now=$(date +%s 2>/dev/null || echo 0)
    if [ "$EXT" != "Yes" ] || [ "$ISCHG" != "Yes" ] || [ "$PCT" -le "$LAST_UPPER" ]; then
        # Healthy — reset escalation counter, both cooldowns, notifier cap.
        rm -f "$ENFORCE_STATE" "$ENFORCE_LAST_DISCH" "$ENFORCE_LAST_CRIT" "$ENFORCE_CRIT_COUNT"
        return 0
    fi
    # Violation: read the counter, increment, save atomically FIRST.
    _last_ts="$_now"
    if [ -f "$ENFORCE_STATE" ]; then
        _count=$(cut -d'|' -f1 "$ENFORCE_STATE" 2>/dev/null || echo 0)
        _last_ts=$(cut -d'|' -f2 "$ENFORCE_STATE" 2>/dev/null || echo 0)
    fi
    case "$_count" in ''|*[!0-9]*) _count=0 ;; esac
    case "$_last_ts" in ''|*[!0-9]*) _last_ts="$_now" ;; esac
    _elapsed=$(( _now - _last_ts ))
    # A long gap (sleep / missed ticks) breaks the "consecutive ticks"
    # chain: a stale count from before the gap must not add to a fresh
    # violation (audit 2026-11-11, M7).
    if [ "$_elapsed" -gt 300 ]; then
        log "ladder: gap ${_elapsed}s since last violating tick — resetting count (was $_count)"
        _count=0
    fi
    # Gauge-jump deferral: if the % jumped >= 5 in one tick, the reading
    # is suspect (the gauge jumps when the battery rests or charging
    # resumes) — defer the increment one tick; the next tick counts
    # normally if the violation is real (audit 2026-11-11, W1).
    if [ "$JUMP_SUSPECT" = "1" ]; then
        log "ladder: deferring COUNT increment one tick (gauge jump suspected: ${PREV_PCT_VAL:-?}% -> ${PCT}%)"
        return 0
    fi
    _count=$(( _count + 1 ))
    atomic_write "$ENFORCE_STATE" "${_count}|${_now}
"
    log "VIOLATION #$_count: PCT=${PCT}% IsChg=Yes UPPER=${LAST_UPPER}% (elapsed ${_elapsed}s)"
    # COUNT 1: reapply the limit (may unstick the enforcer).
    if [ "$_count" -eq 1 ]; then
        log "ladder: reapplying limit ${LAST_UPPER}/${LAST_LOWER}"
        if [ "$_REAPPLIED_THIS_TICK" != "1" ]; then
            bc_reapply_limit "$LAST_UPPER" "$LAST_LOWER" || log "ladder: reapply failed (COUNT=1) — count already saved, escalating"
        else
            log "ladder: reapply already done this tick (drift section)"
        fi
    fi
    # COUNT 4: verify the BC LaunchDaemon is loaded; reapply.
    if [ "$_count" -eq 4 ]; then
        log "ladder: 4 violations (240s) — verifying enforcer daemon"
        if _daemon_loaded; then
            log "ladder: enforcer daemon loaded"
        else
            log "ladder: enforcer daemon NOT loaded — no auto-load (Phase C gate)"
            notify_ratelimited "daemon" 3600 0 "Battery Commander" "Charge-limit enforcer is not loaded (Phase C). Battery at ${PCT}% > ${LAST_UPPER}%."
        fi
        if [ "$_REAPPLIED_THIS_TICK" != "1" ]; then
            bc_reapply_limit "$LAST_UPPER" "$LAST_LOWER" || log "ladder: reapply failed (COUNT=4)"
        fi
    fi
    # COUNT 8: corrective discharge gate.
    if [ "$_count" -ge 8 ]; then
        _ladder_discharge_gate "$_count" "$_now"
    fi
    # COUNT 16: CRITICAL notify.
    if [ "$_count" -ge 16 ]; then
        _ladder_critical "$_count" "$_now"
    fi
}

# === .charge_target cleanup (W1 flag) ===
# The charge_full flag stays until 100% or the next intent clears it.
# The watchdog clears it when the charge is done (PCT>=100) or when the
# mode is no longer charge_full (stale flag). At 100% the mode moves
# charge_full -> hold (the enforcer holds at 100%).
section_charge_target() {
    [ -f "$DASH/.charge_target" ] || return 0
    if [ "$PCT" -ge 100 ]; then
        rm -f "$DASH/.charge_target"
        if [ "$MODE" = "charge_full" ]; then
            atomic_write "$DASH/.active_mode" "hold
"
            MODE="hold"
            date +%s > "$DASH/.hold_since" 2>/dev/null || true
            log "charge_target: reached 100% — flag cleared, mode charge_full -> hold"
        else
            log "charge_target: reached 100% — flag cleared (mode=$MODE)"
        fi
        return 0
    fi
    if [ "$MODE" != "charge_full" ]; then
        rm -f "$DASH/.charge_target"
        log "charge_target: stale flag cleared (mode=$MODE, pct=$PCT)"
    fi
}

# === Consolidated checks (folded from consolidated_checks.sh) ===
# The 10-minute fan-out to sailing_tracker, adaptive, ensure_limit,
# system_guard. Time-gated (600 s) via .watchdog_consolidated_last.
# Each child runs from the LIVE state dir (same as consolidated did);
# stderr is captured and its first line logged (not discarded — the old
# fan-out was silent). A missing/non-executable child is logged, not
# silently skipped. One summary line per run.
# NOTE: the children are BC-clean (verified 2026-11-11 — ensure_limit was
# fixed in W4; adaptive, system_guard, sailing_tracker contain no battopt
# calls). The watchdog invokes them as-is, exactly as
# consolidated_checks.sh did.
section_consolidated() {
    local _now _last=0 _child _ran="" _skipped="" _err
    _now=$(date +%s 2>/dev/null || echo 0)
    [ -f "$CONSOLIDATED_LAST" ] && _last=$(cat "$CONSOLIDATED_LAST" 2>/dev/null || echo 0)
    case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
    [ $(( _now - _last )) -ge "$CONSOLIDATED_EVERY_S" ] || return 0
    echo "$_now" > "$CONSOLIDATED_LAST"
    for _child in sailing_tracker.sh adaptive.sh ensure_limit.sh system_guard.sh; do
        if [ -x "$DASH/$_child" ]; then
            _err=$("$DASH/$_child" 2>&1 >/dev/null) || true
            _ran="$_ran $_child"
            if [ -n "$_err" ]; then
                log "consolidated: $_child stderr — $(printf '%s' "$_err" | head -1)"
            fi
        else
            _skipped="$_skipped $_child"
        fi
    done
    log "consolidated: ran:${_ran:- none} skipped:${_skipped:- none}"
}

# === Discharge session monitor (discharge build D2, design §§4-8) ===
# Supervises ONE discharge session file per tick. NEVER writes BCLM or
# any SMC key; the only files it writes are .discharge_state,
# .discharge_cooldown and discharge.log, plus deleting the supervised
# session file when a session ends / is refused / is aborted.
# Shadow mode: while $DASH/.discharge_shadow exists, the supervised file
# is .discharge_session.shadow, every log line is tagged [SHADOW], and
# no notification is ever sent (log only). With the flag absent the same
# code supervises the real .discharge_session.
# This layer must never fail the tick: section_discharge_monitor wraps
# the implementation and swallows all errors.
DISCHARGE_STATE="$DASH/.discharge_state"
DISCHARGE_COOLDOWN_FILE="$DASH/.discharge_cooldown"
DISCHARGE_LOG="$DASH/discharge.log"
DISCHARGE_SHADOW_FLAG="$DASH/.discharge_shadow"
DISCHARGE_SESSION_REAL="$DASH/.discharge_session"
DISCHARGE_SESSION_SHADOW="$DASH/.discharge_session.shadow"
DISCHARGE_INTENT_FILE="$DASH/.discharge_intent"
DISCHARGE_INTENT_BLOCK_FILE="$DASH/.discharge_intent_block"
# APG critical battery-temp threshold (apg_classify: red above 42 C).
DISCHARGE_TEMP_CRIT=42

_disch_now() {
    local _n
    _n=$(date +%s 2>/dev/null || echo 0)
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    printf '%s' "$_n"
}

_disch_readings() {
    printf 'pct=%s bclm=%s ext=%s chg=%s amp=%s cap=%s ncr=%s apg=%s temp=%s' \
        "${PCT:-?}" "${BCLM:-?}" "${EXT:-?}" "${ISCHG:-?}" "${AMP:-?}" \
        "${CUR:-?}" "${NCR:-?}" "${APG:-?}" "${_disch_temp:-?}"
}

dlog() {
    local _tag="REAL"
    [ "${D_SHADOW:-0}" = "1" ] && _tag="SHADOW"
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$_tag" "$1" >> "$DISCHARGE_LOG" 2>/dev/null || true
}

_disch_notify() {
    # $1 = notify_ratelimited key, $2 = message. Shadow: log only.
    [ "${D_SHADOW:-0}" = "1" ] && return 0
    notify_ratelimited "$1" 0 0 "Battery Commander" "$2" || true
}

_disch_config_sig() {
    if [ -f "$CFG" ]; then
        if command -v md5 >/dev/null 2>&1; then
            md5 -q "$CFG" 2>/dev/null || printf 'none'
        elif command -v md5sum >/dev/null 2>&1; then
            md5sum "$CFG" 2>/dev/null | awk '{print $1}'
        else
            printf 'size-%s' "$(wc -c < "$CFG" 2>/dev/null | tr -d ' ')"
        fi
    else
        printf 'none'
    fi
}

_disch_load_state() {
    DS_PHASE="idle"; DS_SESSION_STARTED=0; DS_CONFIRM_COUNT=0
    DS_CONFIRM_SIGNAL=0; DS_OVERSHOOT_CLAIM=0; DS_ARMED_TICKS=0
    DS_COMP_COUNT=0; DS_START_PCT=""; DS_PARKED_TOTAL_S=0; DS_PARK_SINCE=0
    DS_APG_SINCE=0; DS_LAST_PCT=""; DS_LAST_CAP=""; DS_LAST_EXT=""
    DS_FLIP_TIMES=""; DS_UNREADABLE=0; DS_TEMP_MIN=""; DS_TEMP_MAX=""
    DS_AC_WAS=0; DS_AC_EVER=0
    DS_LAST_TICK=0; DS_CONFIG_SIG=""; DS_SHADOW_CLAIM_COUNT=0
    DS_SHADOW_SIGNAL=0; DS_EXTENDED=0; DS_GAUGE_PCT=""; DS_APG_BLOCK=0
    DS_SEEN_BATT=0; DS_BATT_SINCE=0
    D_STATE_EXISTED=0
    [ -f "$DISCHARGE_STATE" ] || return 0
    D_STATE_EXISTED=1
    local _k _v
    while IFS='=' read -r _k _v; do
        case "$_k" in
            PHASE) DS_PHASE="$_v" ;;
            SESSION_STARTED) DS_SESSION_STARTED="$_v" ;;
            CONFIRM_COUNT) DS_CONFIRM_COUNT="$_v" ;;
            CONFIRM_SIGNAL) DS_CONFIRM_SIGNAL="$_v" ;;
            OVERSHOOT_CLAIM) DS_OVERSHOOT_CLAIM="$_v" ;;
            ARMED_TICKS) DS_ARMED_TICKS="$_v" ;;
            COMP_COUNT) DS_COMP_COUNT="$_v" ;;
            START_PCT) DS_START_PCT="$_v" ;;
            PARKED_TOTAL_S) DS_PARKED_TOTAL_S="$_v" ;;
            PARK_SINCE) DS_PARK_SINCE="$_v" ;;
            APG_SINCE) DS_APG_SINCE="$_v" ;;
            LAST_PCT) DS_LAST_PCT="$_v" ;;
            LAST_CAP) DS_LAST_CAP="$_v" ;;
            LAST_EXT) DS_LAST_EXT="$_v" ;;
            FLIP_TIMES) DS_FLIP_TIMES="$_v" ;;
            UNREADABLE) DS_UNREADABLE="$_v" ;;
            TEMP_MIN) DS_TEMP_MIN="$_v" ;;
            TEMP_MAX) DS_TEMP_MAX="$_v" ;;
            LAST_TICK) DS_LAST_TICK="$_v" ;;
            CONFIG_SIG) DS_CONFIG_SIG="$_v" ;;
            SHADOW_CLAIM_COUNT) DS_SHADOW_CLAIM_COUNT="$_v" ;;
            SHADOW_SIGNAL) DS_SHADOW_SIGNAL="$_v" ;;
            EXTENDED) DS_EXTENDED="$_v" ;;
            GAUGE_PCT) DS_GAUGE_PCT="$_v" ;;
            APG_BLOCK) DS_APG_BLOCK="$_v" ;;
            SEEN_BATT) DS_SEEN_BATT="$_v" ;;
            BATT_SINCE) DS_BATT_SINCE="$_v" ;;
            AC_WAS) DS_AC_WAS="$_v" ;;
            AC_EVER) DS_AC_EVER="$_v" ;;
        esac
    done < "$DISCHARGE_STATE"
    case "$DS_PHASE" in idle|armed|active) ;; *) DS_PHASE="idle" ;; esac
    local _n
    for _n in DS_SESSION_STARTED DS_CONFIRM_COUNT DS_CONFIRM_SIGNAL \
        DS_OVERSHOOT_CLAIM DS_ARMED_TICKS DS_COMP_COUNT DS_PARKED_TOTAL_S \
        DS_PARK_SINCE DS_APG_SINCE DS_UNREADABLE DS_LAST_TICK \
        DS_SHADOW_CLAIM_COUNT DS_SHADOW_SIGNAL DS_EXTENDED DS_APG_BLOCK \
        DS_SEEN_BATT DS_BATT_SINCE DS_AC_WAS DS_AC_EVER; do
        eval "_v=\${$_n}"
        case "$_v" in ''|*[!0-9]*) eval "$_n=0" ;; esac
    done
    case "$DS_GAUGE_PCT" in ''|*[!0-9]*) DS_GAUGE_PCT="" ;; esac
    case "$DS_START_PCT" in ''|*[!0-9]*) DS_START_PCT="" ;; esac
    case "$DS_LAST_PCT" in ''|*[!0-9]*) DS_LAST_PCT="" ;; esac
    case "$DS_LAST_CAP" in ''|*[!0-9]*) DS_LAST_CAP="" ;; esac
    return 0
}

_disch_save_state() {
    atomic_write "$DISCHARGE_STATE" "PHASE=$DS_PHASE
SESSION_STARTED=$DS_SESSION_STARTED
CONFIRM_COUNT=$DS_CONFIRM_COUNT
CONFIRM_SIGNAL=$DS_CONFIRM_SIGNAL
OVERSHOOT_CLAIM=$DS_OVERSHOOT_CLAIM
ARMED_TICKS=$DS_ARMED_TICKS
COMP_COUNT=$DS_COMP_COUNT
START_PCT=$DS_START_PCT
PARKED_TOTAL_S=$DS_PARKED_TOTAL_S
PARK_SINCE=$DS_PARK_SINCE
APG_SINCE=$DS_APG_SINCE
LAST_PCT=$DS_LAST_PCT
LAST_CAP=$DS_LAST_CAP
LAST_EXT=$DS_LAST_EXT
FLIP_TIMES=$DS_FLIP_TIMES
UNREADABLE=$DS_UNREADABLE
TEMP_MIN=$DS_TEMP_MIN
TEMP_MAX=$DS_TEMP_MAX
LAST_TICK=$DS_LAST_TICK
CONFIG_SIG=$DS_CONFIG_SIG
SHADOW_CLAIM_COUNT=$DS_SHADOW_CLAIM_COUNT
SHADOW_SIGNAL=$DS_SHADOW_SIGNAL
EXTENDED=$DS_EXTENDED
GAUGE_PCT=$DS_GAUGE_PCT
APG_BLOCK=$DS_APG_BLOCK
SEEN_BATT=$DS_SEEN_BATT
BATT_SINCE=$DS_BATT_SINCE
AC_WAS=$DS_AC_WAS
AC_EVER=$DS_AC_EVER
" || true
}

_disch_reset_state() {
    DS_PHASE="idle"; DS_SESSION_STARTED=0; DS_CONFIRM_COUNT=0
    DS_CONFIRM_SIGNAL=0; DS_OVERSHOOT_CLAIM=0; DS_ARMED_TICKS=0
    DS_COMP_COUNT=0; DS_START_PCT=""; DS_PARKED_TOTAL_S=0; DS_PARK_SINCE=0
    DS_APG_SINCE=0; DS_LAST_PCT=""; DS_LAST_CAP=""; DS_LAST_EXT=""
    DS_FLIP_TIMES=""; DS_UNREADABLE=0; DS_TEMP_MIN=""; DS_TEMP_MAX=""
    DS_AC_WAS=0; DS_AC_EVER=0
    DS_LAST_TICK="$1"; DS_CONFIG_SIG=""; DS_SHADOW_CLAIM_COUNT=0
    DS_SHADOW_SIGNAL=0; DS_EXTENDED=0; DS_GAUGE_PCT=""; DS_APG_BLOCK=0
    DS_SEEN_BATT=0; DS_BATT_SINCE=0
    _disch_save_state
}

_disch_parked_total() {
    local _now="$1" _total="$DS_PARKED_TOTAL_S"
    if [ "$DS_PARK_SINCE" -gt 0 ] && [ "$_now" -gt "$DS_PARK_SINCE" ]; then
        _total=$(( _total + _now - DS_PARK_SINCE ))
    fi
    printf '%s' "$_total"
}

_disch_episode() {
    # $1 = result, $2 = reason. Emits the verification-hook EPISODE line.
    local _now="$3" _end_pct _depth=0 _dur=0
    _end_pct="$PCT"
    case "$_end_pct" in ''|*[!0-9]*)
        _end_pct="${DS_LAST_PCT:-$DS_START_PCT}" ;;
    esac
    case "$_end_pct" in ''|*[!0-9]*) _end_pct=0 ;; esac
    if [ -n "$DS_START_PCT" ]; then
        _depth=$(( DS_START_PCT - _end_pct ))
    fi
    if [ "$DS_SESSION_STARTED" -gt 0 ] && [ "$_now" -gt "$DS_SESSION_STARTED" ]; then
        _dur=$(( _now - DS_SESSION_STARTED ))
    fi
    dlog "EPISODE id=$DS_SESSION_STARTED result=$1 reason=$2 start_pct=${DS_START_PCT:-0} end_pct=$_end_pct depth_pct=$_depth duration_s=$_dur parked_s=$(_disch_parked_total "$_now")"
    dlog "SESSION_END result=$1 reason=$2 $(_disch_readings)"
}

_disch_end() {
    # $1 result, $2 reason, $3 notify key ("" = none), $4 notify msg,
    # $5 delete supervised session file (1/0), $6 now
    _disch_episode "$1" "$2" "$6"
    [ "$5" = "1" ] && rm -f "$D_SESSION_FILE_CUR" 2>/dev/null
    if [ -n "$3" ]; then
        _disch_notify "$3" "$4"
    fi
    _disch_reset_state "$6"
}

_disch_second_signal() {
    [ "${ISCHG:-}" = "Yes" ] && return 0
    if [ -n "${AMP:-}" ]; then
        case "$AMP" in *[!0-9-]*|'') ;; *)
            [ "$AMP" -gt 0 ] 2>/dev/null && return 0 ;;
        esac
    fi
    if [ -n "$DS_LAST_CAP" ] && [ -n "${CUR:-}" ]; then
        case "$CUR" in ''|*[!0-9]*) ;; *)
            [ "$CUR" -gt "$DS_LAST_CAP" ] 2>/dev/null && return 0 ;;
        esac
    fi
    return 1
}

# _disch_drain_evidence — 0 when the battery is observably draining
# right now: on battery (EXT=No) with discharge current (read_snapshot
# collapses a wrapped negative amperage to -1) or falling capacity /
# percent vs the previous tick. This is the battery-side counterpart
# of _disch_second_signal (which detects CHARGING evidence): a
# session carrying an overshoot claim can only ever be confirmed by
# one of the two, and on battery only this one can exist. Before this
# helper, an overshoot-claim user session armed on AC could never
# activate on battery at all — the claim needed the pct to fall to
# UPPER+2 (~11 points of untracked drain) first. Live case
# 2026-11-15: claim=1, signal=0 for 73+ min at pct 98-99 while the
# user unplugged and replugged; nothing was recorded anywhere.
_disch_drain_evidence() {
    [ "${EXT:-}" = "No" ] || return 1
    [ "${AMP:-}" = "-1" ] && return 0
    if [ -n "$DS_LAST_CAP" ] && [ -n "${CUR:-}" ]; then
        case "$CUR" in ''|*[!0-9]*) ;; *)
            [ "$CUR" -lt "$DS_LAST_CAP" ] 2>/dev/null && return 0 ;;
        esac
    fi
    if [ -n "$DS_LAST_PCT" ] && [ -n "${PCT:-}" ]; then
        case "$PCT" in ''|*[!0-9]*) ;; *)
            [ "$PCT" -lt "$DS_LAST_PCT" ] 2>/dev/null && return 0 ;;
        esac
    fi
    return 1
}

# _disch_apg_thermal — 0 when the current APG pause (if any) must be
# treated as a genuine thermal gate for session purposes: battery
# temp at/above the APG yellow threshold (38 C), or temp unreadable
# (fail safe: an unknown temp blocks like a hot one). A pause with a
# present temp BELOW 38 C is load-only (apg_classify: yellow = temp
# >= 38 OR load >= 4; red = temp > 42 OR load > 6). Per the owner's
# rule (2026-11-15), CPU load alone never blocks a user-initiated
# session — temperature is the hard gate. Uses _disch_temp_int,
# computed by the monitor from the same snapshot as this tick.
_disch_apg_thermal() {
    [ -n "${_disch_temp_int:-}" ] || return 0
    [ "$_disch_temp_int" -ge 38 ] 2>/dev/null
}

# _disch_daemon_seen_batt — 0 when bc-limit's own state lines show
# external=0 at/after this session's start (120 s slack for clock
# skew between the two writers). The daemon is a second, phase-
# offset 60 s sampler; an unplug the watchdog's own tick missed can
# still be latched from its log (read-only). Bounded scan of the
# newest lines; the daemon log is rotation-bounded (~100 KB).
_disch_daemon_seen_batt() {
    local _log="$DASH/bc-limit-daemon.log" _line _ts _ep
    [ -f "$_log" ] || return 1
    _line=$(tail -400 "$_log" 2>/dev/null | grep 'external=0' | tail -1)
    [ -n "$_line" ] || return 1
    _ts=$(printf '%s' "$_line" | sed -n 's/^\[\([0-9-]* [0-9:]*\)\].*/\1/p')
    [ -n "$_ts" ] || return 1
    _ep=$(date -j -f "%Y-%m-%d %H:%M:%S" "$_ts" "+%s" 2>/dev/null)
    case "$_ep" in ''|*[!0-9-]*) return 1 ;; esac
    [ "$_ep" -ge $(( DS_SESSION_STARTED - 120 )) ] 2>/dev/null
}

_disch_temp_critical() {
    [ -n "${_disch_temp_int:-}" ] || return 1
    [ "$_disch_temp_int" -gt "$DISCHARGE_TEMP_CRIT" ] 2>/dev/null
}

_disch_wake_age() {
    local _lw
    if [ -f "$DASH/.last_wake" ]; then
        _lw=$(cat "$DASH/.last_wake" 2>/dev/null || echo "")
        case "$_lw" in ''|*[!0-9]*) ;; *)
            printf '%s' $(( $(_disch_now) - _lw ))
            return 0 ;;
        esac
    fi
    wake_age
}

_disch_vanished() {
    # Session file disappeared while PHASE != idle: sleep or cancel.
    local _now="$1" _result="cancelled" _reason="cancelled" _lw _wa
    if [ -f "$DASH/.last_wake" ]; then
        _lw=$(cat "$DASH/.last_wake" 2>/dev/null || echo 0)
        case "$_lw" in ''|*[!0-9]*) _lw=0 ;; esac
        if [ "$_lw" -gt "$DS_LAST_TICK" ] || { [ "$_lw" -le "$_now" ] && [ $(( _now - _lw )) -lt 300 ]; }; then
            _result="ended-by-sleep"; _reason="sleep"
        fi
    fi
    if [ "$_result" = "cancelled" ]; then
        _wa=$(wake_age 2>/dev/null || echo 999999)
        case "$_wa" in ''|*[!0-9-]*) _wa=999999 ;; esac
        if [ "$_wa" -lt 300 ] 2>/dev/null; then
            _result="ended-by-sleep"; _reason="sleep"
        fi
    fi
    dlog "SESSION_VANISHED result=$_result session=$DS_SESSION_STARTED $(_disch_readings)"
    _disch_end "$_result" "$_reason" "" "" 0 "$_now"
}

_disch_tick_update() {
    # $1 now, $2 gauge (1 = freeze LAST_PCT/LAST_CAP)
    local _now="$1" _gauge="$2" _ti
    if [ "$_gauge" != "1" ]; then
        DS_LAST_PCT="$PCT"
        DS_LAST_CAP="${CUR:-}"
    fi
    DS_LAST_EXT="${EXT:-}"
    if [ -n "${_disch_temp:-}" ]; then
        _ti="$_disch_temp_int"
        if [ -z "$DS_TEMP_MIN" ] || [ "$_ti" -lt "${_disch_tmin_int:-999}" ]; then
            DS_TEMP_MIN="$_disch_temp"; _disch_tmin_int="$_ti"
        fi
        if [ -z "$DS_TEMP_MAX" ] || [ "$_ti" -gt "${_disch_tmax_int:-0}" ]; then
            DS_TEMP_MAX="$_disch_temp"; _disch_tmax_int="$_ti"
        fi
    fi
    DS_LAST_TICK="$_now"
    DS_AC_WAS=${DS_AC_ENGAGED:-0}
    [ "${DS_AC_ENGAGED:-0}" = "1" ] && DS_AC_EVER=1
    _disch_save_state
}

# === Calibration run cross-checks (calibrate build 2026-11-14) ===
# Shared by the discharge monitor (session validation below) and the
# calibration run supervisor further down. The run file is
# $DASH/.calibration_run (KEY=value, owned by the supervisor). A run
# counts as LIVE only while its HEARTBEAT is <= 600 s old
# (CALIBRATION_RUN_STALE_MIN=10 — the same bound bc-limit v1.3
# applies) and its ABS_FLOOR parses inside the hard clamp [8, 20].
CAL_RUN_FILE="$DASH/.calibration_run"
CAL_LOG="$DASH/calibration.log"
CAL_RUN_STALE_S=600

clog() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" >> "$CAL_LOG" 2>/dev/null || true
}

# _cal_run_parse — parse the run file's identity fields into
# CAL_RUN_ID / CAL_LEG / CAL_HEARTBEAT / CAL_ABS_FLOOR.
# Returns 1 if the file is missing or lacks RUN_ID/LEG.
_cal_run_parse() {
    CAL_RUN_ID=""; CAL_LEG=""; CAL_HEARTBEAT=""; CAL_ABS_FLOOR=""
    [ -f "$CAL_RUN_FILE" ] || return 1
    local _k _v
    while IFS='=' read -r _k _v; do
        case "$_k" in
            RUN_ID) CAL_RUN_ID="$_v" ;;
            LEG) CAL_LEG="$_v" ;;
            HEARTBEAT) CAL_HEARTBEAT="$_v" ;;
            ABS_FLOOR) CAL_ABS_FLOOR="$_v" ;;
        esac
    done < "$CAL_RUN_FILE"
    [ -n "$CAL_RUN_ID" ] && [ -n "$CAL_LEG" ] || return 1
    return 0
}

# _cal_run_live — 0 if a parsed run is live (fresh heartbeat, sane
# ABS_FLOOR). Leaves CAL_RUN_ID / CAL_ABS_FLOOR set on success.
_cal_run_live() {
    _cal_run_parse || return 1
    validate_int "$CAL_ABS_FLOOR" 8 20 || return 1
    case "$CAL_HEARTBEAT" in ''|*[!0-9]*) return 1 ;; esac
    local _now _age
    _now=$(_disch_now)
    _age=$(( _now - CAL_HEARTBEAT ))
    [ "$_age" -lt -60 ] && return 1
    [ "$_age" -gt "$CAL_RUN_STALE_S" ] && return 1
    return 0
}

# _cal_session_check <run-id> <target> — 0 if a MODE=calibrate
# session is authorized by the live run (mirrors bc-limit v1.3).
_cal_session_check() {
    [ -n "$1" ] || return 1
    _cal_run_live || return 1
    [ "$1" = "$CAL_RUN_ID" ] || return 1
    validate_int "$2" "$CAL_ABS_FLOOR" 99 || return 1
    return 0
}

# === Discharge intent: resume across sleep (2026-11-14) ===
# pre_sleep_cleanup writes $DASH/.discharge_intent (TARGET,
# ORIGINAL_STARTED, EXPIRES = ORIGINAL_STARTED + 12 h) when it tears
# down a MODE=user session at sleep — user sessions only, never
# corrective or calibrate. On later awake ticks with no session
# file, the monitor evaluates the intent here:
#   drop (INTENT_DROPPED, logged) when expired, already at/below
#     target, malformed, or a calibration run is live;
#   recreate the session (STARTER=resume, STARTED=now,
#     ORIGINAL_STARTED preserved) once the resume gates pass —
#     >= 120 s since wake (the armed phase's own post-wake bound),
#     APG green, no AC-flip cooldown — whereupon the recreated
#     session re-arms under the FULL monitor rules (including the
#     APG budget pause above);
#   otherwise keep the intent and retry next tick, logging
#     INTENT_RESUME_BLOCKED once per block-reason episode
#     (companion file .discharge_intent_block).
# The recreated session carries a FRESH STARTED on purpose: the
# 240-min max-age bound (this monitor and bc-limit) applies per
# supervised session; the intent's 12 h EXPIRES bounds the chain.
_disch_intent_check() {
    local _now="$1"
    [ -f "$DISCHARGE_INTENT_FILE" ] || return 0
    local I_TARGET="" I_ORIG="" I_EXP="" _k _v
    while IFS='=' read -r _k _v; do
        case "$_k" in
            TARGET) I_TARGET="$_v" ;;
            ORIGINAL_STARTED) I_ORIG="$_v" ;;
            EXPIRES) I_EXP="$_v" ;;
        esac
    done < "$DISCHARGE_INTENT_FILE"
    case "$I_ORIG" in ''|*[!0-9]*) I_ORIG="" ;; esac
    if ! validate_int "$I_TARGET" 20 99; then
        dlog "INTENT_DROPPED reason=malformed target=${I_TARGET:-?} $(_disch_readings)"
        rm -f "$DISCHARGE_INTENT_FILE" "$DISCHARGE_INTENT_BLOCK_FILE"
        return 0
    fi
    case "$I_EXP" in ''|*[!0-9]*)
        dlog "INTENT_DROPPED reason=malformed target=$I_TARGET expires=${I_EXP:-?} $(_disch_readings)"
        rm -f "$DISCHARGE_INTENT_FILE" "$DISCHARGE_INTENT_BLOCK_FILE"
        return 0 ;;
    esac
    [ -n "$I_ORIG" ] || I_ORIG=$(( I_EXP - 43200 ))
    if [ "$_now" -gt "$I_EXP" ]; then
        dlog "INTENT_DROPPED reason=expired target=$I_TARGET original_started=$I_ORIG expires=$I_EXP $(_disch_readings)"
        rm -f "$DISCHARGE_INTENT_FILE" "$DISCHARGE_INTENT_BLOCK_FILE"
        return 0
    fi
    if [ "$PCT" -le "$I_TARGET" ]; then
        dlog "INTENT_DROPPED reason=goal-met target=$I_TARGET original_started=$I_ORIG $(_disch_readings)"
        rm -f "$DISCHARGE_INTENT_FILE" "$DISCHARGE_INTENT_BLOCK_FILE"
        return 0
    fi
    if _cal_run_live; then
        dlog "INTENT_DROPPED reason=calibration target=$I_TARGET original_started=$I_ORIG run=$CAL_RUN_ID $(_disch_readings)"
        rm -f "$DISCHARGE_INTENT_FILE" "$DISCHARGE_INTENT_BLOCK_FILE"
        return 0
    fi
    local _block="" _wa
    _wa=$(_disch_wake_age)
    case "$_wa" in ''|*[!0-9-]*) _wa=999999 ;; esac
    if [ "$_wa" -lt 120 ] 2>/dev/null; then
        _block="post-wake"
    elif [ -f "$APG_PAUSED" ] && _disch_apg_thermal; then
        # Temp gate (2026-11-15): intents are user-only by
        # construction; a load-only pause (temp < 38 C) must not
        # block the resume of a user-initiated session.
        _block="apg"
    elif [ -f "$DISCHARGE_COOLDOWN_FILE" ]; then
        local _until
        _until=$(grep '^UNTIL=' "$DISCHARGE_COOLDOWN_FILE" 2>/dev/null | cut -d= -f2)
        case "$_until" in ''|*[!0-9]*) _until=0 ;; esac
        [ "$_until" -gt "$_now" ] && _block="cooldown"
    fi
    if [ -n "$_block" ]; then
        local _prev=""
        [ -f "$DISCHARGE_INTENT_BLOCK_FILE" ] && _prev=$(cat "$DISCHARGE_INTENT_BLOCK_FILE" 2>/dev/null)
        if [ "$_prev" != "$_block" ]; then
            dlog "INTENT_RESUME_BLOCKED reason=$_block target=$I_TARGET original_started=$I_ORIG $(_disch_readings)"
            printf '%s\n' "$_block" > "$DISCHARGE_INTENT_BLOCK_FILE.tmp" \
                && mv "$DISCHARGE_INTENT_BLOCK_FILE.tmp" "$DISCHARGE_INTENT_BLOCK_FILE" || true
        fi
        return 0
    fi
    local _tmp="$DASH/.discharge_session.resume.tmp"
    {
        printf 'MODE=user\n'
        printf 'TARGET=%s\n' "$I_TARGET"
        printf 'STARTED=%s\n' "$_now"
        printf 'STARTER=resume\n'
        printf 'ORIGINAL_STARTED=%s\n' "$I_ORIG"
    } > "$_tmp" && mv "$_tmp" "$DISCHARGE_SESSION_REAL" || return 0
    rm -f "$DISCHARGE_INTENT_FILE" "$DISCHARGE_INTENT_BLOCK_FILE"
    dlog "SESSION_RESUMED target=$I_TARGET original_started=$I_ORIG starter=resume $(_disch_readings)"
    return 0
}

_disch_monitor_impl() {
    local _now _sig _gauge=0 _delta
    _now=$(_disch_now)
    D_SHADOW=0
    D_SESSION_FILE_CUR="$DISCHARGE_SESSION_REAL"
    if [ -f "$DISCHARGE_SHADOW_FLAG" ]; then
        D_SHADOW=1
        D_SESSION_FILE_CUR="$DISCHARGE_SESSION_SHADOW"
    fi
    # Battery temp (APG_TEMP from apg_classify; fallback bc-status).
    _disch_temp="${APG_TEMP:-}"
    if [ -z "$_disch_temp" ] && [ "${DISCHARGE_SNAPSHOT_FAIL:-0}" != "1" ]; then
        local _raw
        _raw=$(bc_status_value "TempBatteryPack" 2>/dev/null) || _raw=""
        _disch_temp=$(printf '%s' "$_raw" | tr -dc '0-9.')
    fi
    case "$_disch_temp" in ''|*[!0-9.]*) _disch_temp="" ;; esac
    _disch_temp_int=""
    if [ -n "$_disch_temp" ]; then
        _disch_temp_int="${_disch_temp%.*}"
        case "$_disch_temp_int" in ''|*[!0-9]*) _disch_temp_int=0 ;; esac
    fi
    _disch_load_state
    _disch_tmin_int=999; _disch_tmax_int=0
    if [ -n "$DS_TEMP_MIN" ]; then _disch_tmin_int="${DS_TEMP_MIN%.*}"; case "$_disch_tmin_int" in ''|*[!0-9]*) _disch_tmin_int=999 ;; esac; fi
    if [ -n "$DS_TEMP_MAX" ]; then _disch_tmax_int="${DS_TEMP_MAX%.*}"; case "$_disch_tmax_int" in ''|*[!0-9]*) _disch_tmax_int=0 ;; esac; fi
    if [ "$D_STATE_EXISTED" = "0" ]; then
        DS_LAST_TICK="$_now"
        _disch_save_state
        if [ "$D_SHADOW" = "1" ]; then
            dlog "MONITOR_START mode=SHADOW $(_disch_readings)"
        else
            dlog "MONITOR_START mode=REAL $(_disch_readings)"
        fi
    fi
    # Prune an expired flip cooldown (housekeeping, any phase).
    if [ -f "$DISCHARGE_COOLDOWN_FILE" ]; then
        local _until
        _until=$(grep '^UNTIL=' "$DISCHARGE_COOLDOWN_FILE" 2>/dev/null | cut -d= -f2)
        case "$_until" in ''|*[!0-9]*) _until=0 ;; esac
        if [ "$_until" -le "$_now" ]; then
            rm -f "$DISCHARGE_COOLDOWN_FILE" 2>/dev/null
            dlog "COOLDOWN_EXPIRED until=$_until"
        fi
    fi

    # --- Snapshot unreadable path (main routes here when ioreg fails) ---
    if [ "${DISCHARGE_SNAPSHOT_FAIL:-0}" = "1" ] || ! validate_int "${PCT:-}" 0 100; then
        if [ "$DS_PHASE" != "idle" ] && [ ! -f "$D_SESSION_FILE_CUR" ]; then
            _disch_vanished "$_now"
            return 0
        fi
        [ "$DS_PHASE" = "idle" ] && return 0
        DS_UNREADABLE=$(( DS_UNREADABLE + 1 ))
        dlog "SNAPSHOT_UNREADABLE count=$DS_UNREADABLE session=$DS_SESSION_STARTED"
        if [ "$DS_UNREADABLE" -ge 2 ]; then
            _disch_end "aborted" "data-unreadable" "discharge_aborted" \
                "Discharge aborted: battery data unreadable" 1 "$_now"
        else
            DS_LAST_TICK="$_now"
            _disch_save_state
        fi
        return 0
    fi
    DS_UNREADABLE=0

    # --- 0. Session file vanished while a session was supervised ---
    if [ "$DS_PHASE" != "idle" ] && [ ! -f "$D_SESSION_FILE_CUR" ]; then
        _disch_vanished "$_now"
        return 0
    fi

    # --- 1. No session file, PHASE idle: intent resume (real mode)
    # --- and shadow housekeeping (shadow mode) ---
    if [ ! -f "$D_SESSION_FILE_CUR" ]; then
        if [ "$D_SHADOW" = "0" ]; then
            _disch_intent_check "$_now"
        fi
        if [ "$D_SHADOW" = "1" ]; then
            local _thr
            _thr=$(( LAST_UPPER + 2 ))
            if [ "$PCT" -gt "$_thr" ]; then
                DS_SHADOW_CLAIM_COUNT=$(( DS_SHADOW_CLAIM_COUNT + 1 ))
                if _disch_second_signal; then DS_SHADOW_SIGNAL=1; fi
                if [ "$DS_SHADOW_CLAIM_COUNT" -eq "$DISCHARGE_CONFIRM_TICKS" ]; then
                    if [ "$DS_SHADOW_SIGNAL" = "1" ]; then
                        dlog "SHADOW_EVAL overshoot pct=$PCT signal=present -> corrective entry WOULD GRANT"
                    else
                        dlog "SHADOW_EVAL overshoot pct=$PCT signal=absent -> corrective entry WOULD REFUSE"
                    fi
                fi
            else
                DS_SHADOW_CLAIM_COUNT=0
                DS_SHADOW_SIGNAL=0
            fi
            DS_LAST_PCT="$PCT"
            DS_LAST_CAP="${CUR:-}"
            DS_LAST_TICK="$_now"
            _disch_save_state
        fi
        # A session recreated by the intent check above falls
        # through and arms in this same tick; otherwise done.
        [ -f "$D_SESSION_FILE_CUR" ] || return 0
    fi

    # --- 2. Session file present: parse + validate ---
    local S_MODE="" S_TARGET="" S_STARTED="" S_STARTER="" S_RUN="" S_PARK="" _k _v
    while IFS='=' read -r _k _v; do
        case "$_k" in
            MODE) S_MODE="$_v" ;;
            TARGET) S_TARGET="$_v" ;;
            STARTED) S_STARTED="$_v" ;;
            STARTER) S_STARTER="$_v" ;;
            RUN) S_RUN="$_v" ;;
            PARK) S_PARK="$_v" ;;
        esac
    done < "$D_SESSION_FILE_CUR"
    local _basic_ok=1 _age_fail=0
    # Calibrate build (2026-11-14): MODE=calibrate is valid only
    # under the live run cross-check (same rule as bc-limit v1.3);
    # its TARGET floor and the armed/active floor checks use the
    # run's ABS_FLOOR instead of DISCHARGE_FLOOR_ABS. A routine
    # session appearing while a run is live is refused (design
    # rule 10: one run, one actor).
    local _cal_ok=0 _eff_floor="$DISCHARGE_FLOOR_ABS" _tgt_min=20 _park=0 _routine_blocked=0
    if [ "$S_MODE" = "calibrate" ]; then
        if _cal_session_check "$S_RUN" "$S_TARGET"; then
            _cal_ok=1; _eff_floor="$CAL_ABS_FLOOR"; _tgt_min="$CAL_ABS_FLOOR"
        fi
        if [ "$S_PARK" = "1" ] && [ "$_cal_ok" = "1" ]; then _park=1; fi
    elif _cal_run_live; then
        _routine_blocked=1
    fi
    case "$S_MODE" in
        user|corrective) ;;
        calibrate) [ "$_cal_ok" = "1" ] || _basic_ok=0 ;;
        *) _basic_ok=0 ;;
    esac
    validate_int "$S_TARGET" "$_tgt_min" 99 || _basic_ok=0
    case "$S_STARTED" in ''|*[!0-9]*) _basic_ok=0 ;; *)
        if [ "$S_STARTED" -le 0 ] || [ "$S_STARTED" -gt "$_now" ]; then
            _basic_ok=0
        elif [ $(( _now - S_STARTED )) -gt $(( DISCHARGE_MAX_MINUTES * 60 )) ]; then
            _age_fail=1
        fi ;;
    esac
    # A session this monitor already supervises handles its own max-age
    # abort below; the stale check applies to files first seen now.
    if [ "$_age_fail" = "1" ] && [ "$DS_PHASE" != "idle" ] \
        && [ "$S_STARTED" = "$DS_SESSION_STARTED" ]; then
        _age_fail=0
        _basic_ok=1
        # (basic_ok may have been 1 already; age was the only failure
        #  that this exemption covers when the other checks passed)
        case "$S_MODE" in
            user|corrective) ;;
            calibrate) [ "$_cal_ok" = "1" ] || _basic_ok=0 ;;
            *) _basic_ok=0 ;;
        esac
        validate_int "$S_TARGET" "$_tgt_min" 99 || _basic_ok=0
    fi
    if [ "$_basic_ok" = "0" ] || [ "$_age_fail" = "1" ]; then
        local _reason="invalid-file" _result="refused"
        if [ "$_basic_ok" = "1" ] && [ "$_age_fail" = "1" ] && [ "$DS_PHASE" = "idle" ]; then
            _reason="stale"
        fi
        [ "$DS_PHASE" != "idle" ] && _result="aborted"
        dlog "SESSION_INVALID mode=${S_MODE:-?} target=${S_TARGET:-?} started=${S_STARTED:-?} starter=${S_STARTER:-?} reason=$_reason $(_disch_readings)"
        if [ "$DS_PHASE" = "idle" ]; then
            case "$S_STARTED" in ''|*[!0-9]*) DS_SESSION_STARTED=0 ;; *) DS_SESSION_STARTED="$S_STARTED" ;; esac
            DS_START_PCT="$PCT"
        fi
        _disch_end "$_result" "$_reason" "" "" 1 "$_now"
        return 0
    fi
    # One run, one actor (calibrate design rule 10): a routine
    # session file while a calibration run is live is refused.
    if [ "$_routine_blocked" = "1" ]; then
        dlog "SESSION_REFUSED reason=calibration session=$S_STARTED $(_disch_readings)"
        _disch_end "refused" "calibration" "" "" 1 "$_now"
        return 0
    fi

    # --- Initialise / re-initialise state from the file + snapshot ---
    if [ "$DS_PHASE" = "idle" ] || [ "$S_STARTED" != "$DS_SESSION_STARTED" ]; then
        DS_PHASE="armed"; DS_SESSION_STARTED="$S_STARTED"
        DS_CONFIRM_COUNT=0; DS_CONFIRM_SIGNAL=0; DS_OVERSHOOT_CLAIM=0
        DS_ARMED_TICKS=0; DS_COMP_COUNT=0; DS_START_PCT="$PCT"
        DS_PARKED_TOTAL_S=0; DS_PARK_SINCE=0; DS_APG_SINCE=0
        DS_LAST_PCT="$PCT"; DS_LAST_CAP="${CUR:-}"; DS_LAST_EXT="${EXT:-}"
        DS_FLIP_TIMES=""; DS_UNREADABLE=0
        DS_TEMP_MIN="$_disch_temp"; DS_TEMP_MAX="$_disch_temp"
        DS_LAST_TICK="$_now"; DS_CONFIG_SIG=$(_disch_config_sig)
        DS_SHADOW_CLAIM_COUNT=0; DS_SHADOW_SIGNAL=0; DS_EXTENDED=0
        DS_GAUGE_PCT=""; DS_APG_BLOCK=0
        DS_SEEN_BATT=0; DS_BATT_SINCE=0; DS_AC_WAS=0; DS_AC_EVER=0
        _disch_save_state
        dlog "SESSION_ARMED mode=$S_MODE target=$S_TARGET started=$S_STARTED starter=${S_STARTER:-?} $(_disch_readings)"
    fi
    D_TARGET="$S_TARGET"

    # --- On-AC actuator marker (bc-limit v1.6-ac) ---
    # .bc-limit-acengage exists exactly while bc-limit holds the
    # manager discharge mode engaged for THIS session (STARTED
    # match). While it stands — and on the tick right after it
    # clears (DS_AC_WAS) — an EXT flip is the actuator's doing,
    # not an unplug: the flip watch below must not count it.
    DS_AC_ENGAGED=0
    if [ -f "$DASH/.bc-limit-acengage" ]; then
        _ac_started=$(grep '^STARTED=' "$DASH/.bc-limit-acengage" 2>/dev/null | tail -1 | cut -d= -f2)
        [ "$_ac_started" = "$DS_SESSION_STARTED" ] && DS_AC_ENGAGED=1
    fi

    # --- Config supersede: a limit change ends the session ---
    _sig=$(_disch_config_sig)
    if [ "$_sig" != "$DS_CONFIG_SIG" ]; then
        dlog "SESSION_SUPERSEDED session=$DS_SESSION_STARTED $(_disch_readings)"
        _disch_end "ended" "superseded" "" "" 1 "$_now"
        return 0
    fi

    # --- EXT observation latch, armed phase (full-fix 2026-11-15) ---
    # EXT transitions used to be processed ONLY in the active phase:
    # in the armed phase _disch_tick_update silently overwrote
    # LAST_EXT every tick, so a sampled battery tick left no trace
    # anywhere — and an unplug shorter than the gap between the two
    # 60 s samplers (watchdog + daemon) left none at all. Live case
    # 2026-11-15: the user unplugged and replugged during an armed
    # session; FLIP_TIMES stayed empty, PARKED_TOTAL_S stayed 0, and
    # discharge.log recorded nothing. Latch the fact instead:
    # SEEN_BATT sticks for the rest of the session, transitions are
    # logged, and bc-limit's phase-offset state lines are
    # cross-checked while the latch is unset. This block sits before
    # the gauge deferral and before every APG branch on purpose:
    # observation is never paused — only decisions are. (The active
    # phase keeps its own flip watch below and needs no latch.)
    if [ "$DS_PHASE" = "armed" ]; then
        if [ "$DS_SEEN_BATT" != "1" ]; then
            if [ "${EXT:-}" = "No" ]; then
                DS_SEEN_BATT=1
                DS_BATT_SINCE="$_now"
                dlog "SESSION_ON_BATTERY source=watchdog session=$DS_SESSION_STARTED $(_disch_readings)"
            elif _disch_daemon_seen_batt; then
                DS_SEEN_BATT=1
                dlog "SESSION_ON_BATTERY source=daemon-log session=$DS_SESSION_STARTED $(_disch_readings)"
            fi
        fi
        if [ "${EXT:-}" = "No" ]; then
            [ "${DS_BATT_SINCE:-0}" = "0" ] && DS_BATT_SINCE="$_now"
        elif [ "${EXT:-}" = "Yes" ] && [ "${DS_BATT_SINCE:-0}" != "0" ]; then
            dlog "SESSION_BACK_ON_AC batt_s=$(( _now - DS_BATT_SINCE )) session=$DS_SESSION_STARTED $(_disch_readings)"
            DS_BATT_SINCE=0
        fi
    fi

    # --- Gauge tick: defer % decisions one tick ---
    if [ -n "$DS_LAST_PCT" ]; then
        _delta=$(( PCT - DS_LAST_PCT ))
        [ "$_delta" -lt 0 ] && _delta=$(( -_delta ))
        if [ "$_delta" -ge 5 ]; then
            if [ -n "${DS_GAUGE_PCT:-}" ] && [ "$PCT" = "$DS_GAUGE_PCT" ]; then
                # The jumped reading repeated EXACTLY on the next
                # tick: it is the gauge's settled level, not a
                # transient — accept it. This is the deferral's own
                # contract ("defer one tick; the next tick counts").
                # Without it, a rock-stable post-jump reading wedges
                # every % decision for the rest of the session:
                # LAST_PCT stays frozen on gauge ticks, so the delta
                # never falls below 5 (found 2026-11-14, hardening
                # seed 8, via R2-user-settle; a real bq20z451 can
                # hold one value for hours at zero current).
                DS_GAUGE_PCT=""
                dlog "GAUGE_ACCEPT pct=$PCT last_pct=$DS_LAST_PCT session=$DS_SESSION_STARTED $(_disch_readings)"
            else
                _gauge=1
                DS_GAUGE_PCT="$PCT"
                dlog "GAUGE_DEFER pct=$PCT last_pct=$DS_LAST_PCT session=$DS_SESSION_STARTED $(_disch_readings)"
            fi
        else
            DS_GAUGE_PCT=""
        fi
    fi

    if [ "$DS_PHASE" = "armed" ]; then
        if [ "$_gauge" = "1" ]; then
            _disch_tick_update "$_now" 1
            return 0
        fi
        # Calibrate L3 park session (PARK=1, run-authorized): issued
        # on AC at the floor by the run supervisor, so it starts
        # parked by design. Move straight to the active-parked
        # state — the floor/cooldown/temp refusals below must never
        # fire on it (it sits AT the floor, on AC, deliberately).
        if [ "$_park" = "1" ] && [ "$EXT" = "Yes" ]; then
            DS_PHASE="active"
            DS_PARK_SINCE="$_now"
            dlog "SESSION_PARKED reason=calibration-park session=$DS_SESSION_STARTED $(_disch_readings)"
            _disch_tick_update "$_now" 0
            return 0
        fi
        # Cooldown (AC-flip abort window) refuses a new session at once.
        if [ -f "$DISCHARGE_COOLDOWN_FILE" ]; then
            local _until2
            _until2=$(grep '^UNTIL=' "$DISCHARGE_COOLDOWN_FILE" 2>/dev/null | cut -d= -f2)
            case "$_until2" in ''|*[!0-9]*) _until2=0 ;; esac
            if [ "$_until2" -gt "$_now" ]; then
                dlog "SESSION_REFUSED reason=cooldown until=$_until2 session=$DS_SESSION_STARTED $(_disch_readings)"
                _disch_end "refused" "cooldown" "discharge_refused" \
                    "Discharge refused: cooldown after an AC flip abort" 1 "$_now"
                return 0
            fi
        fi
        if _disch_temp_critical; then
            dlog "SESSION_REFUSED reason=temp temp=$_disch_temp session=$DS_SESSION_STARTED $(_disch_readings)"
            _disch_end "refused" "temp" "discharge_refused" \
                "Discharge refused: battery temperature critical" 1 "$_now"
            return 0
        fi
        if [ "$PCT" -le "$_eff_floor" ]; then
            dlog "SESSION_REFUSED reason=floor pct=$PCT session=$DS_SESSION_STARTED $(_disch_readings)"
            _disch_end "refused" "floor" "discharge_refused" \
                "Discharge refused: battery at the absolute floor" 1 "$_now"
            return 0
        fi
        if [ $(( _now - DS_SESSION_STARTED )) -gt $(( DISCHARGE_MAX_MINUTES * 60 )) ]; then
            dlog "SESSION_ABORT reason=max-age session=$DS_SESSION_STARTED $(_disch_readings)"
            _disch_end "aborted" "max-age" "discharge_aborted" \
                "Discharge aborted: session exceeded its maximum lifetime" 1 "$_now"
            return 0
        fi
        local _wa
        _wa=$(_disch_wake_age)
        case "$_wa" in ''|*[!0-9-]*) _wa=999999 ;; esac
        if [ "$_wa" -lt "$POST_WAKE_DELAY_S" ] 2>/dev/null; then
            if ! grep -q "ARMED_WAIT session=$DS_SESSION_STARTED" "$DISCHARGE_LOG" 2>/dev/null; then
                dlog "ARMED_WAIT session=$DS_SESSION_STARTED wake_age=${_wa}s $(_disch_readings)"
            fi
            _disch_tick_update "$_now" 0
            return 0
        fi
        # APG in the armed phase (APG fix 2026-11-14; temp gate
        # 2026-11-15). MODE=user: an APG pause must NOT burn the
        # refusal budget. Live case 2026-11-14 22:35-22:40: a user
        # session started on AC, APG went yellow on CPU load (4.18)
        # at 22:36, the budget counted the paused ticks, and at
        # armed_ticks=6 the reason resolved to "apg" -> hard
        # SESSION_REFUSED, session deleted — a deliberate user
        # action silently gone, for the third time that evening.
        # The 2026-11-14 fix paused the user budget while
        # .apg_paused exists (no increment, one ARMING_BLOCKED_APG
        # line per block episode, max-age ABORT as the honest bound).
        #
        # Temp gate (owner's product rule, 2026-11-15): that pause
        # still froze a user session for a whole evening whenever
        # the pause was LOAD-only — APG yellow/red all evening from
        # a busy browser (load 5.4-10.07) at battery temp ~30.6 C.
        # For MODE=user and MODE=calibrate, a pause whose battery
        # temp is BELOW the 38 C yellow threshold no longer blocks
        # arming at all: DS_APG_BLOCK=2 marks the bypass (one
        # ARMING_APG_LOAD_BYPASSED line per episode) and counting
        # proceeds exactly as if unpaused. Temp >= 38 C or temp
        # unreadable = a genuine thermal gate: user/calibrate
        # budgets pause (DS_APG_BLOCK=1). MODE=corrective keeps the
        # historical behaviour: budget counts, confirmation does
        # not. The 240-min wall-clock max-age abort above still
        # bounds every blocked session (honest ABORT, never a
        # refusal), and a residual reason=apg outcome for MODE=user
        # is still routed into the extended wait at the refusal
        # site below, as defence in depth.
        local _apg_blocks=0 _apg_state=0
        if [ -f "$APG_PAUSED" ]; then
            if { [ "$S_MODE" = "user" ] || [ "$S_MODE" = "calibrate" ]; } \
                && ! _disch_apg_thermal; then
                _apg_state=2
            else
                _apg_blocks=1; _apg_state=1
            fi
        fi
        if [ "$_apg_state" != "${DS_APG_BLOCK:-0}" ]; then
            if [ "$_apg_state" = "1" ]; then
                dlog "ARMING_BLOCKED_APG session=$DS_SESSION_STARTED $(_disch_readings)"
            elif [ "$_apg_state" = "2" ]; then
                dlog "ARMING_APG_LOAD_BYPASSED session=$DS_SESSION_STARTED $(_disch_readings)"
            elif [ "${DS_APG_BLOCK:-0}" = "1" ]; then
                dlog "ARMING_RESUMED_APG session=$DS_SESSION_STARTED $(_disch_readings)"
            fi
            DS_APG_BLOCK="$_apg_state"
        fi
        if [ "$_apg_blocks" = "1" ]; then
            if [ "$S_MODE" = "corrective" ]; then
                DS_ARMED_TICKS=$(( DS_ARMED_TICKS + 1 ))
            fi
        else
            DS_ARMED_TICKS=$(( DS_ARMED_TICKS + 1 ))
            if [ "$PCT" -gt "$S_TARGET" ]; then
                DS_CONFIRM_COUNT=$(( DS_CONFIRM_COUNT + 1 ))
                DS_COMP_COUNT=0
            else
                DS_CONFIRM_COUNT=0
                DS_COMP_COUNT=$(( DS_COMP_COUNT + 1 ))
            fi
            if [ "$PCT" -gt $(( LAST_UPPER + 2 )) ]; then
                DS_OVERSHOOT_CLAIM=1
            elif [ "${DS_EXTENDED:-0}" = "1" ] && [ "$S_MODE" = "user" ] \
                && [ "$DS_OVERSHOOT_CLAIM" = "1" ]; then
                # Extended arming (below): the reading has settled
                # back inside the +2 guard band, so the overshoot
                # claim that kept this user session waiting has
                # dissolved — ordinary count confirmation proceeds.
                DS_OVERSHOOT_CLAIM=0
                dlog "OVERSHOOT_CLAIM_CLEARED pct=$PCT session=$DS_SESSION_STARTED $(_disch_readings)"
            fi
            if _disch_second_signal; then DS_CONFIRM_SIGNAL=1; fi
            if [ "$S_MODE" = "user" ] && _disch_drain_evidence; then
                # Battery-side confirmation (2026-11-15): the drain
                # the user asked for is observably happening. An
                # overshoot-claim session can now activate on the
                # first sampled battery tick instead of waiting for
                # the claim to dissolve at UPPER+2.
                if [ "$DS_CONFIRM_SIGNAL" != "1" ]; then
                    dlog "SESSION_DRAIN_SIGNAL session=$DS_SESSION_STARTED $(_disch_readings)"
                fi
                DS_CONFIRM_SIGNAL=1
            fi
            if [ "$DS_COMP_COUNT" -ge "$DISCHARGE_CONFIRM_TICKS" ]; then
                dlog "SESSION_COMPLETE reason=already-at-target session=$DS_SESSION_STARTED $(_disch_readings)"
                _disch_end "completed" "already-at-target" "discharge_completed" \
                    "Discharge complete: already at target ${S_TARGET}%" 1 "$_now"
                return 0
            fi
            if [ "$DS_CONFIRM_COUNT" -ge "$DISCHARGE_CONFIRM_TICKS" ] \
                && { [ "$DS_OVERSHOOT_CLAIM" = "0" ] || [ "$DS_CONFIRM_SIGNAL" = "1" ]; }; then
                DS_PHASE="active"
                dlog "SESSION_ACTIVE mode=$S_MODE target=$S_TARGET session=$DS_SESSION_STARTED $(_disch_readings)"
                if [ "$EXT" = "Yes" ]; then
                    DS_PARK_SINCE="$_now"
                    dlog "SESSION_PARKED session=$DS_SESSION_STARTED $(_disch_readings)"
                fi
                _disch_tick_update "$_now" 0
                return 0
            fi
        fi
        if [ "$DS_ARMED_TICKS" -gt 5 ]; then
            local _reason="no-confirmation"
            if [ -f "$APG_PAUSED" ] && [ "$DS_CONFIRM_COUNT" -lt "$DISCHARGE_CONFIRM_TICKS" ]; then
                _reason="apg"
            elif [ "$DS_OVERSHOOT_CLAIM" = "1" ] && [ "$DS_CONFIRM_SIGNAL" = "0" ] \
                && [ "$DS_CONFIRM_COUNT" -ge "$DISCHARGE_CONFIRM_TICKS" ]; then
                _reason="no-second-signal"
            fi
            if { [ "$_reason" = "no-second-signal" ] || [ "$_reason" = "apg" ]; } \
                && [ "$S_MODE" = "user" ]; then
                # EXTENDED ARMING (hardening 2026-11-14; APG route
                # added by the APG fix the same evening): a USER
                # session whose overshoot claim has no second signal
                # is no longer deleted. Design rule 2 stands — it can
                # never reach ACTIVE on a % reading alone — but the
                # 2026-11-14 21:37 live case (settled gauge drift to
                # 90% at zero current, session started on AC) could
                # NEVER produce a second signal while holding, so the
                # refusal made a deliberate user action silently
                # vanish. The session now stays ARMED: it confirms
                # the moment a second signal appears or the reading
                # settles back inside the +2 band (claim dissolve,
                # above), and the existing max-age abort still bounds
                # it. The reason=apg route is defence in depth for
                # the budget pause above (a user session that still
                # resolves to "apg" — e.g. an already-exhausted
                # budget when the pause lands — waits instead of
                # being refused). MODE=corrective claims (the
                # watchdog's own inference) keep the hard refusal
                # below, unchanged, for both reasons.
                if [ "${DS_EXTENDED:-0}" != "1" ]; then
                    DS_EXTENDED=1
                    dlog "SESSION_ARMING_EXTENDED reason=$_reason session=$DS_SESSION_STARTED $(_disch_readings)"
                fi
                DS_ARMED_TICKS=0
                _disch_tick_update "$_now" 0
                return 0
            fi
            dlog "SESSION_REFUSED reason=$_reason armed_ticks=$DS_ARMED_TICKS session=$DS_SESSION_STARTED $(_disch_readings)"
            _disch_end "refused" "$_reason" "discharge_refused" \
                "Discharge refused: entry not confirmed ($_reason)" 1 "$_now"
            return 0
        fi
        _disch_tick_update "$_now" 0
        return 0
    fi

    if [ "$DS_PHASE" = "active" ]; then
        # EXT transitions + AC-flip watch (also on gauge ticks).
        if [ -n "$DS_LAST_EXT" ] && [ "$EXT" != "$DS_LAST_EXT" ] \
            && { [ "$EXT" = "Yes" ] || [ "$EXT" = "No" ]; } \
            && { [ "$DS_LAST_EXT" = "Yes" ] || [ "$DS_LAST_EXT" = "No" ]; }; then
            local _list="$DS_FLIP_TIMES" _e _out="" _cnt=0 _f1=0 _f2=0
            local _flip_exempt=0
            if [ "${DS_AC_ENGAGED:-0}" = "1" ] || [ "${DS_AC_WAS:-0}" = "1" ]; then
                _flip_exempt=1
                dlog "SESSION_AC_FLIP_EXPECTED ext=$EXT session=$DS_SESSION_STARTED $(_disch_readings)"
            fi
            [ "$_flip_exempt" = "0" ] && _list="${_list:+$_list,}$_now"
            while [ -n "$_list" ]; do
                case "$_list" in
                    *,*) _e="${_list%%,*}"; _list="${_list#*,}" ;;
                    *) _e="$_list"; _list="" ;;
                esac
                case "$_e" in ''|*[!0-9]*) continue ;; esac
                if [ $(( _now - _e )) -le 300 ]; then
                    _out="${_out:+$_out,}$_e"; _cnt=$(( _cnt + 1 )); _f1="$_f2"; _f2="$_e"
                fi
            done
            DS_FLIP_TIMES="$_out"
            if [ "$EXT" = "Yes" ]; then
                DS_PARK_SINCE="$_now"
                dlog "SESSION_PARKED session=$DS_SESSION_STARTED flips=$_cnt $(_disch_readings)"
            else
                if [ "$DS_PARK_SINCE" -gt 0 ]; then
                    DS_PARKED_TOTAL_S=$(( DS_PARKED_TOTAL_S + _now - DS_PARK_SINCE ))
                    DS_PARK_SINCE=0
                fi
                dlog "SESSION_UNPARKED session=$DS_SESSION_STARTED flips=$_cnt $(_disch_readings)"
            fi
            if [ "$_flip_exempt" = "0" ] && [ "$_cnt" -ge 2 ]; then
                local _freason="ac-flip"
                if [ $(( _f1 - DS_SESSION_STARTED )) -le 60 ] \
                    && [ $(( _f2 - DS_SESSION_STARTED )) -le 60 ]; then
                    _freason="ac-flip-signature"
                fi
                atomic_write "$DISCHARGE_COOLDOWN_FILE" "UNTIL=$(( _now + DISCHARGE_FLIP_COOLDOWN_MIN * 60 ))
" || true
                dlog "SESSION_ABORT reason=$_freason flips=$_cnt cooldown_min=$DISCHARGE_FLIP_COOLDOWN_MIN session=$DS_SESSION_STARTED $(_disch_readings)"
                _disch_end "aborted" "$_freason" "discharge_aborted" \
                    "Discharge aborted: AC connection flipping" 1 "$_now"
                return 0
            fi
        fi
        # Bounded lifetime (parked time included).
        if [ $(( _now - DS_SESSION_STARTED )) -gt $(( DISCHARGE_MAX_MINUTES * 60 )) ]; then
            dlog "SESSION_ABORT reason=max-age session=$DS_SESSION_STARTED $(_disch_readings)"
            _disch_end "aborted" "max-age" "discharge_aborted" \
                "Discharge aborted: session exceeded its maximum lifetime" 1 "$_now"
            return 0
        fi
        # Completion BEFORE APG (monitor fix 2026-11-13): a session that
        # has reached its target is finished — APG must not suspend it,
        # and the 15-min APG abort must not fire while it sits at target.
        # On a non-gauge tick the floor abort keeps its precedence; then
        # an unparked session at/below target owns the tick: the design
        # §5.5 counter (DISCHARGE_CONFIRM_TICKS consecutive ticks at/below
        # target) runs whether or not APG is paused, and the APG block
        # below is skipped for that tick.
        # v1.6-ac: a session that AC-drained (DS_AC_EVER) ends
        # parked ON AC at/below target by construction — the
        # actuator disengages at the target and the adapter path
        # returns. Its completion counting therefore runs parked
        # too; a never-engaged parked session keeps the old rule
        # (a parked reading at/below target proves nothing).
        local _comp_claims=0
        if [ "$_gauge" != "1" ]; then
            # Floor abort takes precedence over completion counting.
            # (Calibrate: the floor is the run's ABS_FLOOR via
            # _eff_floor; routine sessions keep DISCHARGE_FLOOR_ABS.)
            if [ "$PCT" -le "$_eff_floor" ] && [ "$S_TARGET" -gt "$_eff_floor" ]; then
                dlog "SESSION_ABORT reason=floor pct=$PCT session=$DS_SESSION_STARTED $(_disch_readings)"
                _disch_end "aborted" "floor" "discharge_aborted" \
                    "Discharge aborted: battery at the absolute floor" 1 "$_now"
                return 0
            fi
            if [ "$DS_PARK_SINCE" = "0" ] || [ "${DS_AC_EVER:-0}" = "1" ]; then
                if [ "$PCT" -le "$S_TARGET" ]; then
                    _comp_claims=1
                    DS_COMP_COUNT=$(( DS_COMP_COUNT + 1 ))
                    if [ "$DS_COMP_COUNT" -ge "$DISCHARGE_CONFIRM_TICKS" ]; then
                        dlog "SESSION_COMPLETE target=$S_TARGET session=$DS_SESSION_STARTED $(_disch_readings)"
                        _disch_end "completed" "target-reached" "discharge_completed" \
                            "Discharge complete: reached target ${S_TARGET}%" 1 "$_now"
                        return 0
                    fi
                else
                    DS_COMP_COUNT=0
                fi
            else
                DS_COMP_COUNT=0
            fi
        fi
        if [ "$_comp_claims" = "0" ]; then  # APG block: skipped on a completion-owned tick
        # APG suspension (counts as parked for completion purposes).
        # Temp gate (2026-11-15, owner's rule): for MODE=user and
        # MODE=calibrate sessions the suspension + 15-min abort apply
        # only while the pause is THERMAL (temp >= 38 C or temp
        # unreadable, _disch_apg_thermal). A load-only pause (temp
        # < 38 C) never suspends a user session mid-drain — CPU load
        # is not a thermal emergency. MODE=corrective keeps the
        # historical behaviour (any pause suspends). If a thermal
        # suspension is in force and the pause turns load-only, the
        # elif below clears it with SESSION_RESUMED, as when the
        # pause file disappears.
        local _apg_susp=0 _apg_applies=0
        if [ -f "$APG_PAUSED" ]; then
            if [ "$S_MODE" = "corrective" ] || _disch_apg_thermal; then
                _apg_applies=1
            fi
        fi
        if [ "$_apg_applies" = "1" ]; then
            if [ "$DS_APG_SINCE" = "0" ]; then
                DS_APG_SINCE="$_now"
                dlog "SESSION_SUSPENDED reason=apg session=$DS_SESSION_STARTED $(_disch_readings)"
            fi
            _apg_susp=1
            if [ $(( _now - DS_APG_SINCE )) -ge 900 ]; then
                dlog "SESSION_ABORT reason=apg suspended_s=$(( _now - DS_APG_SINCE )) session=$DS_SESSION_STARTED $(_disch_readings)"
                _disch_end "aborted" "apg" "discharge_aborted" \
                    "Discharge aborted: thermal pause over 15 minutes" 1 "$_now"
                return 0
            fi
        elif [ "$DS_APG_SINCE" != "0" ]; then
            DS_APG_SINCE=0
            dlog "SESSION_RESUMED session=$DS_SESSION_STARTED $(_disch_readings)"
        fi
        fi
        # Parked continuously on AC beyond the park timeout: end incomplete.
        # (Calibrate PARK=1 sessions are exempt: a calibration park
        # is a designed checkpoint whose timer the run supervisor
        # owns — calibrate design section 3.2.)
        if [ "$DS_PARK_SINCE" -gt 0 ] && [ "$_park" != "1" ] \
            && [ $(( _now - DS_PARK_SINCE )) -gt $(( DISCHARGE_PARK_TIMEOUT_MIN * 60 )) ]; then
            dlog "SESSION_END_INCOMPLETE reason=park-timeout parked_s=$(( _now - DS_PARK_SINCE )) session=$DS_SESSION_STARTED $(_disch_readings)"
            _disch_end "incomplete" "park-timeout" "discharge_ended" \
                "Discharge ended incomplete: parked on AC too long" 1 "$_now"
            return 0
        fi
        if _disch_temp_critical; then
            dlog "SESSION_ABORT reason=temp temp=$_disch_temp session=$DS_SESSION_STARTED $(_disch_readings)"
            _disch_end "aborted" "temp" "discharge_aborted" \
                "Discharge aborted: battery temperature critical" 1 "$_now"
            return 0
        fi
        _disch_tick_update "$_now" "$_gauge"
        return 0
    fi

    _disch_tick_update "$_now" "$_gauge"
    return 0
}

section_discharge_monitor() {
    _disch_monitor_impl 2>/dev/null || true
    return 0
}



# === Calibration run supervisor (calibrate build 2026-11-14, ===
# === calibrate-design.md sections 3, 5 and 7) ===
# Owns .calibration_run tick by tick: heartbeat, the leg state
# machine (L0 preflight -> L1 charge -> L1R rest -> L2 segmented
# discharge -> L3 low rest -> L4 recharge -> L5 close-out),
# two-signal endpoints, sleep checkpoints, and the single safe
# state every abort/failure/cancel funnels through.
#
# The supervisor NEVER writes BCLM. Config changes go through
# dispatch's bc_apply_limit (the single config writer) via the
# calibration_apply_limit action; the L2 power posture goes
# through dispatch's calibration_posture_on/off actions. Discharge
# segments are ordinary session files (MODE=calibrate) supervised
# by the discharge monitor above; their outcomes are read back
# from the EPISODE lines in discharge.log.
#
# Safe state (destination of EVERY exit except L5 completion,
# which ends there too after restoring): session file removed,
# power posture restored and verified, config restored to the
# user's pre-run limit (unless the user deliberately changed it
# mid-run — rule 14: their value wins), run file removed, one
# notification with the reason.
CAL_RESUME_FILE="$DASH/.calibration_resume_request"
CAL_CANCEL_FILE="$DASH/.calibration_cancel_request"
CAL_FAILS_FILE="$DASH/.calibration_data_fails"
CAL_POSTURE_STATE="$DASH/.calibration_posture_state"
CAL_REPORTS_DIR="$DASH/reports"
CAL_RUN_MAX_S=259200        # 72 h run bound (design rule 8)
CAL_L0_MAX_S=3600           # preflight must reach L1 within 1 h
CAL_LEG_BOUND_L1=21600      # 6 h
CAL_LEG_BOUND_L2=86400      # 24 h wall for the whole discharge leg
CAL_LEG_BOUND_L3=7200       # 2 h
CAL_LEG_BOUND_L4=28800      # 8 h
CAL_REST_TOP_S=3600         # 60 min rest at full (design section 3.1)
CAL_REST_LOW_S=1800         # 30 min rest at floor (design section 3.3)
CAL_REST_OUT_S=1800         # 30 min close-out rest (design section 3.5)
CAL_FULL_TICKS_NEED=2       # two-signal: pct=100 on 2 ticks
CAL_FLOOR_V_MV=10900        # two-signal: pack voltage <= 10.9 V
CAL_NOW=0
CAL_DELTA=0
CAL_NEW_HEALTH_X10=""

# _cal_load_run — parse .calibration_run into C_* globals.
# Returns 1 when the file is missing or corrupt (identity/bounds
# fields invalid). Tolerant fields fall back to safe defaults.
_cal_load_run() {
    [ -f "$CAL_RUN_FILE" ] || return 1
    C_RUN_ID=""; C_LEG=""; C_PROFILE=""; C_FLOOR=""; C_ABS_FLOOR=""
    C_SUPERVISION=0; C_HEALTH_X10=""; C_CYCLES=""; C_BASE_MAXCAP=""
    C_BASE_UPPER=""; C_BASE_LOWER=""; C_STARTED=""; C_HEARTBEAT=0
    C_CONFIG_PHASE="base"; C_EXPECT_U=""; C_EXPECT_L=""
    C_LEG_STARTED=0; C_L2_STARTED=0; C_SEGMENTS=0
    C_SEG_STARTED=0; C_SEG_TARGET=0; C_SEG_LOG_LINE=0
    C_FULL_TICKS=0; C_FLOOR_TICKS=0; C_FLOOR_VOLT_OK=0; C_EMERG_TICKS=0
    C_REST_REMAIN=0; C_WAITING=0; C_AWAIT=""; C_APG_SINCE=0
    C_WAIT_KEY=""; C_CONT_TARGET=""; C_PARK_LAST_ISSUE=0
    C_PARK_REISSUES=0; C_NOTIFY_KEY=""
    local _k _v
    while IFS='=' read -r _k _v; do
        case "$_k" in
            RUN_ID) C_RUN_ID="$_v" ;;
            LEG) C_LEG="$_v" ;;
            PROFILE) C_PROFILE="$_v" ;;
            FLOOR) C_FLOOR="$_v" ;;
            ABS_FLOOR) C_ABS_FLOOR="$_v" ;;
            SUPERVISION) C_SUPERVISION="$_v" ;;
            HEALTH_X10) C_HEALTH_X10="$_v" ;;
            CYCLES) C_CYCLES="$_v" ;;
            BASE_MAXCAP) C_BASE_MAXCAP="$_v" ;;
            BASE_UPPER) C_BASE_UPPER="$_v" ;;
            BASE_LOWER) C_BASE_LOWER="$_v" ;;
            STARTED) C_STARTED="$_v" ;;
            HEARTBEAT) C_HEARTBEAT="$_v" ;;
            CONFIG_PHASE) C_CONFIG_PHASE="$_v" ;;
            EXPECT_U) C_EXPECT_U="$_v" ;;
            EXPECT_L) C_EXPECT_L="$_v" ;;
            LEG_STARTED) C_LEG_STARTED="$_v" ;;
            L2_STARTED) C_L2_STARTED="$_v" ;;
            SEGMENTS) C_SEGMENTS="$_v" ;;
            SEG_STARTED) C_SEG_STARTED="$_v" ;;
            SEG_TARGET) C_SEG_TARGET="$_v" ;;
            SEG_LOG_LINE) C_SEG_LOG_LINE="$_v" ;;
            FULL_TICKS) C_FULL_TICKS="$_v" ;;
            FLOOR_TICKS) C_FLOOR_TICKS="$_v" ;;
            FLOOR_VOLT_OK) C_FLOOR_VOLT_OK="$_v" ;;
            EMERG_TICKS) C_EMERG_TICKS="$_v" ;;
            REST_REMAIN) C_REST_REMAIN="$_v" ;;
            WAITING) C_WAITING="$_v" ;;
            AWAIT) C_AWAIT="$_v" ;;
            APG_SINCE) C_APG_SINCE="$_v" ;;
            WAIT_KEY) C_WAIT_KEY="$_v" ;;
            CONT_TARGET) C_CONT_TARGET="$_v" ;;
            PARK_LAST_ISSUE) C_PARK_LAST_ISSUE="$_v" ;;
            PARK_REISSUES) C_PARK_REISSUES="$_v" ;;
            NOTIFY_KEY) C_NOTIFY_KEY="$_v" ;;
        esac
    done < "$CAL_RUN_FILE"
    [ -n "$C_RUN_ID" ] || return 1
    case "$C_LEG" in L0|L1|L1R|L2|L3|L4|L5) ;; *) return 1 ;; esac
    validate_int "$C_STARTED" 1 9999999999 || return 1
    validate_int "$C_FLOOR" 5 30 || return 1
    validate_int "$C_ABS_FLOOR" 8 20 || return 1
    [ "$C_ABS_FLOOR" -le "$C_FLOOR" ] || return 1
    validate_int "$C_BASE_UPPER" 15 100 || return 1
    validate_int "$C_BASE_LOWER" 15 99 || return 1
    validate_int "$C_EXPECT_U" 15 100 || return 1
    validate_int "$C_EXPECT_L" 15 99 || return 1
    # Numeric tolerances: a garbled counter resets to 0, never aborts.
    C_HEARTBEAT=$(_cal_num "$C_HEARTBEAT")
    C_LEG_STARTED=$(_cal_num "$C_LEG_STARTED")
    C_L2_STARTED=$(_cal_num "$C_L2_STARTED")
    C_SEGMENTS=$(_cal_num "$C_SEGMENTS")
    C_SEG_STARTED=$(_cal_num "$C_SEG_STARTED")
    C_SEG_TARGET=$(_cal_num "$C_SEG_TARGET")
    C_SEG_LOG_LINE=$(_cal_num "$C_SEG_LOG_LINE")
    C_FULL_TICKS=$(_cal_num "$C_FULL_TICKS")
    C_FLOOR_TICKS=$(_cal_num "$C_FLOOR_TICKS")
    C_FLOOR_VOLT_OK=$(_cal_num "$C_FLOOR_VOLT_OK")
    C_EMERG_TICKS=$(_cal_num "$C_EMERG_TICKS")
    C_REST_REMAIN=$(_cal_num "$C_REST_REMAIN")
    C_WAITING=$(_cal_num "$C_WAITING")
    C_APG_SINCE=$(_cal_num "$C_APG_SINCE")
    C_PARK_LAST_ISSUE=$(_cal_num "$C_PARK_LAST_ISSUE")
    C_PARK_REISSUES=$(_cal_num "$C_PARK_REISSUES")
    C_SUPERVISION=$(_cal_num "$C_SUPERVISION")
    return 0
}

# _cal_num — echo the argument if it is a non-negative integer, else 0.
_cal_num() {
    case "$1" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac
}

# _cal_save_run — atomic full rewrite of the run file from C_*.
_cal_save_run() {
    atomic_write "$CAL_RUN_FILE" "RUN_ID=$C_RUN_ID
LEG=$C_LEG
PROFILE=$C_PROFILE
FLOOR=$C_FLOOR
ABS_FLOOR=$C_ABS_FLOOR
SUPERVISION=$C_SUPERVISION
HEALTH_X10=$C_HEALTH_X10
CYCLES=$C_CYCLES
BASE_MAXCAP=$C_BASE_MAXCAP
BASE_UPPER=$C_BASE_UPPER
BASE_LOWER=$C_BASE_LOWER
STARTED=$C_STARTED
HEARTBEAT=$C_HEARTBEAT
CONFIG_PHASE=$C_CONFIG_PHASE
EXPECT_U=$C_EXPECT_U
EXPECT_L=$C_EXPECT_L
LEG_STARTED=$C_LEG_STARTED
L2_STARTED=$C_L2_STARTED
SEGMENTS=$C_SEGMENTS
SEG_STARTED=$C_SEG_STARTED
SEG_TARGET=$C_SEG_TARGET
SEG_LOG_LINE=$C_SEG_LOG_LINE
FULL_TICKS=$C_FULL_TICKS
FLOOR_TICKS=$C_FLOOR_TICKS
FLOOR_VOLT_OK=$C_FLOOR_VOLT_OK
EMERG_TICKS=$C_EMERG_TICKS
REST_REMAIN=$C_REST_REMAIN
WAITING=$C_WAITING
AWAIT=$C_AWAIT
APG_SINCE=$C_APG_SINCE
WAIT_KEY=$C_WAIT_KEY
CONT_TARGET=$C_CONT_TARGET
PARK_LAST_ISSUE=$C_PARK_LAST_ISSUE
PARK_REISSUES=$C_PARK_REISSUES
NOTIFY_KEY=$C_NOTIFY_KEY
"
}

_cal_set_leg() {
    C_LEG="$1"
    C_LEG_STARTED="$CAL_NOW"
    C_WAIT_KEY=""
    C_APG_SINCE=0
    C_NOTIFY_KEY=""
}

# _cal_wait <key> <log-line> — log a waiting state once per key.
_cal_wait() {
    if [ "$C_WAIT_KEY" != "$1" ]; then
        C_WAIT_KEY="$1"
        clog "$2"
    fi
    C_AWAIT="$3"
}

# _cal_voltage_mv — pack voltage in mV from ioreg (top-level key),
# or empty when unreadable.
_cal_voltage_mv() {
    local _mv
    _mv=$(ioreg -rn AppleSmartBattery 2>/dev/null \
        | grep -oE '"Voltage" = [0-9]+' | head -1 | grep -oE '[0-9]+$')
    case "$_mv" in ''|*[!0-9]*) _mv="" ;; esac
    printf '%s' "$_mv"
}

# _cal_segment_outcome — echoes "<result> <reason>" from the first
# EPISODE line in discharge.log for the current segment (written
# after SEG_LOG_LINE); empty when the monitor has not closed the
# segment yet. Falls back to a whole-file scan when the log was
# rotated mid-segment (line numbers shifted).
_cal_segment_outcome() {
    [ -f "$DISCHARGE_LOG" ] || return 0
    [ "${C_SEG_STARTED:-0}" -gt 0 ] 2>/dev/null || return 0
    local _start="${C_SEG_LOG_LINE:-0}" _total
    _total=$(wc -l < "$DISCHARGE_LOG" 2>/dev/null | tr -d ' ')
    case "$_total" in ''|*[!0-9]*) _total=0 ;; esac
    [ "$_start" -gt "$_total" ] && _start=0
    local _line _res _rsn
    _line=$(awk -v start="$_start" -v id="$C_SEG_STARTED" '
        NR > start && index($0, "EPISODE id=" id " ") > 0 { print; exit }' \
        "$DISCHARGE_LOG" 2>/dev/null)
    [ -n "$_line" ] || return 0
    _res=$(printf '%s' "$_line" | grep -oE 'result=[a-z-]+' | head -1 | cut -d= -f2)
    _rsn=$(printf '%s' "$_line" | grep -oE 'reason=[a-z-]+' | head -1 | cut -d= -f2)
    printf '%s %s' "${_res:-?}" "${_rsn:-?}"
}

# _cal_session_is_ours — 0 when the live session file is this run's.
_cal_session_is_ours() {
    [ -f "$DISCHARGE_SESSION_REAL" ] || return 1
    grep -q '^MODE=calibrate' "$DISCHARGE_SESSION_REAL" 2>/dev/null || return 1
    grep -q "^RUN=${C_RUN_ID}\$" "$DISCHARGE_SESSION_REAL" 2>/dev/null || return 1
    return 0
}

# _cal_remove_session — remove the session file if it is this run's.
_cal_remove_session() {
    if _cal_session_is_ours; then
        rm -f "$DISCHARGE_SESSION_REAL"
        dlog "SESSION_ENDED reason=calibration-supervisor session=$C_SEG_STARTED"
    fi
}

# _cal_restore_state — the state-restoration half of the safe
# state: power posture (dispatch verifies by re-reading pmset),
# then the config — restored only when the temp limit is still
# the live one (rule 14: a deliberate user change is never
# stomped). Returns 1 only on a genuine restore failure.
_cal_restore_state() {
    local _fail=0
    if [ -f "$CAL_POSTURE_STATE" ]; then
        if "$DASH/dispatch.sh" calibration_posture_off >/dev/null 2>&1; then
            clog "POSTURE_RESTORED run=$C_RUN_ID"
        else
            clog "POSTURE_RESTORE_FAILED run=$C_RUN_ID"
            _fail=1
        fi
    fi
    if [ "$C_CONFIG_PHASE" = "temp" ]; then
        local _cu _cl
        _cu=$(grep '^LAST_UPPER=' "$CFG" 2>/dev/null | cut -d= -f2)
        _cl=$(grep '^LAST_LOWER=' "$CFG" 2>/dev/null | cut -d= -f2)
        if [ "$_cu" = "$C_EXPECT_U" ] && [ "$_cl" = "$C_EXPECT_L" ]; then
            if "$DASH/dispatch.sh" calibration_apply_limit \
                    "$C_BASE_UPPER" "$C_BASE_LOWER" >/dev/null 2>&1; then
                clog "CONFIG_RESTORED upper=$C_BASE_UPPER lower=$C_BASE_LOWER run=$C_RUN_ID"
            else
                clog "CONFIG_RESTORE_FAILED run=$C_RUN_ID"
                _fail=1
            fi
        else
            clog "CONFIG_LEFT_AS_USER_SET upper=${_cu:-?} lower=${_cl:-?} run=$C_RUN_ID"
        fi
    fi
    return $_fail
}

# _cal_end_common — mode marker back to the resting state, marker
# files cleared, run file removed. (The run is over when this is
# called; nothing may be saved afterwards.)
_cal_end_common() {
    printf 'hold\n' > "$DASH/.active_mode.cal.tmp" 2>/dev/null \
        && mv "$DASH/.active_mode.cal.tmp" "$DASH/.active_mode" 2>/dev/null
    rm -f "$CAL_RESUME_FILE" "$CAL_CANCEL_FILE" "$CAL_FAILS_FILE" 2>/dev/null
    rm -f "$CAL_RUN_FILE" 2>/dev/null
}

# _cal_abort <reason> <notify-message> — THE safe-state funnel.
_cal_abort() {
    local _reason="$1" _msg="$2" _rfail=0
    _cal_remove_session
    _cal_restore_state || _rfail=1
    [ "$_rfail" = "1" ] && _msg="$_msg (WARNING: state restore failed — check the limit in the menu)"
    clog "RUN_ABORT reason=$_reason leg=$C_LEG pct=${PCT:-?} run=$C_RUN_ID"
    log "calibration: RUN_ABORT reason=$_reason leg=$C_LEG run=$C_RUN_ID"
    notify_ratelimited "calibration_abort" 0 0 "Battery Commander" "$_msg" || true
    _cal_end_common
}

# _cal_full_watch — two-signal FULL endpoint (design section 5.1),
# shared by L1 and L4. Returns 0 when reached: PCT=100 on
# CAL_FULL_TICKS_NEED consecutive non-gauge ticks AND observed
# charge termination (IsCharging=No on AC, or Amperage collapsed
# to 0). A gauge-suspect tick decides nothing (rule 3): the count
# neither advances nor resets.
_cal_full_watch() {
    if [ "${JUMP_SUSPECT:-0}" = "1" ]; then
        return 1
    fi
    if [ "$PCT" -eq 100 ] 2>/dev/null; then
        C_FULL_TICKS=$(( C_FULL_TICKS + 1 ))
    else
        C_FULL_TICKS=0
    fi
    [ "$C_FULL_TICKS" -ge "$CAL_FULL_TICKS_NEED" ] || return 1
    if [ "$EXT" = "Yes" ] && [ "$ISCHG" = "No" ]; then return 0; fi
    if [ "$EXT" = "Yes" ] && [ "${AMP:-}" = "0" ]; then return 0; fi
    return 1
}

# _cal_apg_thermal — 0 when the current APG pause is a genuine
# thermal gate for calibration purposes: battery temp >= 38 C (the
# APG yellow threshold) or temp unreadable (fail safe). APG_TEMP is
# refreshed by apg_classify earlier in the same tick. A load-only
# pause (temp < 38 C) is NOT thermal (owner's rule, 2026-11-15).
_cal_apg_thermal() {
    local _t="${APG_TEMP:-}" _ti
    case "$_t" in ''|*[!0-9.]*) return 0 ;; esac
    _ti="${_t%.*}"
    case "$_ti" in ''|*[!0-9-]*) return 0 ;; esac
    [ "$_ti" -ge 38 ] 2>/dev/null
}

# _cal_apg_abort_check — in a charge leg, an APG pause lasting
# >= 15 min aborts the run (design rule 4). Returns 0 = abort now.
# Temp gate (2026-11-15): only a THERMAL pause runs the abort
# clock; a load-only pause (temp < 38 C) resets it — CPU load is
# not a thermal emergency and must not kill a user-started run.
_cal_apg_abort_check() {
    if [ -f "$APG_PAUSED" ] && _cal_apg_thermal; then
        [ "$C_APG_SINCE" = "0" ] && C_APG_SINCE="$CAL_NOW"
        if [ $(( CAL_NOW - C_APG_SINCE )) -ge 900 ]; then
            return 0
        fi
    else
        C_APG_SINCE=0
    fi
    return 1
}

# --- L0: preflight -> apply the temp limit, enter L1 ---
_cal_leg_l0() {
    if [ -f "$DISCHARGE_SESSION_REAL" ]; then
        _cal_abort "routine-session" "Calibration aborted: a discharge session is active"
        return 1
    fi
    if [ $(( CAL_NOW - C_LEG_STARTED )) -gt "$CAL_L0_MAX_S" ]; then
        _cal_abort "preflight-timeout" "Calibration aborted: could not start within an hour (needs AC power and a cool, unloaded system)"
        return 1
    fi
    if [ -f "$APG_PAUSED" ] && _cal_apg_thermal; then
        # Temp gate (2026-11-15): a load-only pause (temp < 38 C)
        # does not hold the preflight; AWAIT=apg names the wait.
        _cal_wait "l0-apg" "RUN_WAIT leg=L0 reason=apg run=$C_RUN_ID" "apg"
        return 0
    fi
    if [ "$EXT" != "Yes" ]; then
        _cal_wait "l0-ac" "RUN_WAIT leg=L0 reason=no-ac run=$C_RUN_ID" "ac"
        return 0
    fi
    C_AWAIT=""
    if "$DASH/dispatch.sh" calibration_apply_limit 100 99 >/dev/null 2>&1; then
        C_CONFIG_PHASE="temp"; C_EXPECT_U=100; C_EXPECT_L=99
        C_FULL_TICKS=0
        _cal_set_leg "L1"
        clog "LEG_START leg=L1 run=$C_RUN_ID (temp limit 100/99 applied; base was $C_BASE_UPPER/$C_BASE_LOWER)"
    else
        _cal_abort "apply-failed" "Calibration aborted: could not set the temporary 100% limit"
        return 1
    fi
    return 0
}

# --- L1: charge to verified full ---
_cal_leg_l1() {
    if _cal_apg_abort_check; then
        _cal_abort "apg" "Calibration aborted: battery stayed too hot for 15 minutes during charging"
        return 1
    fi
    if [ $(( CAL_NOW - C_LEG_STARTED )) -gt "$CAL_LEG_BOUND_L1" ]; then
        _cal_abort "leg-timeout" "Calibration aborted: charging to full took over 6 hours"
        return 1
    fi
    if _cal_full_watch; then
        clog "ENDPOINT_FULL leg=L1 pct=$PCT ticks=$C_FULL_TICKS ischg=$ISCHG ext=$EXT amp=${AMP:-?} run=$C_RUN_ID"
        C_FULL_TICKS=0
        C_REST_REMAIN="$CAL_REST_TOP_S"
        _cal_set_leg "L1R"
        clog "LEG_START leg=L1R rest_s=$CAL_REST_TOP_S run=$C_RUN_ID"
    fi
    return 0
}

# --- L1R: rest at full (AC ticks only), then L2 ---
_cal_leg_l1r() {
    if [ "$EXT" = "Yes" ]; then
        C_REST_REMAIN=$(( C_REST_REMAIN - CAL_DELTA ))
        [ "$C_REST_REMAIN" -lt 0 ] && C_REST_REMAIN=0
    fi
    if [ "$C_REST_REMAIN" -le 0 ]; then
        if [ "$PCT" -eq 100 ] 2>/dev/null; then
            C_L2_STARTED="$CAL_NOW"
            C_SEG_STARTED=0; C_WAITING=0; C_CONT_TARGET=""
            _cal_set_leg "L2"
            clog "LEG_START leg=L2 floor=$C_FLOOR abs_floor=$C_ABS_FLOOR run=$C_RUN_ID"
        else
            # Drained during the rest: top up again before the
            # discharge leg (the cycle starts at VERIFIED full).
            C_FULL_TICKS=0
            _cal_set_leg "L1"
            clog "REST_INCOMPLETE pct=$PCT — returning to L1 to re-top before discharge run=$C_RUN_ID"
        fi
    fi
    return 0
}

# --- L2 helpers ---

_cal_l2_track() {
    if ! _cal_session_is_ours; then
        _cal_wait "l2-foreign" "SEGMENT_FOREIGN session present but not this run's — waiting run=$C_RUN_ID" ""
        return 0
    fi
    C_AWAIT=""
    # Two-signal floor record (design section 5.1): the count of
    # consecutive non-gauge ticks at/below FLOOR, and whether the
    # pack voltage confirmed (<= 10.9 V) on any of those ticks.
    local _v=""
    if [ "${JUMP_SUSPECT:-0}" != "1" ]; then
        if [ "$PCT" -le "$C_FLOOR" ] 2>/dev/null; then
            _v=$(_cal_voltage_mv)
            if [ "$C_FLOOR_TICKS" = "0" ]; then
                clog "SEGMENT_NEAR_FLOOR pct=$PCT volt=${_v:-?}mV target=$C_SEG_TARGET run=$C_RUN_ID"
            fi
            C_FLOOR_TICKS=$(( C_FLOOR_TICKS + 1 ))
            if [ -n "$_v" ] && [ "$_v" -le "$CAL_FLOOR_V_MV" ]; then
                if [ "$C_FLOOR_VOLT_OK" = "0" ]; then
                    clog "FLOOR_VOLTAGE_CONFIRMED pct=$PCT volt=${_v}mV run=$C_RUN_ID"
                fi
                C_FLOOR_VOLT_OK=1
            fi
            if [ "$PCT" -le "$C_ABS_FLOOR" ] && [ -n "$_v" ] \
                && [ "$_v" -gt "$CAL_FLOOR_V_MV" ]; then
                C_EMERG_TICKS=$(( C_EMERG_TICKS + 1 ))
            else
                C_EMERG_TICKS=0
            fi
        else
            C_FLOOR_TICKS=0; C_FLOOR_VOLT_OK=0; C_EMERG_TICKS=0
        fi
    fi
    return 0
}

_cal_floor_reached() {
    local _v
    _v=$(_cal_voltage_mv)
    clog "ENDPOINT_FLOOR pct=$PCT ticks=$C_FLOOR_TICKS volt=${_v:-?}mV volt_confirmed=$C_FLOOR_VOLT_OK run=$C_RUN_ID"
    if [ -f "$CAL_POSTURE_STATE" ]; then
        if "$DASH/dispatch.sh" calibration_posture_off >/dev/null 2>&1; then
            clog "POSTURE_RELEASED leg=L3 run=$C_RUN_ID"
        else
            clog "POSTURE_RESTORE_FAILED leg=L3 run=$C_RUN_ID"
        fi
    fi
    C_SEG_STARTED=0
    C_REST_REMAIN="$CAL_REST_LOW_S"
    C_PARK_LAST_ISSUE=0; C_PARK_REISSUES=0
    _cal_set_leg "L3"
    clog "LEG_START leg=L3 rest_s=$CAL_REST_LOW_S — waiting for AC (plug in) run=$C_RUN_ID"
    notify_ratelimited "calibration_floor" 0 0 "Battery Commander" \
        "Calibration: floor reached (${C_FLOOR}%) — plug in the charger now for the low rest" || true
}

_cal_checkpoint() {
    # $1 reason: the run pauses here; only an explicit user resume
    # (with its gates) starts the next segment. Posture is released
    # so the Mac may sleep normally while it waits.
    local _reason="$1"
    C_SEG_STARTED=0
    C_WAITING=1
    if [ -f "$CAL_POSTURE_STATE" ]; then
        if "$DASH/dispatch.sh" calibration_posture_off >/dev/null 2>&1; then
            clog "POSTURE_RELEASED checkpoint=$_reason run=$C_RUN_ID"
        else
            clog "POSTURE_RESTORE_FAILED checkpoint=$_reason run=$C_RUN_ID"
        fi
    fi
    clog "RUN_CHECKPOINT reason=$_reason pct=$PCT run=$C_RUN_ID"
    notify_ratelimited "calibration_checkpoint" 0 0 "Battery Commander" \
        "Calibration paused ($_reason) at ${PCT}% — tap Resume Calibration in the menu when ready" || true
}

_cal_l2_ended() {
    local _out _res _rsn
    _out=$(_cal_segment_outcome)
    _res="${_out%% *}"; _rsn="${_out#* }"
    [ "$_out" = "$_res" ] && _rsn=""
    # Fold the current tick into the floor evidence: the monitor
    # closes the segment on the very tick that completes the
    # two-tick floor count, so that tick's reading belongs to the
    # record before any completion is classified.
    if [ "$_res" = "completed" ] && [ "${JUMP_SUSPECT:-0}" != "1" ] \
        && [ "$PCT" -le "$C_FLOOR" ] 2>/dev/null; then
        local _fv
        _fv=$(_cal_voltage_mv)
        C_FLOOR_TICKS=$(( C_FLOOR_TICKS + 1 ))
        if [ -n "$_fv" ] && [ "$_fv" -le "$CAL_FLOOR_V_MV" ]; then
            C_FLOOR_VOLT_OK=1
        fi
    fi
    case "$_res $_rsn" in
        "completed target-reached"|"completed already-at-target")
            if [ "$C_FLOOR_TICKS" -ge 2 ] && [ "$C_FLOOR_VOLT_OK" = "1" ]; then
                _cal_floor_reached
                return 0
            fi
            if [ "$C_SEG_TARGET" = "$C_ABS_FLOOR" ]; then
                # Already drained to the emergency bound by %: the
                # floor stands only if voltage confirms NOW.
                local _v
                _v=$(_cal_voltage_mv)
                if [ -n "$_v" ] && [ "$_v" -le "$CAL_FLOOR_V_MV" ]; then
                    C_FLOOR_VOLT_OK=1
                    _cal_floor_reached
                    return 0
                fi
                _cal_abort "gauge-voltage-disagreement" "Calibration aborted: the gauge claimed the floor but the pack voltage disagrees — normal limit restored"
                return 1
            fi
            # Gauge claimed the floor; voltage disagrees: continue
            # toward the emergency bound with a fresh segment
            # (design section 5.1 — the leg continues).
            clog "FINDING gauge-floor-unconfirmed pct=$PCT floor_ticks=$C_FLOOR_TICKS volt_ok=$C_FLOOR_VOLT_OK — continuing to abs_floor=$C_ABS_FLOOR run=$C_RUN_ID"
            C_CONT_TARGET="$C_ABS_FLOOR"
            C_SEG_STARTED=0
            ;;
        "aborted ac-flip"|"aborted ac-flip-signature")
            _cal_abort "ac-flip" "Calibration aborted: the AC connection was flipping — normal limit restored"
            return 1
            ;;
        "aborted floor")
            # Monitor floor abort (pct hit ABS_FLOOR with a higher
            # target): the floor stands only with voltage evidence.
            local _v2
            _v2=$(_cal_voltage_mv)
            if [ "$C_FLOOR_VOLT_OK" = "1" ] \
                || { [ -n "$_v2" ] && [ "$_v2" -le "$CAL_FLOOR_V_MV" ]; }; then
                C_FLOOR_VOLT_OK=1
                _cal_floor_reached
                return 0
            fi
            _cal_abort "gauge-voltage-disagreement" "Calibration aborted: the gauge claimed the floor but the pack voltage disagrees — normal limit restored"
            return 1
            ;;
        "aborted apg"|"aborted temp")
            _cal_checkpoint "$_rsn"
            ;;
        "aborted max-age")
            clog "SEGMENT_CONTINUE reason=max-age pct=$PCT run=$C_RUN_ID"
            C_SEG_STARTED=0
            ;;
        "aborted data-unreadable")
            _cal_abort "data-unreadable" "Calibration aborted: battery data unreadable — normal limit restored"
            return 1
            ;;
        "refused "*)
            _cal_abort "segment-refused-$_rsn" "Calibration aborted: a discharge segment was refused ($_rsn) — normal limit restored"
            return 1
            ;;
        "ended superseded")
            C_CONFIG_PHASE="user"
            _cal_abort "superseded" "Calibration ended: you changed the charge limit — your new limit stays"
            return 1
            ;;
        "incomplete park-timeout")
            clog "SEGMENT_PARK_TIMEOUT pct=$PCT — will re-issue when unplugged run=$C_RUN_ID"
            C_SEG_STARTED=0
            C_AWAIT="unplug"
            ;;
        "ended-by-sleep sleep")
            _cal_checkpoint "sleep"
            ;;
        "cancelled cancelled")
            _cal_checkpoint "session-ended"
            ;;
        "")
            # No EPISODE line: the file vanished without the
            # monitor closing it (killed session, manual removal).
            clog "SEGMENT_VANISHED session=$C_SEG_STARTED pct=$PCT run=$C_RUN_ID"
            _cal_checkpoint "vanished"
            ;;
        *)
            _cal_abort "segment-$_res-$_rsn" "Calibration aborted: discharge segment ended unexpectedly ($_res/$_rsn) — normal limit restored"
            return 1
            ;;
    esac
    return 0
}

_cal_l2_issue() {
    if [ -f "$APG_PAUSED" ] && _cal_apg_thermal; then
        # Temp gate (2026-11-15): a load-only pause (temp < 38 C)
        # does not hold the issue; AWAIT=apg names the wait.
        _cal_wait "l2-apg" "RUN_WAIT leg=L2 reason=apg run=$C_RUN_ID" "apg"
        return 0
    fi
    if [ "$EXT" = "Yes" ]; then
        _cal_wait "l2-ac" "RUN_WAIT leg=L2 reason=on-ac (unplug to drain) run=$C_RUN_ID" "unplug"
        return 0
    fi
    C_AWAIT=""
    if [ ! -f "$CAL_POSTURE_STATE" ]; then
        if "$DASH/dispatch.sh" calibration_posture_on >/dev/null 2>&1; then
            clog "POSTURE_ASSERTED leg=L2 run=$C_RUN_ID"
        else
            _cal_abort "posture-failed" "Calibration aborted: could not set the anti-sleep posture for the discharge leg"
            return 1
        fi
    fi
    local _target="$C_FLOOR"
    if [ -n "$C_CONT_TARGET" ]; then
        _target="$C_CONT_TARGET"
        C_CONT_TARGET=""
    fi
    local _tmp="$DASH/.discharge_session.cal.tmp"
    {
        printf 'MODE=calibrate\n'
        printf 'TARGET=%s\n' "$_target"
        printf 'STARTED=%s\n' "$CAL_NOW"
        printf 'RUN=%s\n' "$C_RUN_ID"
        printf 'STARTER=supervisor\n'
    } > "$_tmp" && mv "$_tmp" "$DISCHARGE_SESSION_REAL"
    C_SEG_STARTED="$CAL_NOW"
    C_SEG_TARGET="$_target"
    C_SEGMENTS=$(( C_SEGMENTS + 1 ))
    C_SEG_LOG_LINE=$(wc -l < "$DISCHARGE_LOG" 2>/dev/null | tr -d ' ')
    case "$C_SEG_LOG_LINE" in ''|*[!0-9]*) C_SEG_LOG_LINE=0 ;; esac
    C_FLOOR_TICKS=0; C_FLOOR_VOLT_OK=0; C_EMERG_TICKS=0
    C_WAIT_KEY=""
    clog "SEGMENT_START n=$C_SEGMENTS target=$_target pct=$PCT run=$C_RUN_ID"
    return 0
}

_cal_l2_resume() {
    # A wake reading at or below the floor fails the run (design
    # section 5.4): the pack sat at/below the floor unsupervised.
    if [ "$PCT" -le "$C_FLOOR" ] 2>/dev/null; then
        _cal_abort "woke-at-floor" "Calibration failed: the battery woke at or below the floor (${C_FLOOR}%) — normal limit restored; plug in"
        return 1
    fi
    if [ ! -f "$CAL_RESUME_FILE" ]; then
        _cal_wait "l2-resume-tap" "RUN_WAIT leg=L2 reason=resume-tap run=$C_RUN_ID" "resume"
        return 0
    fi
    C_AWAIT=""
    local _mt _age
    _mt=$(stat -f %m "$CAL_RESUME_FILE" 2>/dev/null || echo 0)
    case "$_mt" in ''|*[!0-9]*) _mt=0 ;; esac
    _age=$(( CAL_NOW - _mt ))
    if [ "$_age" -gt 600 ]; then
        rm -f "$CAL_RESUME_FILE"
        clog "RESUME_MARKER_STALE age=${_age}s — tap Resume again run=$C_RUN_ID"
        return 0
    fi
    local _lw=0 _wa=999999
    if [ -f "$DASH/.last_wake" ]; then
        _lw=$(cat "$DASH/.last_wake" 2>/dev/null || echo 0)
        case "$_lw" in ''|*[!0-9]*) _lw=0 ;; esac
        [ "$_lw" -gt 0 ] && _wa=$(( CAL_NOW - _lw ))
    fi
    if [ "$_wa" -lt 120 ]; then
        _cal_wait "l2-resume-wake" "RESUME_WAIT wake_age=${_wa}s (<120) run=$C_RUN_ID" "resume"
        return 0
    fi
    if [ -f "$APG_PAUSED" ] && _cal_apg_thermal; then
        # Temp gate (2026-11-15): the design's "APG clear" resume
        # gate is reinterpreted under the owner's rule — a load-only
        # pause (temp < 38 C) does not block the resume of a
        # user-started run. The other gates (120 s post-wake,
        # pct >= floor+15, fresh user tap) are unchanged.
        _cal_wait "l2-resume-apg" "RESUME_WAIT reason=apg run=$C_RUN_ID" "resume"
        return 0
    fi
    if [ "$PCT" -lt $(( C_FLOOR + 15 )) ] 2>/dev/null; then
        _cal_wait "l2-resume-pct" "RESUME_REFUSED pct=$PCT below floor+15 (needs >= $(( C_FLOOR + 15 ))) run=$C_RUN_ID" "resume"
        return 0
    fi
    rm -f "$CAL_RESUME_FILE"
    C_WAITING=0
    C_WAIT_KEY=""
    clog "RUN_RESUMED pct=$PCT wake_age=${_wa}s run=$C_RUN_ID"
    _cal_l2_issue
    return $?
}

_cal_leg_l2() {
    if [ $(( CAL_NOW - C_L2_STARTED )) -gt "$CAL_LEG_BOUND_L2" ]; then
        _cal_abort "leg-timeout" "Calibration aborted: the discharge leg exceeded 24 hours — normal limit restored"
        return 1
    fi
    if [ -f "$DISCHARGE_SESSION_REAL" ]; then
        _cal_l2_track
        return 0
    fi
    if [ "$C_SEG_STARTED" != "0" ]; then
        _cal_l2_ended
        return $?
    fi
    if [ "$C_WAITING" = "1" ]; then
        _cal_l2_resume
        return $?
    fi
    _cal_l2_issue
    return $?
}

# --- L3: low rest — park on AC at the floor ---
_cal_l3_issue_park() {
    local _tmp="$DASH/.discharge_session.cal.tmp"
    {
        printf 'MODE=calibrate\n'
        printf 'TARGET=%s\n' "$C_FLOOR"
        printf 'PARK=1\n'
        printf 'STARTED=%s\n' "$CAL_NOW"
        printf 'RUN=%s\n' "$C_RUN_ID"
        printf 'STARTER=supervisor\n'
    } > "$_tmp" && mv "$_tmp" "$DISCHARGE_SESSION_REAL"
    C_SEG_STARTED="$CAL_NOW"
    C_SEG_TARGET="$C_FLOOR"
    C_SEG_LOG_LINE=$(wc -l < "$DISCHARGE_LOG" 2>/dev/null | tr -d ' ')
    case "$C_SEG_LOG_LINE" in ''|*[!0-9]*) C_SEG_LOG_LINE=0 ;; esac
    C_PARK_LAST_ISSUE="$CAL_NOW"
    C_PARK_REISSUES=$(( C_PARK_REISSUES + 1 ))
    C_WAIT_KEY=""
    clog "PARK_START target=$C_FLOOR pct=$PCT run=$C_RUN_ID"
}

_cal_leg_l3() {
    if [ $(( CAL_NOW - C_LEG_STARTED )) -gt "$CAL_LEG_BOUND_L3" ]; then
        _cal_abort "leg-timeout" "Calibration aborted: the low rest exceeded 2 hours — normal limit restored"
        return 1
    fi
    if [ -f "$DISCHARGE_SESSION_REAL" ]; then
        if _cal_session_is_ours && [ "$EXT" = "Yes" ]; then
            C_AWAIT=""
            C_REST_REMAIN=$(( C_REST_REMAIN - CAL_DELTA ))
            [ "$C_REST_REMAIN" -lt 0 ] && C_REST_REMAIN=0
            if [ "$C_REST_REMAIN" -le 0 ]; then
                _cal_remove_session
                C_SEG_STARTED=0
                C_FULL_TICKS=0
                _cal_set_leg "L4"
                clog "LEG_START leg=L4 (recharge to full; may cross sleep) run=$C_RUN_ID"
                notify_ratelimited "calibration_recharge" 0 0 "Battery Commander" \
                    "Calibration: low rest done — final recharge to 100% started (lid may close)" || true
            fi
        fi
        return 0
    fi
    if [ "$C_SEG_STARTED" != "0" ]; then
        # The park session ended early: dangerous reasons abort the
        # run; anything else just re-parks when AC is present.
        local _out _res _rsn
        _out=$(_cal_segment_outcome)
        _res="${_out%% *}"; _rsn="${_out#* }"
        case "$_res $_rsn" in
            "aborted temp"|"aborted data-unreadable"|"aborted ac-flip"|"aborted ac-flip-signature")
                _cal_abort "park-$_rsn" "Calibration aborted during the low rest ($_rsn) — normal limit restored"
                return 1
                ;;
            "ended superseded")
                C_CONFIG_PHASE="user"
                _cal_abort "superseded" "Calibration ended: you changed the charge limit — your new limit stays"
                return 1
                ;;
            *)
                clog "PARK_ENDED result=${_res:-none} reason=${_rsn:-none} — will re-park run=$C_RUN_ID"
                C_SEG_STARTED=0
                ;;
        esac
        return 0
    fi
    if [ "$EXT" != "Yes" ]; then
        _cal_wait "l3-ac" "RUN_WAIT leg=L3 reason=no-ac (plug in) run=$C_RUN_ID" "ac"
        if [ "$PCT" -le "$C_ABS_FLOOR" ] 2>/dev/null \
            && [ "$C_NOTIFY_KEY" != "l3-urgent" ]; then
            C_NOTIFY_KEY="l3-urgent"
            notify_ratelimited "calibration_urgent" 0 0 "Battery Commander" \
                "Calibration: battery is AT the floor (${PCT}%) and unplugged — plug in the charger now" || true
        fi
        return 0
    fi
    C_AWAIT=""
    _cal_l3_issue_park
    return 0
}

# --- L4: recharge to verified full (the one leg allowed across sleep) ---
_cal_leg_l4() {
    # Completion is checked BEFORE the bound (design rule 8): a
    # run that finished charging during a long sleep closes out.
    if _cal_full_watch; then
        clog "ENDPOINT_FULL leg=L4 pct=$PCT ticks=$C_FULL_TICKS ischg=$ISCHG ext=$EXT amp=${AMP:-?} run=$C_RUN_ID"
        C_FULL_TICKS=0
        C_REST_REMAIN="$CAL_REST_OUT_S"
        _cal_set_leg "L5"
        clog "LEG_START leg=L5 rest_s=$CAL_REST_OUT_S run=$C_RUN_ID"
        return 0
    fi
    if _cal_apg_abort_check; then
        _cal_abort "apg" "Calibration aborted: battery stayed too hot for 15 minutes during the recharge"
        return 1
    fi
    if [ $(( CAL_NOW - C_LEG_STARTED )) -gt "$CAL_LEG_BOUND_L4" ]; then
        _cal_abort "leg-timeout" "Calibration aborted: the recharge took over 8 hours — normal limit restored"
        return 1
    fi
    return 0
}

# --- L5: close-out rest, restore, report ---
_cal_write_report() {
    mkdir -p "$CAL_REPORTS_DIR" 2>/dev/null || return 1
    local _dump _fcc="" _des="" _cyc=""
    _dump=$(ioreg -rn AppleSmartBattery 2>/dev/null)
    _fcc=$(printf '%s' "$_dump" | grep -oE '"MaxCapacity" = [0-9]+' | head -1 | grep -oE '[0-9]+$')
    _des=$(printf '%s' "$_dump" | grep -oE '"DesignCapacity" = [0-9]+' | head -1 | grep -oE '[0-9]+$')
    _cyc=$(printf '%s' "$_dump" | grep -oE '"CycleCount" = [0-9]+' | head -1 | grep -oE '[0-9]+$')
    CAL_NEW_HEALTH_X10="?"
    if [ -n "$_fcc" ] && [ -n "$_des" ] && [ "$_des" -gt 0 ] 2>/dev/null; then
        CAL_NEW_HEALTH_X10=$(( _fcc * 1000 / _des ))
    fi
    local _rep="$CAL_REPORTS_DIR/calibration-$C_RUN_ID.md"
    local _h0="?"
    case "$C_HEALTH_X10" in ''|*[!0-9]*) ;; *)
        _h0="$(( C_HEALTH_X10 / 10 )).$(( C_HEALTH_X10 % 10 ))%" ;; esac
    {
        printf '# Calibration run %s\n\n' "$C_RUN_ID"
        printf -- '- Profile: %s — floor %s%%, emergency abort %s%%, supervision line %s%%\n' \
            "$C_PROFILE" "$C_FLOOR" "$C_ABS_FLOOR" "$C_SUPERVISION"
        printf -- '- Battery at start: health %s (x10=%s), full-charge %s mAh, %s cycles\n' \
            "$_h0" "$C_HEALTH_X10" "$C_BASE_MAXCAP" "$C_CYCLES"
        printf -- '- Battery at end: health x10=%s, full-charge %s mAh, %s cycles\n' \
            "$CAL_NEW_HEALTH_X10" "${_fcc:-?}" "${_cyc:-?}"
        printf -- '- Segments used: %s\n' "$C_SEGMENTS"
        printf -- '- Full detail: calibration.log (endpoints logged with both signals)\n'
    } > "$_rep.tmp" && mv "$_rep.tmp" "$_rep"
    clog "RUN_REPORT path=$_rep health_x10 $C_HEALTH_X10 -> $CAL_NEW_HEALTH_X10"
}

_cal_leg_l5() {
    if [ "$EXT" = "Yes" ]; then
        C_REST_REMAIN=$(( C_REST_REMAIN - CAL_DELTA ))
        [ "$C_REST_REMAIN" -lt 0 ] && C_REST_REMAIN=0
    fi
    [ "$C_REST_REMAIN" -gt 0 ] && return 0
    _cal_write_report
    local _rfail=0
    _cal_restore_state || _rfail=1
    clog "RUN_COMPLETE run=$C_RUN_ID health_x10 $C_HEALTH_X10 -> $CAL_NEW_HEALTH_X10 segments=$C_SEGMENTS"
    log "calibration: RUN_COMPLETE run=$C_RUN_ID"
    if [ "$_rfail" = "1" ]; then
        notify_ratelimited "calibration_complete" 0 0 "Battery Commander" \
            "Calibration complete — but the state restore reported a failure; check the limit in the menu" || true
    else
        notify_ratelimited "calibration_complete" 0 0 "Battery Commander" \
            "Calibration complete — gauge re-anchored at both ends; your normal limit is restored" || true
    fi
    _cal_end_common
    return 1
}

# _cal_supervisor_impl — one supervisor tick.
_cal_supervisor_impl() {
    [ -f "$CAL_RUN_FILE" ] || { rm -f "$CAL_FAILS_FILE" 2>/dev/null; return 0; }
    CAL_NOW=$(_disch_now)

    # Snapshot-unreadable path (design rule 11): count failures
    # against the run; the 2nd consecutive one aborts it to the
    # safe state (every restore step is a file/dispatch operation
    # that needs no battery data).
    if [ "${CALIBRATION_SNAPSHOT_FAIL:-0}" = "1" ]; then
        _cal_load_run || return 0
        local _f=0
        [ -f "$CAL_FAILS_FILE" ] && _f=$(cat "$CAL_FAILS_FILE" 2>/dev/null || echo 0)
        _f=$(_cal_num "$_f")
        _f=$(( _f + 1 ))
        echo "$_f" > "$CAL_FAILS_FILE" 2>/dev/null
        clog "RUN_DATA_UNREADABLE count=$_f leg=$C_LEG run=$C_RUN_ID"
        if [ "$_f" -ge 2 ]; then
            _cal_abort "data-unreadable" "Calibration aborted: battery data unreadable — normal limit restored"
        fi
        return 0
    fi
    rm -f "$CAL_FAILS_FILE" 2>/dev/null

    if ! _cal_load_run; then
        # Corrupt run file = no run (design rule 11): delete and
        # log loudly. The config is NOT touched (the pre-run base
        # is unknowable from a corrupt file; worst case the temp
        # 100/99 remains — safe and visible) and any calibrate
        # session is removed so no cross-check can pass against a
        # ghost run.
        clog "RUN_CORRUPT run file deleted (treated as no run)"
        log "calibration: corrupt run file deleted"
        if [ -f "$DISCHARGE_SESSION_REAL" ] \
            && grep -q '^MODE=calibrate' "$DISCHARGE_SESSION_REAL" 2>/dev/null; then
            rm -f "$DISCHARGE_SESSION_REAL"
        fi
        if [ -f "$CAL_POSTURE_STATE" ]; then
            "$DASH/dispatch.sh" calibration_posture_off >/dev/null 2>&1 || true
        fi
        printf 'hold\n' > "$DASH/.active_mode.cal.tmp" 2>/dev/null \
            && mv "$DASH/.active_mode.cal.tmp" "$DASH/.active_mode" 2>/dev/null
        rm -f "$CAL_RUN_FILE" "$CAL_RESUME_FILE" "$CAL_CANCEL_FILE" 2>/dev/null
        return 0
    fi

    # Tick delta for the rest timers (sleep counts as rest at the
    # endpoints; legs that must not cross sleep never get here
    # with a live segment — theirs died at WillSleep).
    CAL_DELTA=$(( CAL_NOW - C_HEARTBEAT ))
    [ "$CAL_DELTA" -lt 0 ] && CAL_DELTA=0
    [ "$CAL_DELTA" -gt 86400 ] && CAL_DELTA=86400

    # Heartbeat before anything else: bc-limit and the monitor
    # authorize calibrate sessions against its freshness.
    C_HEARTBEAT="$CAL_NOW"
    _cal_save_run

    if [ -f "$CAL_CANCEL_FILE" ]; then
        rm -f "$CAL_CANCEL_FILE"
        _cal_abort "user-cancel" "Calibration cancelled — normal limit restored"
        return 0
    fi
    if [ $(( CAL_NOW - C_STARTED )) -gt "$CAL_RUN_MAX_S" ]; then
        _cal_abort "run-timeout" "Calibration aborted: exceeded the 72-hour run bound — normal limit restored"
        return 0
    fi
    # Rule 14 (config integrity): the live config must equal what
    # the current phase expects. A deliberate user change ends the
    # run and the user's value survives.
    local _cu _cl
    _cu=$(grep '^LAST_UPPER=' "$CFG" 2>/dev/null | cut -d= -f2)
    _cl=$(grep '^LAST_LOWER=' "$CFG" 2>/dev/null | cut -d= -f2)
    if [ "$_cu" != "$C_EXPECT_U" ] || [ "$_cl" != "$C_EXPECT_L" ]; then
        clog "RUN_SUPERSEDED config=${_cu:-?}/${_cl:-?} expected=$C_EXPECT_U/$C_EXPECT_L run=$C_RUN_ID"
        C_CONFIG_PHASE="user"
        _cal_abort "superseded" "Calibration ended: you changed the charge limit — your new limit stays"
        return 0
    fi

    local _ended=0
    case "$C_LEG" in
        L0)  _cal_leg_l0  || _ended=1 ;;
        L1)  _cal_leg_l1  || _ended=1 ;;
        L1R) _cal_leg_l1r || _ended=1 ;;
        L2)  _cal_leg_l2  || _ended=1 ;;
        L3)  _cal_leg_l3  || _ended=1 ;;
        L4)  _cal_leg_l4  || _ended=1 ;;
        L5)  _cal_leg_l5  || _ended=1 ;;
    esac
    [ "$_ended" = "1" ] && return 0
    [ -f "$CAL_RUN_FILE" ] && _cal_save_run
    return 0
}

section_calibration_supervisor() {
    _cal_supervisor_impl 2>/dev/null || true
    return 0
}
# === Main (one tick) ===
_REAPPLIED_THIS_TICK=0
MODE="idle"
BCLM=""
BCLM_UNREADABLE=0
BACKEND="unknown"
APG="unknown"

# Read the state once (ioreg). If the snapshot is unreadable, exit quietly
# (the next tick retries) — never act on stale or missing readings.
if ! read_snapshot; then
    log "snapshot unreadable (ioreg) — skipping tick"
    # The discharge monitor still needs the tick: it counts unreadable
    # ticks against any supervised session and aborts on the 2nd (D2).
    DISCHARGE_SNAPSHOT_FAIL=1
    section_discharge_monitor
    # The calibration supervisor likewise counts unreadable ticks
    # against a live run and aborts it on the 2nd (rule 11).
    CALIBRATION_SNAPSHOT_FAIL=1
    section_calibration_supervisor
    exit 0
fi
BCLM=$(bc_read_bclm) || BCLM=""
BACKEND=$(_bc_backend)
MODE=$(read_effective_session 2>/dev/null || echo "idle")

# Gauge-jump detection (audit 2026-11-11, W1): the % is an estimate and
# can jump when the battery rests or charging resumes (86% -> 93.5%
# observed 2026-11-11). A >= 5% move in one 60 s tick is not physical
# charging/discharging — flag it so the ladder defers one tick instead
# of escalating on a gauge artifact. Never suppresses the hold reapply.
JUMP_SUSPECT=0
PREV_PCT_VAL=""
_prev_entry=""
[ -f "$PREV_PCT" ] && _prev_entry=$(cat "$PREV_PCT" 2>/dev/null || echo "")
_prev_ts=${_prev_entry%%|*}
PREV_PCT_VAL=${_prev_entry##*|}
case "$_prev_ts" in ''|*[!0-9]*) _prev_ts=0 ;; esac
case "$PREV_PCT_VAL" in ''|*[!0-9]*) PREV_PCT_VAL="" ;; esac
if [ -n "$PREV_PCT_VAL" ] && [ $(( $(date +%s) - _prev_ts )) -le 120 ]; then
    _pct_delta=$(( PCT - PREV_PCT_VAL ))
    [ "$_pct_delta" -lt 0 ] && _pct_delta=$(( -_pct_delta ))
    if [ "$_pct_delta" -ge 5 ]; then
        JUMP_SUSPECT=1
        log "gauge jump suspected: ${PREV_PCT_VAL}% -> ${PCT}% in one tick (gauge artifact, not a real change)"
    fi
fi
atomic_write "$PREV_PCT" "$(date +%s)|${PCT}
"

# Previous-tick CurrentCapacity + PCT (C2 confirmation input): same
# "ts|CUR|PCT" freshness discipline as PREV_PCT (120 s window). Read the
# PREV_CUR file BEFORE overwriting it with this tick's values.
PREV_CUR_VAL=""
PREV_TICK_PCT=""
_prev_cur_entry=""
[ -f "$PREV_CUR" ] && _prev_cur_entry=$(cat "$PREV_CUR" 2>/dev/null || echo "")
_prev_cur_ts=${_prev_cur_entry%%|*}
_prev_cur_rest=${_prev_cur_entry#*|}
PREV_CUR_VAL=${_prev_cur_rest%%|*}
PREV_TICK_PCT=${_prev_cur_rest##*|}
case "$_prev_cur_ts" in ''|*[!0-9]*) _prev_cur_ts=0 ;; esac
case "$PREV_CUR_VAL" in ''|*[!0-9]*) PREV_CUR_VAL="" ;; esac
case "$PREV_TICK_PCT" in ''|*[!0-9]*) PREV_TICK_PCT="" ;; esac
if [ -z "$PREV_CUR_VAL" ] || [ $(( $(date +%s) - _prev_cur_ts )) -gt 120 ]; then
    PREV_CUR_VAL=""
    PREV_TICK_PCT=""
fi
atomic_write "$PREV_CUR" "$(date +%s)|${CUR}|${PCT}
"

# BCLM unreadable: the limit sections are blind. Log it at most once per
# hour (the drift section skips; the ladder's reapply refuses on its own).
if [ -z "$BCLM" ]; then
    _bclm_last=0
    [ -f "$DASH/.bclm_unreadable_last" ] && _bclm_last=$(cat "$DASH/.bclm_unreadable_last" 2>/dev/null || echo 0)
    case "$_bclm_last" in ''|*[!0-9]*) _bclm_last=0 ;; esac
    if [ $(( $(date +%s) - _bclm_last )) -ge 3600 ]; then
        log "BCLM unreadable (bc-candidates) — limit sections skipped this tick"
        echo "$(date +%s)" > "$DASH/.bclm_unreadable_last"
    fi
    BCLM_UNREADABLE=1
else
    rm -f "$DASH/.bclm_unreadable_last" 2>/dev/null || true
    BCLM_UNREADABLE=0
fi

# APG classification (fresh; maintains .apg_paused).
apg_classify

# Guardian sections (order matches guardian.sh: L1, L2, L2b, L3, L4, L4b).
section_l1_stale_session
section_l2_overshoot
# Discharge session monitor (D2) — after the overshoot section.
section_discharge_monitor
# Calibration run supervisor (calibrate build 2026-11-14) — right
# after the monitor: it consumes the monitor's segment outcomes.
section_calibration_supervisor
section_l2b_discharge_complete
section_l3_drift
section_l4_orphan
section_l4b_phantom
# L8 daemon check.
section_l8_daemon_check
# Enforce ladder.
section_ladder
# charge_target cleanup.
section_charge_target
# Consolidated children (time-gated).
section_consolidated
# Stay Awake (On Battery) guard (final cleanup 2026-11-18):
# auto-revert at <=20%, supersede stand-down, drift re-assert.
section_stay_awake_batt

# Heartbeat + log trim (.watchdog.log at 100 KB, keep the last 200 lines
# — guardian's pattern).
heartbeat
echo "$(date +%s)" > "$ENFORCE_HB"
if [ -f "$WLOG" ]; then
    _wsize=$(wc -c < "$WLOG" | tr -d ' ')
    [ "${_wsize:-0}" -gt 102400 ] && tail -200 "$WLOG" > "$WLOG.tmp" && mv "$WLOG.tmp" "$WLOG"
fi

# Verification episode tracker (design §9 step 1; verification
# deployment 2026-11-14): the tracker consumes this tick's heartbeat
# from .watchdog.log and maintains .episode_open + the episode store
# under verification/. Strictly observe-and-score: it is additive,
# guarded on the driver being installed, and wrapped so it can NEVER
# fail or delay the tick — the enforcer path above is untouched.
if [ -x "$DASH/bc-tracker-live.sh" ]; then
    "$DASH/bc-tracker-live.sh" >/dev/null 2>&1 || true
fi

exit 0


