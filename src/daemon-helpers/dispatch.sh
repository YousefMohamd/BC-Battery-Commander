#!/bin/bash

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
# The state dir must exist for the lock + log files below; without it
# acquire() would spin forever (lock create fails, no live owner, retry).
mkdir -p "$DASH" 2>/dev/null || true
# Battery Commander (BC) — the independent backend. The closed-source
# battopt binary is GONE. The enforcer + read-only status binaries live in
# installed runtime locations (state dir / privileged helpers).
# BC_BUILD_DIR can be overridden in the environment.
BC_BUILD_DIR="${BC_BUILD_DIR:-}"
# Runtime probes resolve to installed locations, never the build tree
# (root-cause fix 2026-11-19: build-tree paths broke every status read
# once the project moved -- "status unavailable"). bc-status lives in
# the state dir; the daemon binary in the privileged helpers dir (DMG
# installs) or the state dir's bin/ (pre-DMG layout).
BC_STATUS="$DASH/bc-status"
BC_LIMIT="/Library/PrivilegedHelperTools/bc-limit"
[ -x "$BC_LIMIT" ] || BC_LIMIT="$DASH/bin/bc-limit"
BC_CANDIDATES="$BC_BUILD_DIR/bc-candidates"
LOG="$DASH/actions.log"
LOCK="$DASH/.op.lock"
CFG="$DASH/config"
# NOTE: FORCE (force_reset.sh) is gone — the battopt-form reset is dropped
# (W1.10). A BC recovery is not designed in W1; force_reset is a stub.

LOCK_TIMEOUT="${LOCK_TIMEOUT:-600}"
LOCK_OWNED=0
LOCK_OWNER_PID=""
LOCK_WATCHDOG_PID=""

case "$LOCK_TIMEOUT" in
    ''|*[!0-9]*) LOCK_TIMEOUT=600 ;;
esac

# Shared session guard (state_guard.sh provides guard_session_active, etc.)
if [ -f "$DASH/state_guard.sh" ]; then
    source "$DASH/state_guard.sh"
fi

# read_config — (re-)parse the canonical config as KEY=value into the
# globals. Never `source` a data file (code execution from a data file).
read_config() {
    local _cfg_key _cfg_val
    if [ -f "$CFG" ]; then
        while IFS='=' read -r _cfg_key _cfg_val; do
            case "$_cfg_key" in
                LAST_UPPER) LAST_UPPER="$_cfg_val" ;;
                LAST_LOWER) LAST_LOWER="$_cfg_val" ;;
                SAILING) SAILING="$_cfg_val" ;;
                SAIL_GAP) SAIL_GAP="$_cfg_val" ;;
            esac
        done < "$CFG"
    fi
    # A corrupt config must never flow into a limit write: same numeric
    # guards as the plugin's _bc_parse_config (canonical 86/85).
    case "$LAST_UPPER" in ''|*[!0-9]*) LAST_UPPER=86 ;; esac
    case "$LAST_LOWER" in ''|*[!0-9]*) LAST_LOWER=85 ;; esac
    case "$SAILING" in true|false) ;; *) SAILING=false ;; esac
    case "$SAIL_GAP" in ''|*[!0-9]*) SAIL_GAP=1 ;; esac
    # Range guards (M7/m9 parity, consolidation 2026-11-13): upper 15-100,
    # lower 15-99, upper > lower, gap 1-30. An out-of-range value must
    # never flow into a limit write; fall back to the canonical pair.
    if [ "$LAST_UPPER" -lt 15 ] || [ "$LAST_UPPER" -gt 100 ]; then LAST_UPPER=86; fi
    if [ "$LAST_LOWER" -lt 15 ] || [ "$LAST_LOWER" -gt 99 ]; then LAST_LOWER=85; fi
    if [ "$LAST_LOWER" -ge "$LAST_UPPER" ]; then LAST_UPPER=86; LAST_LOWER=85; fi
    if [ "$SAIL_GAP" -lt 1 ] || [ "$SAIL_GAP" -gt 30 ]; then SAIL_GAP=1; fi
}

# Defaults — used ONLY when no config file exists. They match the live
# config (86/85, SAILING=false, SAIL_GAP=1); see design §3.5.
LAST_UPPER=86
LAST_LOWER=85
SAILING=false
SAIL_GAP=1
read_config

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
    # Rotate actions.log at 100 KB, keep the last 500 lines (the
    # cleanup_logs.sh pattern). Best-effort: two concurrent dispatches can
    # race the rotate and lose a few log lines; that is benign for a log.
    local _log_size
    _log_size=$(stat -f %z "$LOG" 2>/dev/null || echo 0)
    if [ "${_log_size:-0}" -gt 102400 ]; then
        tail -500 "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv "$LOG.tmp.$$" "$LOG" 2>/dev/null || rm -f "$LOG.tmp.$$" 2>/dev/null
    fi
}
# get_pct — battery % from ioreg (CurrentCapacity*100/MaxCapacity).
# The only % source dispatch needs; it never calls battopt, never sudo's.
get_pct() {
    local _snap _cur _max
    _snap=$(ioreg -rn AppleSmartBattery 2>/dev/null) || return 1
    _cur=$(printf '%s\n' "$_snap" | grep -E '"CurrentCapacity" = [0-9]+' | grep -oE '[0-9]+' | head -1)
    _max=$(printf '%s\n' "$_snap" | grep -E '"MaxCapacity" = [0-9]+' | grep -oE '[0-9]+' | head -1)
    [ -n "$_cur" ] && [ -n "$_max" ] && [ "$_max" -gt 0 ] || return 1
    echo $(( _cur * 100 / _max ))
}

# === BATTERY COMMANDER (BC) BACKEND PRIMITIVE (W1.1) ===
# The single helper every limit intent uses. It writes the canonical config
# (atomically) AFTER verification, then signals the enforcer (bc-limit, run
# as root by the LaunchDaemon every 60 s) by the config write itself.
# Dispatch NEVER writes BCLM, NEVER calls `bc-limit --write`, NEVER calls
# battopt, and NEVER runs sudo for charge control. The limit % lives in the
# config, never in the SMC.
#
# Read-only status sources (no sudo, no battopt):
#   %      — ioreg (CurrentCapacity*100/MaxCapacity), see get_pct().
#   BCLM   — bc-candidates (read-only SMC reader), see bc_read_bclm().
#   health/cycle/temp — bc-status (Key: value), see bc_status_value().
#   limits — the canonical config (KEY=value), never BCLM.

# bc_read_bclm — print the BCLM value (10 = hold, 100 = charging allowed),
# or nothing if it cannot be read. Read-only; never writes.
# bc-candidates prints one line per key: "BCLM: size=1 type=ui8 bytes=0a value=10".
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
    _v=$(bc_status_value BCLM 2>/dev/null) || _v=""
    [ -n "$_v" ] && printf '%s' "$_v" && return 0
    return 1
}

# bc_status_value <Key> — print the value for Key from bc-status output
# (format is "Key: value" with units, e.g. "Capacity: 85.9%").
# Returns 1 if bc-status is missing or the key is absent.
bc_status_value() {
    local _key="$1" _out _line
    [ -x "$BC_STATUS" ] || return 1
    _out=$("$BC_STATUS" 2>/dev/null) || return 1
    _line=$(printf '%s\n' "$_out" | grep "^${_key}:" | head -1) || return 1
    [ -n "$_line" ] || return 1
    printf '%s' "${_line#*: }" | tr -d '[:space:]'
}

# _bc_backend — the selected enforcement backend (cached; it does not
# change per run). From `bc-limit --probe` (read-only). "unknown" if the
# probe cannot run (the enforcer is not installed/loaded until Phase C).
_bc_backend() {
    [ -n "${_BC_BACKEND:-}" ] && { printf '%s' "$_BC_BACKEND"; return 0; }
    if [ -x "$BC_LIMIT" ]; then
        _BC_BACKEND=$("$BC_LIMIT" --probe 2>/dev/null | grep -oE 'backend=[a-z0-9]+' | head -1 | cut -d= -f2)
    fi
    [ -n "${_BC_BACKEND:-}" ] || _BC_BACKEND="unknown"
    printf '%s' "$_BC_BACKEND"
}

# bc_status_snapshot — one multi-line BC status block for dialogs/reports:
# bc-status fields + BCLM + backend + configured limits. Read-only.
bc_status_snapshot() {
    local _s _bclm _be
    if [ -x "$BC_STATUS" ]; then
        _s=$("$BC_STATUS" 2>/dev/null | grep -v "READ-ONLY DONE" || true)
    fi
    _bclm=$(bc_read_bclm) || _bclm="?"
    _be=$(_bc_backend)
    printf '%s\nBCLM: %s\nBackend: %s\nLimit: %s/%s\n' "${_s:-bc-status unavailable}" "$_bclm" "$_be" "$LAST_UPPER" "$LAST_LOWER"
}

# _bc_verify <UPPER> <LOWER> — one helper replacing the ~6 duplicated
# verify-retry blocks. Verifies the BC backend state after a config write:
#   (1) the canonical config file reads back the requested limits (the
#       limit % lives in the config, never in the SMC — there is no SMC
#       value to read back, so the config read-back IS the verification);
#   (2) BCLM + % are readable (the SMC path the enforcer needs is alive).
# Returns 0 if both hold, 1 otherwise. Single retry (sleep 2, retry once)
# for transient read failures — the same retry shape the old code used,
# but against BC state, not battopt text.
_bc_verify() {
    local _u="$1" _l="$2" _try _cu _cl _pct _bclm
    for _try in 1 2; do
        _cu=""; _cl=""; _pct=""; _bclm=""
        if [ -f "$CFG" ]; then
            _cu=$(grep '^LAST_UPPER=' "$CFG" 2>/dev/null | cut -d= -f2-)
            _cl=$(grep '^LAST_LOWER=' "$CFG" 2>/dev/null | cut -d= -f2-)
        fi
        _pct=$(get_pct) || true
        _bclm=$(bc_read_bclm) || true
        if [ "$_cu" = "$_u" ] && [ "$_cl" = "$_l" ] && [ -n "$_pct" ] && [ -n "$_bclm" ]; then
            return 0
        fi
        [ "$_try" = "1" ] && sleep 2
    done
    return 1
}

# _bc_kick_enforcer - latency fix (2026-11-18): ask launchd to run the
# bc-limit enforcer NOW instead of at its next 60 s StartInterval tick,
# so a limit change takes effect in ~1-2 s instead of 0-60 s. Plain
# `launchctl kickstart` (no -k): if a run is already in flight, launchd
# starts no second instance - the kick is a harmless no-op and the
# in-flight run reads the fresh config anyway. The job lives in the
# system domain, so the kick needs root (sudo -n, the owner's NOPASSWD
# grant). Any failure is logged and swallowed: the config is already
# written and verified, and the next scheduled tick applies it exactly
# as before this fix existed.
_bc_kick_enforcer() {
    if /usr/bin/sudo -n /bin/launchctl kickstart system/com.batterycommander.bclimit >/dev/null 2>&1; then
        log "bc_apply_limit: enforcer kickstarted - applies immediately"
    else
        log "bc_apply_limit: kickstart unavailable - enforcer picks it up within 60s"
    fi
}

# _bc_kick_watchdog / _bc_kick_daemon — engagement-path latency fix
# (final cleanup 2026-11-18): session actions ride TWO 60 s cadences
# — the watchdog monitor arms a session, then the bc-limit daemon
# engages it (measured 2026-11-18: press 20:16:32 -> ARMED 20:16:59
# -> ENGAGED 20:17:56 = 84 s). Same discipline as _bc_kick_enforcer:
# plain kickstart (a run already in flight makes it a harmless
# no-op), failure logged and swallowed — the 60 s cadence remains
# the unchanged fallback. _bc_kick_enforcer above is deliberately
# left untouched (its log text is suite-visible); _bc_kick_daemon
# is the same kick with neutral wording for the session paths.
_bc_kick_watchdog() {
    if /usr/bin/sudo -n /bin/launchctl kickstart "gui/$(id -u)/com.batterycommander.watchdog" >/dev/null 2>&1; then
        log "kick: watchdog kickstarted"
    else
        log "kick: watchdog kickstart unavailable - next tick within 60s"
    fi
}

_bc_kick_daemon() {
    if /usr/bin/sudo -n /bin/launchctl kickstart system/com.batterycommander.bclimit >/dev/null 2>&1; then
        log "kick: enforcer kickstarted (session path)"
    else
        log "kick: enforcer kickstart unavailable (session path) - next tick within 60s"
    fi
}

# _bc_kick_session_chain <STARTED epoch> — after a REAL session
# start: kick the watchdog so its monitor arms the session now,
# wait (<= ~8 s) for the arming record of THIS session
# (.discharge_state PHASE=armed|active with the matching
# SESSION_STARTED), then kick the daemon so it engages on its
# first tick after arming instead of up to 60 s later. If arming
# does not land in the window, re-kick the watchdog once and kick
# the daemon anyway — worst case is the pre-fix behaviour.
_bc_kick_session_chain() {
    local _started="$1" _i=0 _st=""
    _bc_kick_watchdog
    if [ -z "$_started" ]; then
        _bc_kick_daemon
        return 0
    fi
    while [ "$_i" -lt 16 ]; do
        if [ -f "$DASH/.discharge_state" ]; then
            _st=$(grep '^SESSION_STARTED=' "$DASH/.discharge_state" 2>/dev/null | tail -1 | cut -d= -f2)
            if [ "$_st" = "$_started" ] \
                && grep -qE '^PHASE=(armed|active)' "$DASH/.discharge_state" 2>/dev/null; then
                break
            fi
        fi
        sleep 0.5
        _i=$((_i + 1))
    done
    if [ "$_i" -ge 16 ]; then
        log "kick: session not armed within 8s - re-kicking watchdog; daemon kicked anyway"
        _bc_kick_watchdog
    fi
    _bc_kick_daemon
}

# bc_apply_limit <UPPER> <LOWER> — the BC backend primitive (W1.1).
# Steps: (1) validate U/L; (2) read current state (BCLM, %, config) — fail
# BEFORE any write if the state is unreadable; (3) write the new config
# atomically (only after verification above); (4) verify by re-reading
# (config read-back + BCLM/% readable, via _bc_verify); (5) log.
# The enforcer picks the new config up on its next 60 s run. Returns 0 on
# success, 1 on failure (config NOT written on failure). SAILING/SAIL_GAP
# come from the caller's globals and are written with the limits.
bc_apply_limit() {
    local _u="$1" _l="$2" _pct _bclm
    validate_int "$_u" 15 100 || { log "bc_apply_limit: invalid upper ($_u)"; return 1; }
    validate_int "$_l" 15 99 || { log "bc_apply_limit: invalid lower ($_l)"; return 1; }
    [ "$_l" -lt "$_u" ] || { log "bc_apply_limit: lower ($_l) must be below upper ($_u)"; return 1; }
    _pct=$(get_pct) || true
    _bclm=$(bc_read_bclm) || true
    if [ -z "$_pct" ]; then
        log "bc_apply_limit: no battery reading — config NOT written"
        return 1
    fi
    if [ -z "$_bclm" ]; then
        log "bc_apply_limit: BCLM unreadable — config NOT written (enforcer state unknown)"
        return 1
    fi
    LAST_UPPER="$_u"
    LAST_LOWER="$_l"
    save_cfg
    if _bc_verify "$_u" "$_l"; then
        log "bc_apply_limit: config written $_u/$_l (pct=$_pct BCLM=$_bclm) — enforcer picks it up within 60s"
        _bc_kick_enforcer
        return 0
    fi
    log "bc_apply_limit: verify failed after config write $_u/$_l (pct=$_pct BCLM=$_bclm)"
    return 1
}

# _limit_failed_notify <U> <L> <label> — after a failed bc_apply_limit,
# the config may still hold the new limits (written, verify lagged — the
# enforcer reads the config and applies them anyway). Tell the user which
# one happened instead of always saying "failed".
_limit_failed_notify() {
    local _u="$1" _l="$2" _label="$3" _cu="" _cl=""
    if [ -f "$CFG" ]; then
        _cu=$(grep '^LAST_UPPER=' "$CFG" 2>/dev/null | cut -d= -f2-)
        _cl=$(grep '^LAST_LOWER=' "$CFG" 2>/dev/null | cut -d= -f2-)
    fi
    if [ "$_cu" = "$_u" ] && [ "$_cl" = "$_l" ]; then
        notify "Battery Commander (BC)" "$_label saved — applying within 60s (not verified)"
    else
        notify "Battery Commander (BC)" "$_label failed ($_u/$_l)"
    fi
}

# _daemon_loaded — 0 if the bc-limit enforcer LaunchDaemon is loaded.
# It lives in the SYSTEM domain (root LaunchDaemon since Phase C,
# 2026-11-13): `launchctl list <label>` in the user domain NEVER
# matches it — the same bug class the plugin carried until the
# 2026-11-14 integration fix. Use `launchctl print system/...`
# (the watchdog's _daemon_loaded pattern).
_daemon_loaded() {
    launchctl print system/com.batterycommander.bclimit >/dev/null 2>&1
}

# _bc_ready — 0 if the BC backend can be read (BCLM via bc-candidates).
# Logs a warning if the enforcer LaunchDaemon is not loaded.
_bc_ready() {
    local _bclm
    _bclm=$(bc_read_bclm) || { log "preflight: BCLM unreadable"; return 1; }
    if ! _daemon_loaded; then
        log "preflight: enforcer LaunchDaemon com.batterycommander.bclimit not loaded — config writes will not be applied until it is"
    fi
    return 0
}
# === SMART DISCHARGE SESSION ===
SD_SESSION_FILE="$DASH/.sd_session"

# Discharge intent (2026-11-14): pre_sleep_cleanup stores a resume
# intent (.discharge_intent) when a MODE=user session is torn down
# at sleep; the watchdog monitor recreates the session after the
# wake. Any dispatch action that ends or supersedes a discharge
# session is a NEWER user intent and must clear the stored one —
# a stale intent must never resurrect a session the user (or a
# charge intent) already moved past. $1 = caller tag for the log.
sd_intent_clear() {
    if [ -f "$DASH/.discharge_intent" ]; then
        rm -f "$DASH/.discharge_intent" "$DASH/.discharge_intent_block"
        printf '[%s] [REAL] INTENT_CLEARED by=%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "${1:-dispatch}" \
            >> "$DASH/discharge.log" 2>/dev/null
        log "sd_intent_clear: discharge intent cleared (by=${1:-dispatch})"
    fi
}

sd_session_invalidate() {
    rm -f "$SD_SESSION_FILE"
    sd_intent_clear "dispatch.teardown"
    # Discharge build (2026-11-13): every path that cleared the legacy
    # session (ensure_clean before a new charge intent, kill_discharge,
    # teardowns) also ends any discharge session, real or shadow — a new
    # user charge intent supersedes a running session. The watchdog
    # monitor sees the vanished file and closes the episode in
    # discharge.log. Never a cooldown (a teardown is not a flip abort).
    local _df _tag
    for _df in "$DASH/.discharge_session" "$DASH/.discharge_session.shadow"; do
        if [ -f "$_df" ]; then
            rm -f "$_df"
            if [ "$_df" = "$DASH/.discharge_session" ]; then _tag="REAL"; else _tag="SHADOW"; fi
            printf '[%s] [%s] SESSION_ENDED reason=teardown by=dispatch.sd_session_invalidate file=%s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$_tag" "$(basename "$_df")" \
                >> "$DASH/discharge.log" 2>/dev/null
            log "sd_session_invalidate: discharge session ended ($(basename "$_df"))"
        fi
    done
}

# === LIMIT PULL-DOWN (hardening 2026-11-14, WS1-A) ===
# A limit intent that lands with the battery ABOVE the new upper must
# ACT. The old behaviour wrote the config and deferred to "natural
# drain", which the user experiences as "nothing happened" (his
# report, 2026-11-14 21:34). sd_pull_down_for_limit <UPPER> starts a
# real user discharge session with TARGET=UPPER through the same
# session machinery smart_discharge uses — same file, same format,
# same atomic write, same flip-cooldown respect. It runs INSIDE
# intent_apply (the caller already holds acquire + the session
# guard), so it never re-acquires. Ordering follows the charge_full
# lesson: the config is already written when this runs — session
# second — so the watchdog monitor arms the session against the NEW
# config signature, and its config-supersede can never kill the
# session created here.
# Result lands in SD_PD_RESULT: started-ac | started-batt |
# started-shadow-ac | started-shadow-batt | already | cooldown |
# calibrate | range | none (battery not above target / no reading).
# The caller owns the user-facing notification text.
SD_PD_RESULT="none"
SD_PD_UNTIL=""
sd_pull_down_for_limit() {
    SD_PD_RESULT="none"; SD_PD_UNTIL=""
    local _u="$1" _cur _file _tag _ext _tgt _now
    validate_int "$_u" 15 100 || return 0
    _cur=$(get_pct); [ -n "$_cur" ] || return 0
    [ "$_cur" -gt "$_u" ] || return 0
    if [ "$_u" -ge 100 ]; then
        # pct above a 100 upper is impossible (pct <= 100); reached
        # only on a bogus reading — nothing to start.
        log "sd_pull_down: upper=100 at pct=$_cur — no session"
        return 0
    fi
    if [ "$_u" -lt 20 ]; then
        SD_PD_RESULT="range"
        log "sd_pull_down: upper $_u below the session target range (20-99) — no session; natural drain"
        return 0
    fi
    _file="$DASH/.discharge_session"; _tag="REAL"
    if [ -f "$DASH/.discharge_shadow" ]; then
        _file="$DASH/.discharge_session.shadow"; _tag="SHADOW"
    fi
    # A calibration run owns the session file — never touch it.
    if [ -f "$DASH/.discharge_session" ] \
        && grep -q '^MODE=calibrate' "$DASH/.discharge_session" 2>/dev/null; then
        SD_PD_RESULT="calibrate"
        log "sd_pull_down: calibration session active — no pull-down session (upper=$_u)"
        return 0
    fi
    if [ -f "$_file" ]; then
        _tgt=$(grep '^TARGET=' "$_file" 2>/dev/null | tail -1 | cut -d= -f2)
        case "$_tgt" in ''|*[!0-9]*) _tgt="" ;; esac
        if [ "$_tgt" = "$_u" ]; then
            SD_PD_RESULT="already"
            log "sd_pull_down: session already targets $_u — left untouched"
            return 0
        fi
    fi
    # Flip-abort cooldown (written by the watchdog monitor) — the
    # same respect smart_discharge's start path gives it. Checked
    # before any existing session is touched.
    if [ -f "$DASH/.discharge_cooldown" ]; then
        SD_PD_UNTIL=$(grep '^UNTIL=' "$DASH/.discharge_cooldown" 2>/dev/null | tail -1 | cut -d= -f2)
        case "$SD_PD_UNTIL" in ''|*[!0-9]*) SD_PD_UNTIL="" ;; esac
        if [ -n "$SD_PD_UNTIL" ] && [ "$(date +%s)" -lt "$SD_PD_UNTIL" ]; then
            SD_PD_RESULT="cooldown"
            log "sd_pull_down: start deferred — flip cooldown until $SD_PD_UNTIL (upper=$_u)"
            return 0
        fi
        SD_PD_UNTIL=""
    fi
    if [ -f "$_file" ]; then
        # An active session + a new limit intent: the config write
        # already superseded it (the monitor ends sessions on a
        # config change). Replace it explicitly so the episode log
        # tells the story, in the monitor's own vocabulary.
        _tgt=$(grep '^TARGET=' "$_file" 2>/dev/null | tail -1 | cut -d= -f2)
        case "$_tgt" in ''|*[!0-9]*) _tgt="?" ;; esac
        printf '[%s] [%s] SESSION_SUPERSEDED by=dispatch.limit-intent old_target=%s new_target=%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$_tag" "$_tgt" "$_u" >> "$DASH/discharge.log" 2>/dev/null
        rm -f "$_file"
        log "sd_pull_down: active session (target=$_tgt) superseded by limit intent $_u"
    fi
    _now=$(date +%s)
    atomic_write "$_file" "MODE=user
TARGET=$_u
STARTED=$_now
STARTER=dispatch
"
    # A limit-intent start supersedes any stored sleep-resume intent.
    [ "$_tag" = "REAL" ] && sd_intent_clear "dispatch.limit-intent"
    _ext="No"
    ioreg -rn AppleSmartBattery 2>/dev/null | grep -q '"ExternalConnected" = Yes' && _ext="Yes"
    printf '[%s] [%s] SESSION_START_REQUESTED target=%s cur=%s ext=%s starter=dispatch origin=limit-intent\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$_tag" "$_u" "$_cur" "$_ext" >> "$DASH/discharge.log" 2>/dev/null
    log "sd_pull_down: session started (target=$_u, cur=$_cur, ext=$_ext, tag=$_tag)"
    if [ "$_tag" = "SHADOW" ]; then
        if [ "$_ext" = "Yes" ]; then SD_PD_RESULT="started-shadow-ac"; else SD_PD_RESULT="started-shadow-batt"; fi
    elif [ "$_ext" = "Yes" ]; then
        SD_PD_RESULT="started-ac"
    else
        SD_PD_RESULT="started-batt"
    fi
    # Engagement-path latency (final cleanup 2026-11-18): a REAL
    # pull-down session waits on the same watchdog-arm + daemon
    # cadences as a Smart Discharge start — kick the chain now.
    # Every state the chain reads is already committed above
    # (config written before this call, session file atomic,
    # intent cleared); the rest of the intent is notifications.
    if [ "$SD_PD_RESULT" = "started-ac" ] || [ "$SD_PD_RESULT" = "started-batt" ]; then
        _bc_kick_session_chain "$_now"
    fi
}

# _pd_notify <base message> <upper> — one unmissable notification
# whose text states exactly what the pull-down did (WS1-A: feedback
# must never be ambiguous again).
_pd_notify() {
    local _base="$1" _u="$2" _until_human
    case "$SD_PD_RESULT" in
        started-ac)
            notify "Battery Commander (BC)" "$_base — discharging to ${_u}% (parked on AC; unplug to drain)" ;;
        started-batt)
            notify "Battery Commander (BC)" "$_base — discharging to ${_u}%" ;;
        started-shadow-ac)
            notify "Battery Commander (BC)" "$_base — shadow discharge to ${_u}% started (log only; parked on AC)" ;;
        started-shadow-batt)
            notify "Battery Commander (BC)" "$_base — shadow discharge to ${_u}% started (log only)" ;;
        already)
            notify "Battery Commander (BC)" "$_base — discharge to ${_u}% already running" ;;
        cooldown)
            _until_human=$(date -r "$SD_PD_UNTIL" '+%H:%M' 2>/dev/null || echo "later")
            notify "Battery Commander (BC)" "$_base — pull-down discharge deferred by the AC-flip cooldown (until ${_until_human}); the battery settles by natural drain meanwhile" ;;
        calibrate)
            notify "Battery Commander (BC)" "$_base — a calibration run owns the discharge session, so no pull-down was started" ;;
        range)
            notify "Battery Commander (BC)" "$_base — discharge sessions can't target below 20%, so the battery settles by natural drain" ;;
        *)
            notify "Battery Commander (BC)" "$_base" ;;
    esac
}

is_charging() { ioreg -rn AppleSmartBattery 2>/dev/null | grep -q '"IsCharging" = Yes'; }


# === INPUT PERSISTENCE ===
LAST_INPUTS="$DASH/.last_inputs"

get_last_input() {
    local key="$1" fallback="$2"
    local val=""
    [ -f "$LAST_INPUTS" ] && val=$(grep "^${key}=" "$LAST_INPUTS" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -z "$val" ] && echo "$fallback" || echo "$val"
}


# === ATOMIC WRITE ===
atomic_write() {
    local file="$1" content="$2"
    local tmp="${file}.tmp.$$"
    printf '%s' "$content" > "$tmp" && mv "$tmp" "$file"
}


# === INPUT VALIDATION ===
validate_int() {
    # $1 = value, $2 = min, $3 = max
    local v="$1" min="$2" max="$3"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    [ "$v" -ge "$min" ] && [ "$v" -le "$max" ] || return 1
    return 0
}


save_last_input() {
    local key="$1" val="$2"
    [ -z "$key" ] && return 0
    [ -z "$val" ] && return 0
    local tmp="${LAST_INPUTS}.tmp"
    if [ -f "$LAST_INPUTS" ]; then
        grep -v "^${key}=" "$LAST_INPUTS" 2>/dev/null > "$tmp" || true
    else
        touch "$tmp"
    fi
    echo "${key}=${val}" >> "$tmp"
    mv "$tmp" "$LAST_INPUTS" 2>/dev/null || true
}


save_cfg() {
    # Atomic config write (tmp+mv via atomic_write). Called ONLY by
    # bc_apply_limit (verify-first); intents never call save_cfg directly.
    local _content
    _content=$(printf 'LAST_UPPER=%s\nLAST_LOWER=%s\nSAILING=%s\nSAIL_GAP=%s\n' \
        "$LAST_UPPER" "$LAST_LOWER" "$SAILING" "$SAIL_GAP")
    atomic_write "$CFG" "$_content"
}

# NOTE: kill_clients() and soft_stop() are deleted — both were battopt/sudo.
# BC has no battopt processes to kill; session markers are cleared by
# _clear_session_locked / the BC kill_* helpers below.

# NOTE: _daemon_ok() is deleted — it health-checked the battopt daemon.
# BC readiness is _bc_ready() (BCLM readable? enforcer loaded?).

# Preflight — called by every action. Guarantees daemon responds.
# Preflight — called by every action (from acquire). BC version: no daemon
# restart, no force_reset, no battopt. Checks the shutdown flag and the
# active session, then logs the BC readiness (BCLM readable? enforcer
# LaunchDaemon loaded?). A missing/unloaded enforcer is a WARNING, not a
# failure — dispatch only writes config; the enforcer applies it on its
# next 60 s run. Never auto-loads the enforcer (loading is the Phase C gate).
preflight() {
    [ -f "$DASH/.user_shutdown" ] && return 0
    # Respect active session — do NOT force_reset during charge/discharge/hold
    if command -v guard_session_active >/dev/null 2>&1 && guard_session_active; then
        log "preflight: active session ($(cat "$DASH/.active_mode" 2>/dev/null)) — skipping force_reset"
        return 0
    fi
    # BC readiness: BCLM readable? enforcer loaded?
    if ! _bc_ready; then
        log "preflight: BC not ready (BCLM unreadable or enforcer not loaded) — continuing, config write only"
    fi
    return 0
}

# NOTE: run_with_retry() is deleted — it ran battopt with an "ongoing"
# retry. The BC equivalent is bc_apply_limit + _bc_verify (above).
ensure_clean() {
    # Invalidate old discharge ownership before starting another operation.
    sd_session_invalidate 2>/dev/null || true
    # BC: there are no battopt processes to kill and no discharge watcher
    # to stop (no BC discharge mechanism yet). The only transients are the
    # session markers; _clear_session_locked (inside intent_apply_inner)
    # owns the token/mode pair. If a session is active, do NOT clear its
    # markers here — the intent itself decides.
    [ -f "$DASH/.user_shutdown" ] && return 0
    # Respect active session — skip force_reset during charge/discharge/hold
    if command -v guard_session_active >/dev/null 2>&1 && guard_session_active; then
        log "ensure_clean: active session — skipping force_reset"
        return 0
    fi
    # No "ongoing" state exists in BC (that was a battopt daemon concept).
    # A stale .charge_target with no active session is cleared so a new
    # intent starts clean.
    local _mode
    _mode=$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')
    [ "$_mode" = "idle" ] && rm -f "$DASH/.charge_target" 2>/dev/null || true
}

_kill_descendants() {
    local signal="$1"
    local pid="$2"
    local child

    for child in $(pgrep -P "$pid" 2>/dev/null); do
        _kill_descendants "$signal" "$child"
    done
    kill "-$signal" "$pid" 2>/dev/null || true
}

_start_lock_watchdog() {
    (
        sleep "$LOCK_TIMEOUT"

        if [ "$(cat "$LOCK" 2>/dev/null | tr -d '[:space:]')" = "$LOCK_OWNER_PID" ] &&
           kill -0 "$LOCK_OWNER_PID" 2>/dev/null; then
            log "acquire: lock timeout ${LOCK_TIMEOUT}s; terminating dispatch pid=$LOCK_OWNER_PID"
            _kill_descendants TERM "$LOCK_OWNER_PID"
            sleep 2
            if kill -0 "$LOCK_OWNER_PID" 2>/dev/null; then
                _kill_descendants KILL "$LOCK_OWNER_PID"
            fi
        fi
    ) >/dev/null 2>&1 &
    LOCK_WATCHDOG_PID=$!
}

acquire() {
    local old_pid old_age old_cmd
    local _tries=0

    while :; do
        # Bound the retry loop: if the lock file can never be created
        # (missing/unwritable state dir) there is no live owner to wait
        # for -- spinning forever here hung dispatch with no timeout.
        _tries=$((_tries + 1))
        if [ "$_tries" -gt 10 ]; then
            log "acquire: giving up after $_tries lock attempts"
            exit 1
        fi
        # Bash noclobber provides an atomic create for the PID file.
        if ( set -C; printf '%s\n' "$$" > "$LOCK" ) 2>/dev/null; then
            break
        fi

        old_pid=$(cat "$LOCK" 2>/dev/null | tr -d '[:space:]')

        if [ -z "$old_pid" ] || ! kill -0 "$old_pid" 2>/dev/null; then
            log "acquire: removing dead lock owner=${old_pid:-unknown}"
            if [ "$(cat "$LOCK" 2>/dev/null | tr -d '[:space:]')" = "$old_pid" ]; then
                rm -f "$LOCK"
            fi
            continue
        fi

        old_age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
        if [ "$old_age" -gt "$LOCK_TIMEOUT" ]; then
            old_cmd=$(ps -p "$old_pid" -o command= 2>/dev/null)
            log "acquire: stale lock pid=$old_pid age=${old_age}s"

            # Terminate only a process that still appears to be dispatch.sh.
            # Never kill an unrelated process that reused the recorded PID.
            case "$old_cmd" in
                *dispatch.sh*)
                    _kill_descendants TERM "$old_pid"
                    sleep 2
                    if kill -0 "$old_pid" 2>/dev/null; then
                        _kill_descendants KILL "$old_pid"
                    fi
                    ;;
            esac

            # Remove only the same owner observed above. Do not remove a
            # newer owner's lock if the expired process already cleaned up.
            if [ "$(cat "$LOCK" 2>/dev/null | tr -d '[:space:]')" = "$old_pid" ]; then
                rm -f "$LOCK"
            fi
            continue
        fi

        log "lock held by pid=$old_pid age=${old_age}s"
        exit 2
    done

    LOCK_OWNED=1
    LOCK_OWNER_PID=$$
    log "acquire: lock acquired pid=$$"

    _start_lock_watchdog

    # SAFETY LAYER: preflight before every action
    if ! preflight; then
        release
        exit 1
    fi
}

release() {
    if [ "$LOCK_OWNED" -eq 1 ] &&
       [ "$(cat "$LOCK" 2>/dev/null | tr -d '[:space:]')" = "$$" ]; then
        rm -f "$LOCK"
    fi

    if [ -n "$LOCK_WATCHDOG_PID" ]; then
        kill "$LOCK_WATCHDOG_PID" 2>/dev/null || true
        wait "$LOCK_WATCHDOG_PID" 2>/dev/null || true
        LOCK_WATCHDOG_PID=""
    fi

    LOCK_OWNED=0
    LOCK_OWNER_PID=""
    clear_cache; }

notify() {
    # App-native notification transport (final cleanup 2026-11-18,
    # owner order: notifications are the app's OWN — no external
    # notifier is a product dependency anywhere). Scripts never post
    # directly: notify() appends ONE line (title<TAB>body) to the
    # queue file, and BatteryCommander.app drains the queue on its
    # 10 s refresh cadence and posts each line itself via
    # UNUserNotificationCenter — so every notification carries the
    # app's name and icon automatically and persists in Notification
    # Center. BC_NOTIFY_QUEUE overrides the queue path for sandbox
    # tests only (same pattern as BC_PMSET). Tabs/newlines in the
    # text are flattened so one call is always exactly one line.
    local _queue="${BC_NOTIFY_QUEUE:-$DASH/.notify_queue}"
    local _t _b
    _t=$(printf '%s' "$1" | tr '\n\t' '  ')
    _b=$(printf '%s' "$2" | tr '\n\t' '  ')
    printf '%s\t%s\n' "$_t" "$_b" >> "$_queue" 2>/dev/null || true
}

# BC kill helpers (v1): the UI never kills the root enforcer (only the
# LaunchDaemon-run bc-limit writes BCLM; it is not pkill'ed from the UI).
# These clear the session markers and log. (Design §3 — the exact
# kill/stop mechanism for a root enforcer is a W1 flag, not a sudo kill.)
kill_charge()    { log "kill_charge";    rm -f "$DASH/.charge_target" 2>/dev/null; }
kill_discharge() {
    log "kill_discharge"
    local _had=0
    [ -f "$DASH/.discharge_session" ] && _had=1
    sd_session_invalidate 2>/dev/null || true
    # Engagement-path latency (final cleanup 2026-11-18): if a real
    # session actually ended, the watchdog (episode close-out) and
    # the daemon (discharge-mode disengage + hold restore) would
    # otherwise wait for their 60 s cadences — kick both now.
    if [ "$_had" = "1" ]; then
        _bc_kick_watchdog
        _bc_kick_daemon
    fi
}
kill_calibrate() {
    log "kill_calibrate"
    # Calibrate build (2026-11-14): force stop = remove the run's
    # session file NOW (the drain/park stops immediately) + write
    # the cancel marker; the watchdog's run supervisor lands the
    # run in the safe state on its next tick (config + power
    # posture restored and verified, run file closed).
    if [ -f "$DASH/.discharge_session" ] \
        && grep -q '^MODE=calibrate' "$DASH/.discharge_session" 2>/dev/null; then
        rm -f "$DASH/.discharge_session"
        printf '[%s] [REAL] SESSION_ENDED reason=force-stop by=dispatch.kill_calibrate file=.discharge_session\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" >> "$DASH/discharge.log" 2>/dev/null
        log "kill_calibrate: calibration session file removed"
    fi
    if [ -f "$DASH/.calibration_run" ]; then
        echo "$(date +%s)" > "$DASH/.calibration_cancel_request"
        log "kill_calibrate: cancel requested — supervisor restores the safe state"
        notify "Battery Commander (BC)" "Calibration stopping — safe state within a minute"
        # Engagement-path latency (final cleanup 2026-11-18): the
        # run supervisor IS the watchdog — kick it so the safe state
        # lands in seconds instead of on the 60 s cadence.
        _bc_kick_watchdog
    else
        log "kill_calibrate: no calibration run active"
    fi
}

# calibration_profile — auto-profile by battery health (Yousef's
# direction, 2026-11-14; calibrate design as amended at build).
# Reads health = FullChargeCapacity/DesignCapacity and CycleCount
# via bc-status and echoes:
#   "FLOOR ABS_FLOOR SUPERVISION PROFILE HEALTH_X10 FCC DESIGN CYCLES"
# Bands: health >= 80% -> floor 10, emergency 8, no supervision
# line; health 60-80% -> floor 10, emergency 8, supervision 30%;
# health < 60% OR cycles > 1000 -> floor 15, emergency 12,
# supervision 35%. Returns 1 when the readings are unusable (a
# calibration must never start blind).
calibration_profile() {
    local _fcc _des _cyc _hx _floor _abs _sup _prof
    _fcc=$(bc_status_value "FullCharge" 2>/dev/null | tr -dc '0-9')
    _des=$(bc_status_value "Design" 2>/dev/null | tr -dc '0-9')
    _cyc=$(bc_status_value "Cycle" 2>/dev/null | tr -dc '0-9')
    case "$_fcc" in ''|*[!0-9]*) return 1 ;; esac
    case "$_des" in ''|*[!0-9]*) return 1 ;; esac
    case "$_cyc" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_des" -gt 0 ] || return 1
    _hx=$(( _fcc * 1000 / _des ))
    if [ "$_cyc" -gt 1000 ] || [ "$_hx" -lt 600 ]; then
        _floor=15; _abs=12; _sup=35; _prof="low"
    elif [ "$_hx" -ge 800 ]; then
        _floor=10; _abs=8; _sup=0; _prof="high"
    else
        _floor=10; _abs=8; _sup=30; _prof="mid"
    fi
    printf '%s %s %s %s %s %s %s %s' "$_floor" "$_abs" "$_sup" "$_prof" "$_hx" "$_fcc" "$_des" "$_cyc"
}

# _pmset_battery_sleep — the current system-sleep minutes on
# battery scope (pmset -g custom, Battery Power section), or empty.
_pmset_battery_sleep() {
    "$PMSET_BIN" -g custom 2>/dev/null | awk '
        /^Battery Power:/ { s=1; next }
        /^AC Power:/ { s=0 }
        s && $1=="sleep" { print $2; exit }'
}

# PMSET_BIN is overridable for sandbox tests only (BC_PMSET);
# production always uses the system pmset.
PMSET_BIN="${BC_PMSET:-/usr/bin/pmset}"


# === CACHE INVALIDATION ===
clear_cache() {
    rm -f "$DASH/.status_cache"
}

# === SWIFTBAR REFRESH HOOK ===
# NOTE (W2): the plugin name becomes battery-commander.10s.sh when W2
# renames it; update the refresh name then.
# Trigger SwiftBar to re-run the plugin immediately after any dispatch action.
# Falls back silently if SwiftBar isn't running or URL scheme unsupported.
refresh_swiftbar() {
    /usr/bin/open -g "swiftbar://refreshplugin?name=battery-commander.10s" >/dev/null 2>&1 || true
}

# === INTENT APPLY (v1.6.2) — atomic battery mutations ===

# NOTE: _kill_transients() is deleted — it pkill'ed battopt charge /
# discharge / calibrate / sd_watcher and ran `battopt ... stop`. In BC
# there is nothing to kill from the UI; _clear_session_locked owns the
# session state.

_clear_session_locked() {
    guard_token_clear_locked || return 1
    rm -f "$DASH/.sd_session"
    rm -f "$DASH/.hold_override"
    rm -f "$DASH/.hold_token"
    rm -f "$DASH/.pre_hold_config"
}

# NOTE: _verify_smc_upper() is deleted — it parsed battopt's free-text
# status for "upper limit N". The BC verifier is _bc_verify() (above):
# the limit % lives in the config, never in the SMC.

intent_apply_inner() {
    local kind="$1"; shift
    local U L T CUR V MODE GAP TOKEN
    local D="$DASH"

    guard_lock || { log "intent_apply: lock failed ($kind)"; return 1; }

    # BC: no _kill_transients (no battopt processes to kill, no discharge
    # watcher to stop). _clear_session_locked owns the token/mode pair.
    _clear_session_locked || {
        log "intent_apply: clear session failed ($kind)"
        guard_unlock
        return 1
    }

    case "$kind" in
        limit)
            U="$1"; L="$2"; MODE="$3"; GAP="$4"
            CUR=$(get_pct)
            # Respect caller-provided MODE; fallback for backward compat
            if [ "$MODE" = "Hold" ]; then
                SAILING=false
                SAIL_GAP=1
            elif [ "$MODE" = "Sail" ] || [ "$MODE" = "Sailing" ]; then
                SAILING=true
                [ -n "$GAP" ] && SAIL_GAP="$GAP"
                validate_int "$SAIL_GAP" 5 30 2>/dev/null || SAIL_GAP=10
            else
                # backward compat: no MODE passed → keep legacy behavior
                SAILING=true
                SAIL_GAP=$((U - L))
                [ "$SAIL_GAP" -lt 1 ] && SAIL_GAP=1
            fi
            echo "hold" > "$D/.active_mode"
            guard_token_write_locked hold >/dev/null || { guard_unlock; return 1; }
            # Above-target pull-down (hardening 2026-11-14, WS1-A):
            # if the battery is above the new upper, a real discharge
            # session to the upper starts after the config write —
            # see sd_pull_down_for_limit. (The deferred "natural
            # drain" behaviour was removed by Yousef's order: a limit
            # the user sets must act.)
            if bc_apply_limit "$U" "$L"; then
                guard_token_clear_locked
                echo "idle" > "$D/.active_mode"
                sd_pull_down_for_limit "$U"
                guard_unlock
                _pd_notify "Limit set ${U}% / ${L}%" "$U"
                return 0
            fi
            guard_token_clear_locked
            echo "idle" > "$D/.active_mode"
            guard_unlock
            log "intent_apply: limit failed ($U/$L)"
            _limit_failed_notify "$U" "$L" "Limit"
            return 1
            ;;

        hold_current)
            CUR=$(get_pct)
            [ -n "$CUR" ] || {
                guard_unlock
                notify "Battery Commander (BC)" "Hold failed (no battery reading)"
                return 1
            }
            # A hold needs lower < upper with lower >= 15 (bc_apply_limit):
            # at 15% or below no valid pair exists -- fail clearly instead
            # of the old clamp dance, which produced e.g. 20/19 and was
            # then rejected by bc_apply_limit with a confusing message.
            if [ "$CUR" -le 15 ]; then
                guard_unlock
                notify "Battery Commander (BC)" "Hold failed (battery ${CUR}% — too low to hold)"
                log "intent_apply: hold_current refused at ${CUR}% (no valid lower >= 15 below upper)"
                return 1
            fi
            U="$CUR"
            L=$((CUR - 1))
            # A hold is not sailing: reset the sailing flags like the
            # limit/Hold path does, so a stale SAILING=true + gap does
            # not persist in the config with a hold limit.
            SAILING=false
            SAIL_GAP=1
            echo "hold" > "$D/.active_mode"
            guard_token_write_locked hold >/dev/null || { guard_unlock; return 1; }
            if bc_apply_limit "$U" "$L"; then
                log "intent_apply: hold_current persisted $U/$L"
                guard_token_clear_locked
                echo "hold" > "$D/.active_mode"
                rm -f "$D/.charge_target"  # hold = no target
                date +%s > "$D/.hold_since"
                guard_unlock
                notify "Battery Commander (BC)" "Holding at ${U}%"
                return 0
            fi
            guard_token_clear_locked
            echo "idle" > "$D/.active_mode"
            rm -f "$D/.charge_target"  # hold failed, no charge intent
            guard_unlock
            log "intent_apply: hold_current failed ($U/$L)"
            _limit_failed_notify "$U" "$L" "Hold"
            return 1
            ;;

        clear_hold)
            # BC (approved decision 3): remove the hold and return to the
            # configured limit (LAST_UPPER/LAST_LOWER from the canonical
            # config). This replaces the old behaviour, which was identical
            # to stop_now (hold at current % — it removed nothing).
            if bc_apply_limit "$LAST_UPPER" "$LAST_LOWER"; then
                echo "idle" > "$D/.active_mode"
                rm -f "$D/.hold_since"  # hold cleared
                # Same pull-down rule as the limit branch (WS1-A):
                # returning to a configured limit below the current
                # charge starts the session that takes it there.
                sd_pull_down_for_limit "$LAST_UPPER"
                guard_unlock
                _pd_notify "Hold cleared — limit ${LAST_UPPER}% / ${LAST_LOWER}%" "$LAST_UPPER"
                return 0
            fi
            echo "idle" > "$D/.active_mode"
            guard_unlock
            log "intent_apply: clear_hold failed ($LAST_UPPER/$LAST_LOWER)"
            _limit_failed_notify "$LAST_UPPER" "$LAST_LOWER" "Clear hold"
            return 1
            ;;
        sail_on|sail_off|sail_gap)
            case "$kind" in
                sail_on)
                    SAILING=true
                    [ "$LAST_LOWER" -ge "$LAST_UPPER" ] && LAST_LOWER=$((LAST_UPPER - 5))
                    [ "$LAST_LOWER" -lt 15 ] && LAST_LOWER=15
                    ;;
                sail_off)
                    SAILING=false
                    ;;
                sail_gap)
                    GAP="$1"
                    SAIL_GAP="$GAP"
                    if [ "$SAILING" = "true" ]; then
                        LAST_LOWER=$((LAST_UPPER - GAP))
                        [ "$LAST_LOWER" -lt 15 ] && LAST_LOWER=15
                    fi
                    ;;
            esac
            echo "hold" > "$D/.active_mode"
            guard_token_write_locked hold >/dev/null || { guard_unlock; return 1; }
            if bc_apply_limit "$LAST_UPPER" "$LAST_LOWER"; then
                guard_token_clear_locked
                echo "idle" > "$D/.active_mode"
                guard_unlock
                notify "Battery Commander (BC)" "$kind applied ($LAST_UPPER/$LAST_LOWER)"
                return 0
            fi
            guard_token_clear_locked
            echo "idle" > "$D/.active_mode"
            guard_unlock
            log "intent_apply: $kind failed ($LAST_UPPER/$LAST_LOWER)"
            _limit_failed_notify "$LAST_UPPER" "$LAST_LOWER" "Sail"
            return 1
            ;;

        disable_limit)
            U=100; L=99
            SAILING=false
            SAIL_GAP=1
            if bc_apply_limit "$U" "$L"; then
                guard_token_clear_locked
                echo "idle" > "$D/.active_mode"
                rm -f "$D/.charge_target"  # limits disabled, no charge intent
                guard_unlock
                notify "Battery Commander (BC)" "Limits disabled (100/99)"
                return 0
            fi
            guard_token_clear_locked
            echo "idle" > "$D/.active_mode"
            rm -f "$D/.charge_target"
            guard_unlock
            log "intent_apply: disable_limit failed (100/99)"
            _limit_failed_notify 100 99 "Disable limits"
            return 1
            ;;

        charge_full)
            echo "charge_full" > "$D/.active_mode"
            echo "100" > "$D/.charge_target"  # dispatch charge = to 100.
            # Mode written BEFORE the flag (charge build 2026-11-14):
            # the watchdog stale-clears .charge_target on any tick whose
            # mode is not charge_full, so an interleaved tick must never
            # see the flag without the mode (it would delete the flag of
            # a live charge_full intent and the 100% mode flip would
            # never fire). Mode-first makes every interleaving safe.
            TOKEN=$(guard_token_write_locked charge_full) || {
                rm -f "$D/.charge_target"  # token failed, no charge intent
                echo "idle" > "$D/.active_mode"
                guard_unlock
                return 1
            }
            # BC: "charge to 100%" = limit 100/99, enforced by bc-limit
            # (BCLM=100 until 100%, then BCLM=10). No `battopt charge` and
            # no 2 h watcher — the enforcer's 60 s loop is the watcher.
            # No separate 99/98 step. .charge_target stays until the battery
            # reaches 100% (cleared by the BC watchdog, W3) or the next
            # intent clears it.
            # Charging to 100% is not sailing (same reset as disable_limit).
            SAILING=false
            SAIL_GAP=1
            if bc_apply_limit 100 99; then
                guard_unlock
                notify "Battery Commander (BC)" "Charging to 100%"
                return 0
            fi
            guard_token_clear_locked
            echo "idle" > "$D/.active_mode"
            rm -f "$D/.charge_target"  # limit failed, no charge intent
            guard_unlock
            _limit_failed_notify 100 99 "Charge to 100%"
            return 1
            ;;

        smart_discharge)
            # Discharge build (2026-11-13): Smart Discharge is the
            # discharge-session toggle handled directly by the
            # smart_discharge action (session file + watchdog monitor +
            # bc-limit). This intent branch is retired — it must never
            # write the config again (the old stub set the limit to the
            # target). Defensive no-op for stale callers.
            log "intent_apply: smart_discharge retired — session toggle lives in the smart_discharge action"
            guard_unlock
            notify "Battery Commander (BC)" "Smart Discharge uses sessions now — use the Smart Discharge menu item"
            return 0
            ;;

        calibration_start)
            # Calibrate build (2026-11-14): calibration start/cancel
            # is the calibrate ACTION's toggle (run file + watchdog
            # run supervisor), like Smart Discharge. This intent
            # branch is retired — a defensive no-op for stale callers.
            log "intent_apply: calibration_start retired — toggle lives in the calibrate action"
            guard_unlock
            notify "Battery Commander (BC)" "Use the Calibration menu item to start calibration"
            return 0
            ;;

        calibration_stop)
            # Routes through kill_calibrate (session removal + the
            # supervisor's cancel marker). The supervisor owns the
            # safe-state landing, so no mode/token surgery here.
            kill_calibrate
            guard_unlock
            return 0
            ;;

        *)
            log "intent_apply: unknown kind ($kind)"
            guard_unlock
            return 1
            ;;
    esac
}

intent_apply() {
    intent_apply_inner "$@"
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        rm -f "$DASH/.layer4b_hold" 2>/dev/null || true
    fi
    return "$rc"
}

# === END INTENT APPLY ===

cleanup() {
    local rc="$1"

    if [ -n "$LOCK_WATCHDOG_PID" ]; then
        kill "$LOCK_WATCHDOG_PID" 2>/dev/null || true
        wait "$LOCK_WATCHDOG_PID" 2>/dev/null || true
        LOCK_WATCHDOG_PID=""
    fi

    # Remove only our lock. A delayed cleanup must never remove a newer
    # dispatch process's lock after ownership has changed.
    if [ "$LOCK_OWNED" -eq 1 ] &&
       [ "$(cat "$LOCK" 2>/dev/null | tr -d '[:space:]')" = "$$" ]; then
        rm -f "$LOCK"
    fi

    sleep 1
    refresh_swiftbar
    return "$rc"
}

# Convert termination signals into a normal exit so the EXIT cleanup runs.
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# Fire refresh and lock cleanup on normal, error, and signal paths.
trap 'cleanup $?' EXIT

# _stay_batt_superseded — a Sleep Mode choice supersedes the Stay
# Awake (On Battery) toggle (final cleanup 2026-11-18): drop the
# toggle's marker so the menu state is true immediately. The mode's
# own pmset posture (applied by the caller before this runs)
# governs disablesleep from here; the watchdog guard performs the
# same stand-down as a backstop for changes made any other way.
_stay_batt_superseded() {
    if [ -f "$DASH/.stay_awake_batt" ]; then
        rm -f "$DASH/.stay_awake_batt"
        log "stay_awake_batt: superseded by a sleep mode change — marker cleared"
    fi
}

case "$1" in
    force_reset)
        # BC recovery (W6): re-verify BCLM + config + daemon state,
        # then reapply the configured limit (see force_reset.sh).
        acquire
        if [ -x "$DASH/force_reset.sh" ]; then
            if "$DASH/force_reset.sh"; then
                log "force_reset: BC recovery done"
                notify "Battery Commander (BC)" "Reset done — limit re-applied"
            else
                log "force_reset: BC recovery FAILED — see actions.log"
                notify "Battery Commander (BC)" "Reset failed — check actions.log"
            fi
        else
            log "force_reset: force_reset.sh not found in $DASH"
            notify "Battery Commander (BC)" "Reset not available — script missing"
        fi
        release
        ;;
    
    stay_awake_batt_toggle)
        # Stay Awake (On Battery) — final cleanup 2026-11-18 (owner
        # request): the battery-scoped sibling of Stay Awake (Lid
        # Closed), written with pmset -b disablesleep 1. (Catalina
        # stores disablesleep as one system-wide value — probed
        # 2026-11-18 — so on this OS the effect is not confined to
        # the battery source; the -b write is still the correct
        # scoped intent for per-source macOS versions.) State lives
        # in its OWN marker (.stay_awake_batt) — deliberately NOT a
        # .sleep_mode value, so self_healing's mode validation and
        # the AC-mode auto-reverts never see it. Safety net: the
        # watchdog guard (section_stay_awake_batt) auto-reverts at
        # <=20% on battery, stands down when a Sleep Mode change
        # supersedes the toggle, and re-asserts the setting if it
        # was cleared externally. The dialog carries the caution,
        # mirroring the Lid Closed flow.
        SAB_MARKER="$DASH/.stay_awake_batt"
        if [ -f "$SAB_MARKER" ]; then
            # --- Turn OFF ---
            if sudo -n /usr/bin/pmset -b disablesleep 0 >/dev/null 2>&1; then
                rm -f "$SAB_MARKER"
                log "stay_awake_batt: OFF (pmset -b disablesleep 0)"
                notify "Battery Commander (BC)" "Stay Awake (On Battery): OFF — normal sleep on battery"
            else
                log "stay_awake_batt: OFF FAILED (pmset error) - marker kept"
                notify "Battery Commander (BC)" "Stay Awake (On Battery): OFF FAILED (pmset error - see actions.log)"
            fi
            exit 0
        fi
        # --- Turn ON ---
        # The Lid Closed mode already disables sleep for EVERY
        # power source (-a); a battery toggle on top adds nothing.
        SAB_MODE=$(cat "$DASH/.sleep_mode" 2>/dev/null | tr -d '[:space:]')
        if [ "$SAB_MODE" = "download" ]; then
            notify "Battery Commander (BC)" "Stay Awake is already ON for all power sources (Lid Closed mode) — battery covered"
            log "stay_awake_batt: ON refused — sleep_mode=download already covers all sources"
            exit 0
        fi
        CONFIRM=$(osascript <<AS
try
    set d to display dialog "Stay Awake (On Battery)\n\nThe Mac will NOT sleep while running on battery (the display may still sleep).\n\n⚠️ Heat caution: never leave a running Mac in a bag or enclosed space.\n\nSafety: it switches itself OFF automatically at 20% battery." buttons {"Cancel", "Stay Awake"} default button "Cancel" with title "Battery Commander (BC)"
    return button returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        if [ "$CONFIRM" != "Stay Awake" ]; then
            log "stay_awake_batt: ON declined at dialog"
            exit 0
        fi
        if ! sudo -n /usr/bin/pmset -b disablesleep 1 >/dev/null 2>&1; then
            log "stay_awake_batt: ON FAILED (pmset error) - marker NOT written"
            notify "Battery Commander (BC)" "Stay Awake (On Battery): FAILED to start (pmset error - see actions.log)"
            exit 0
        fi
        # Verify before claiming ON. Platform fact (probed live
        # 2026-11-18): on Catalina, disablesleep is stored as ONE
        # system-wide value — a `pmset -b disablesleep 1` write is
        # exactly what `pmset -g` reports as SleepDisabled (even on
        # AC), a later `-c`/`-a` write replaces it, and
        # `pmset -g custom` never lists the key at all. So the
        # effective SleepDisabled IS the read-back, on any source.
        # (The -b write remains the correct scoped intent: on
        # macOS versions with true per-source storage it lands on
        # the battery profile only.)
        SAB_EFF=$(pmset -g 2>/dev/null | awk '/SleepDisabled/{print $2}')
        if [ "$SAB_EFF" = "1" ]; then
            atomic_write "$SAB_MARKER" "SINCE=$(date +%s)"
            log "stay_awake_batt: ON verified (SleepDisabled=1 after pmset -b)"
            notify "Battery Commander (BC)" "Stay Awake (On Battery): ON — auto-off at 20%"
        else
            sudo -n /usr/bin/pmset -b disablesleep 0 >/dev/null 2>&1
            log "stay_awake_batt: ON verify FAILED (SleepDisabled=${SAB_EFF:-?}) — reverted"
            notify "Battery Commander (BC)" "Stay Awake (On Battery): FAILED to verify — not enabled"
        fi
        ;;

    sleep_mode_default)
        acquire
        rm -f "$DASH/.sleep_override_ac"
        rm -f "$DASH/.sleep_override_lid"
        rm -f "$DASH/.sleep_override_batt"
        SM_FAIL=0
        sudo -n /usr/bin/pmset -a disablesleep 0 || SM_FAIL=1
        # Battery defaults
        $DASH/power_saver.sh enforce-sleep-policy || SM_FAIL=1
        # AC defaults — restore normal sleep timing. Conflict fix
        # 2026-11-26: the AC sleep timer belongs to the active power
        # profile when one is applied — restore it instead of the
        # hardcoded default. Power Saver's timer was already set by
        # enforce-sleep-policy above.
        _pm_owner=$(cat "$DASH/.current_power_mode" 2>/dev/null | tr -d '[:space:]')
        case "$_pm_owner" in
            fast|balanced|awake|deep)
                "$DASH/power_mode.sh" "$_pm_owner" >/dev/null 2>&1 || SM_FAIL=1
                ;;
            powersaver)
                ;;
            *)
                sudo -n /usr/bin/pmset -c sleep 120 || SM_FAIL=1
                ;;
        esac
        sudo -n /usr/bin/pmset -c displaysleep 20 || SM_FAIL=1
        sudo -n /usr/bin/pmset -c disksleep 0 || SM_FAIL=1
        sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || SM_FAIL=1
        if [ "$SM_FAIL" -ne 0 ]; then
            log "sleep_mode: default FAILED (pmset/power_saver error) - .sleep_mode NOT updated"
            notify "Battery Commander (BC)" "Sleep Mode: Default FAILED (pmset error - see actions.log)"
            release
            exit 1
        fi
        atomic_write "$DASH/.sleep_mode" "default"
        _stay_batt_superseded
        log "sleep_mode: default"
        notify "Battery Commander (BC)" "Sleep Mode: Default"
        release
        ;;

    sleep_mode_presentation)
        # Requires AC
        if ! pmset -g batt 2>/dev/null | grep -q "AC Power"; then
            osascript -e 'display dialog "⚠️  AC required

Presentation Mode only works with the charger connected." buttons {"OK"} with title "Sleep Mode" with icon caution' 2>/dev/null
            exit 0
        fi
        acquire
        rm -f "$DASH/.sleep_override_lid" "$DASH/.sleep_override_batt"
        touch "$DASH/.sleep_override_ac"
        SM_FAIL=0
        sudo -n /usr/bin/pmset -c sleep 0 || SM_FAIL=1
        sudo -n /usr/bin/pmset -c displaysleep 0 || SM_FAIL=1
        sudo -n /usr/bin/pmset -c disksleep 0 || SM_FAIL=1
        sudo -n /usr/bin/pmset -a disablesleep 0 || SM_FAIL=1
        sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || SM_FAIL=1
        if [ "$SM_FAIL" -ne 0 ]; then
            log "sleep_mode: presentation FAILED (pmset error) - .sleep_mode NOT updated"
            notify "Battery Commander (BC)" "Sleep Mode: Presentation FAILED (pmset error - see actions.log)"
            release
            exit 1
        fi
        atomic_write "$DASH/.sleep_mode" "presentation"
        _stay_batt_superseded
        log "sleep_mode: presentation"
        notify "Battery Commander (BC)" "Sleep Mode: Presentation"
        release
        ;;

    sleep_mode_download)
        if ! pmset -g batt 2>/dev/null | grep -q "AC Power"; then
            osascript -e 'display dialog "⚠️  AC required

Stay Awake mode only works with the charger connected." buttons {"OK"} with title "Sleep Mode" with icon caution' 2>/dev/null
            exit 0
        fi
        BUTTON=$(osascript << 'AS'
try
    display dialog "⚠️  Enable Stay Awake (Lid Closed)?

Keeps Mac fully awake with lid closed.

Risks:
• Heat buildup — place on hard surface only
• Never put in bag or cushion
• Auto-disables when unplugged

Best for: large downloads, long exports, backups." buttons {"Cancel", "Enable"} default button "Cancel" with title "Sleep Mode" with icon caution
    return button returned of result
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$BUTTON" != "Enable" ] && { exit 0; }
        
        acquire
        # Ensure sleep disable is off before starting
        sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null
        sleep 1
        
        # Enable sleep disable (lid-closed awake)
        sudo -n /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1
        
        # Verify it started
        sleep 1
        if [ "$(pmset -g | awk '/SleepDisabled/{print $2}')" != "1" ]; then
            notify "Battery Commander (BC)" "Stay Awake: FAILED to start"
            release
            exit 1
        fi
        
        atomic_write "$DASH/.sleep_mode" "download"
        _stay_batt_superseded
        log "sleep_mode: download (disablesleep=1)"
        notify "Battery Commander (BC)" "Stay Awake: ON — disable when done"
        release
        ;;

    sleep_mode_normal_from_download)
        acquire
        if ! sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null; then
            log "sleep_mode: normal_from_download FAILED (pmset disablesleep 0) - .sleep_mode NOT updated"
            notify "Battery Commander (BC)" "Stay Awake: OFF FAILED (pmset error - see actions.log)"
            release
            exit 1
        fi
        atomic_write "$DASH/.sleep_mode" "default"
        _stay_batt_superseded
        log "sleep_mode: disablesleep=0"
        notify "Battery Commander (BC)" "Stay Awake: OFF"
        release
        ;;

    sleep_mode_travel)
        BUTTON=$(osascript << 'AS'
try
    display dialog "⚠️  Enable Travel Mode?

Battery hibernates after 4h instead of 30min.

Impact:
• Drains battery ~3% more overnight
• Keeps session state alive longer
• Only affects battery (AC unchanged)

Best for: short trips, keeping state alive." buttons {"Cancel", "Enable"} default button "Cancel" with title "Sleep Mode" with icon caution
    return button returned of result
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$BUTTON" != "Enable" ] && { exit 0; }
        
        acquire
        rm -f "$DASH/.sleep_override_ac" "$DASH/.sleep_override_lid"
        touch "$DASH/.sleep_override_batt"
        SM_FAIL=0
        $DASH/power_saver.sh apply-delays travel || SM_FAIL=1
        sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || SM_FAIL=1
        if [ "$SM_FAIL" -ne 0 ]; then
            log "sleep_mode: travel FAILED (pmset/power_saver error) - .sleep_mode NOT updated"
            notify "Battery Commander (BC)" "Sleep Mode: Travel FAILED (pmset error - see actions.log)"
            release
            exit 1
        fi
        atomic_write "$DASH/.sleep_mode" "travel"
        # Travel's profile never touches disablesleep: if the
        # battery stay-awake toggle was on, its battery-scope 1 is
        # the only possible source — clear it with the marker.
        if [ -f "$DASH/.stay_awake_batt" ]; then
            sudo -n /usr/bin/pmset -b disablesleep 0 2>/dev/null || true
        fi
        _stay_batt_superseded
        log "sleep_mode: travel"
        notify "Battery Commander (BC)" "Sleep Mode: Travel"
        release
        ;;

    sleep_mode_long)
        BUTTON=$(osascript << 'AS'
try
    display dialog "⚠️  Enable Long Day?

Keeps the Mac ready on both battery and AC.

Impact:
• Standby delayed to 1h on battery, 4h on AC
• Hibernates after 1h on battery, 2h on AC
• Drains battery more while active

Best for: long work sessions, keeping the Mac ready." buttons {"Cancel", "Enable"} default button "Cancel" with title "Sleep Mode" with icon caution
    return button returned of result
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$BUTTON" != "Enable" ] && { exit 0; }
        
        acquire
        rm -f "$DASH/.sleep_override_ac" "$DASH/.sleep_override_lid" "$DASH/.sleep_override_batt"
        SM_FAIL=0
        $DASH/power_saver.sh apply-delays long || SM_FAIL=1
        sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || SM_FAIL=1
        if [ "$SM_FAIL" -ne 0 ]; then
            log "sleep_mode: long FAILED (pmset/power_saver error) - .sleep_mode NOT updated"
            notify "Battery Commander (BC)" "Sleep Mode: Long Day FAILED (pmset error - see actions.log)"
            release
            exit 1
        fi
        atomic_write "$DASH/.sleep_mode" "long"
        # Same stay-awake-batt clearing as Travel (see above).
        if [ -f "$DASH/.stay_awake_batt" ]; then
            sudo -n /usr/bin/pmset -b disablesleep 0 2>/dev/null || true
        fi
        _stay_batt_superseded
        log "sleep_mode: long"
        notify "Battery Commander (BC)" "Sleep Mode: Long Day"
        release
        ;;
    

    reapply_limit)
        # Manually reapply the saved limit (called after daemon restart).
        # BC: lock + verify (the old version had neither) + fresh config
        # read (KEY=value, never source). Defaults 86/85 (§3.5).
        acquire
        read_config
        LAST_UPPER="${LAST_UPPER:-86}"
        LAST_LOWER="${LAST_LOWER:-85}"
        if bc_apply_limit "$LAST_UPPER" "$LAST_LOWER"; then
            log "reapply_limit: $LAST_UPPER/$LAST_LOWER"
            notify "Battery Commander (BC)" "Limit re-applied: $LAST_UPPER/$LAST_LOWER"
        else
            log "reapply_limit: FAILED ($LAST_UPPER/$LAST_LOWER)"
            notify "Battery Commander (BC)" "Limit re-apply failed"
        fi
        release
        ;;
    
    reset_defaults)
        # Dialog FIRST (no lock — W1.7; user think time must not hold .op.lock).
        BUTTON=$(osascript << 'AS'
try
    set d to display dialog "Reset all Battery Commander (BC) settings to defaults?\n
\n
This will:\n
  • Charge limits: 86% / 85%\n
  • Sailing Mode: OFF (gap 1)\n
  • Power Mode: Balanced (18/10/15)\n
  • Clear saved dialog inputs (.last_inputs)\n
  • Kill any running discharge/calibration\n
\n
This action cannot be undone." buttons {"Cancel", "Reset"} default button "Cancel" with title "Battery Commander (BC) - Reset to Defaults" with icon caution
    return button returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$BUTTON" = "__CANCELLED__" ] && exit 0

        if [ "$BUTTON" = "Reset" ]; then
            acquire
            sd_session_invalidate
            # BC kill helpers clear session markers (no pkill of a root daemon).
            kill_discharge 2>/dev/null
            kill_charge 2>/dev/null
            kill_calibrate 2>/dev/null

            # Reset config to defaults (86/85, canonical: Sailing OFF,
            # gap 1) via the BC backend (verify-first, atomic write).
            SAILING=false
            SAIL_GAP=1
            RESET_LIMIT_OK=1
            bc_apply_limit 86 85 || { RESET_LIMIT_OK=0; log "reset_defaults: limit apply failed"; }

            # Reset Power Mode to Balanced
            $DASH/power_mode.sh balanced >> "$LOG" 2>&1

            # Clear saved input history (reset dialogs to defaults)
            rm -f "$DASH/.last_inputs" 2>/dev/null

            # Remove stale state files
            rm -f "$DASH/.sd_watch" 2>/dev/null
            rm -f "$DASH/.daemon_fail_count" 2>/dev/null

            log "reset_defaults: 86/85, Sailing OFF gap 1, Power Mode Balanced"
            if [ "$RESET_LIMIT_OK" = "1" ]; then
                notify "Battery Commander (BC)" "Reset to Defaults — done"
            else
                notify "Battery Commander (BC)" "Reset partial — limit apply failed, check actions.log"
            fi
            # Only the Reset path clears the session mode: an empty or
            # cancelled dialog must not silently idle an active session.
            echo "idle" > "$DASH/.active_mode"
            release
        fi
        ;;
    kill_charge)    kill_charge ;;
    kill_discharge) kill_discharge ;;
    kill_calibrate) kill_calibrate ;;

    stop_now)
        log "stop_now"
        acquire; ensure_clean
        intent_apply hold_current
        release
        ;;

    remove_limit_hold)
        log "remove_limit_hold"
        acquire; ensure_clean
        intent_apply clear_hold
        release
        ;;

    disable_limit)
        acquire; ensure_clean
        log "disable all"
        intent_apply disable_limit
        release
        ;;

    charge_full)
        acquire; ensure_clean
        log "charge_full: START"
        intent_apply charge_full
        release
        ;;


    charge_to_upper)
        acquire; ensure_clean
        log "charge_to_upper: START"
        if [ -f "$DASH/.user_shutdown" ]; then
            notify "Battery Commander (BC)" "Charge to upper cancelled (shutdown)"
        elif [ "$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')" = "discharge" ] || [ "$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')" = "charge_full" ] || [ "$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')" = "calibration" ]; then
            notify "Battery Commander (BC)" "Charge to upper cancelled (active session)"
        else
            read_config
            U=${LAST_UPPER:-86}
            L=${LAST_LOWER:-85}
            # BC: the "charge to UPPER" session is just the configured limit
            # enforced by bc-limit (BCLM=10 at UPPER). Reapply it and verify;
            # no `battopt charge`, no charge_upper_watcher (deleted, §2.8).
            # A stale .charge_upper_token (from the deleted watcher) is removed.
            rm -f "$DASH/.charge_upper_token" 2>/dev/null || true
            if ! _bc_verify "$U" "$L"; then
                bc_apply_limit "$U" "$L" || true
            fi
            if ! _bc_verify "$U" "$L"; then
                notify "Battery Commander (BC)" "Charge to upper cancelled (verify failed for $U/$L)"
            elif ! pmset -g batt 2>/dev/null | head -1 | grep -q "AC Power"; then
                notify "Battery Commander (BC)" "Charge to upper cancelled (AC not attached)"
            else
                CUR=$(get_pct)
                if [ -z "$CUR" ]; then
                    notify "Battery Commander (BC)" "Charge to upper cancelled (no battery reading)"
                elif [ "$CUR" -ge "$U" ]; then
                    notify "Battery Commander (BC)" "Charge to upper not needed (CUR=$CUR, UPPER=$U)"
                else
                    notify "Battery Commander (BC)" "Charging to $U% (enforcer active)"
                fi
            fi
        fi
        release
        ;;

    smart_discharge)
        # Discharge build (2026-11-13, design §7): Smart Discharge is a
        # start/cancel TOGGLE for a discharge session. Starting writes
        # ONLY the session file — dispatch never writes BCLM and never
        # changes the limit config for a session. bc-limit (the sole
        # BCLM writer) honours a valid session by suppressing the resume
        # write; the watchdog monitor confirms entry (second-signal
        # rule), supervises the session, and ends it. Shadow mode: while
        # $DASH/.discharge_shadow exists, the session file is the
        # .shadow variant and has NO effect on charging (log only).
        DS_SHADOW=0
        DS_FILE="$DASH/.discharge_session"
        if [ -f "$DASH/.discharge_shadow" ]; then
            DS_SHADOW=1
            DS_FILE="$DASH/.discharge_session.shadow"
        fi
        DS_TAG="REAL"; [ "$DS_SHADOW" = "1" ] && DS_TAG="SHADOW"
        ds_log() {
            printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$DS_TAG" "$1" >> "$DASH/discharge.log" 2>/dev/null
        }

        # Calibrate build (2026-11-14): a MODE=calibrate session
        # belongs to a calibration run — this toggle must never
        # offer to cancel it or start over it.
        if [ -f "$DASH/.discharge_session" ] \
            && grep -q '^MODE=calibrate' "$DASH/.discharge_session" 2>/dev/null; then
            notify "Battery Commander (BC)" "A calibration run is using the discharge session — manage it from the Calibration menu"
            log "smart_discharge: refused — calibration session active"
            exit 0
        fi

        if [ -f "$DS_FILE" ]; then
            # --- CANCEL path: a start request during a session cancels it
            # (design §5.1 rule 1 + §7; user cancel never imposes a
            # cooldown — discharge design rule 9). ---
            DS_TGT=$(grep '^TARGET=' "$DS_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
            case "$DS_TGT" in ''|*[!0-9]*) DS_TGT="?" ;; esac
            CONFIRM=$(osascript <<AS
try
    set d to display dialog "Smart Discharge session is ACTIVE\n\nTarget: ${DS_TGT}%\n\nCancel this session? Charging control returns to the normal limit rules immediately." buttons {"Keep Session", "Cancel Session"} default button "Keep Session" with title "Battery Commander (BC)"
    return button returned of d
on error
    return "__CANCELLED__"
end try
AS
)
            if [ "$CONFIRM" = "Cancel Session" ]; then
                acquire
                rm -f "$DS_FILE"
                # A cancel is final: no sleep-resume intent may
                # survive it (real sessions only — a shadow cancel
                # must not touch real intent).
                [ "$DS_SHADOW" = "0" ] && sd_intent_clear "dispatch.cancel"
                ds_log "SESSION_CANCEL_REQUESTED target=${DS_TGT} by=dispatch (user toggle)"
                log "smart_discharge: session cancelled by user (target=${DS_TGT})"
                release
                # Engagement-path latency (final cleanup
                # 2026-11-18): a real cancel waits on the watchdog
                # (episode close-out) + daemon (disengage / hold
                # restore) cadences — kick both now.
                if [ "$DS_SHADOW" = "0" ]; then
                    _bc_kick_watchdog
                    _bc_kick_daemon
                fi
                if [ "$DS_SHADOW" = "1" ]; then
                    notify "Battery Commander (BC)" "Shadow discharge session cancelled"
                else
                    notify "Battery Commander (BC)" "Discharge session cancelled — normal limit rules resumed"
                fi
            fi
            exit 0
        fi

        # --- START path ---
        # Flip-abort cooldown (written by the watchdog monitor).
        if [ -f "$DASH/.discharge_cooldown" ]; then
            CD_UNTIL=$(grep '^UNTIL=' "$DASH/.discharge_cooldown" 2>/dev/null | tail -1 | cut -d= -f2)
            case "$CD_UNTIL" in ''|*[!0-9]*) CD_UNTIL=0 ;; esac
            if [ "$(date +%s)" -lt "$CD_UNTIL" ]; then
                CD_HUMAN=$(date -r "$CD_UNTIL" '+%H:%M' 2>/dev/null || echo "later")
                notify "Battery Commander (BC)" "Discharge unavailable — cooldown after an AC-flip abort (until ${CD_HUMAN})"
                log "smart_discharge: start refused (flip cooldown until $CD_UNTIL)"
                exit 0
            fi
        fi

        CUR=$(get_pct); [ -z "$CUR" ] && exit 1
        read_config
        DEF_TGT="${LAST_LOWER:-85}"
        # Default target = the configured LOWER limit (decision adopted
        # 2026-11-13), unless that is not below the current level.
        if [ "$DEF_TGT" -ge "$CUR" ]; then
            DEF_TGT=$((CUR - 5))
            [ "$DEF_TGT" -lt 20 ] && DEF_TGT=20
        fi
        if [ "$DS_SHADOW" = "1" ]; then
            DS_INTRO="SHADOW MODE: this session is logged only and has NO effect on charging."
        else
            DS_INTRO="The battery drains to the target. On AC, discharge mode drains the pack while plugged in (charging stays inhibited); on battery it drains naturally."
        fi
        T=$(osascript <<AS
try
    set d to display dialog "Smart Discharge - Target\n\nCurrent: ${CUR}%\n${DS_INTRO}\n\nTarget must be LOWER than ${CUR}%\nDefault (lower limit): ${DEF_TGT}%\n\nTarget battery level (20-99):" default answer "${DEF_TGT}" buttons {"Cancel", "Start"} default button "Start" with title "Battery Commander (BC)"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$T" = "__CANCELLED__" ] && { exit 0; }
        if ! validate_int "$T" 20 99; then
            notify "Battery Commander (BC)" "Invalid target (20-99) — cancelled"
            exit 0
        fi
        save_last_input SD_TARGET "$T"
        if [ "$T" -ge "$CUR" ]; then
            notify "Battery Commander (BC)" "Target ${T}% must be < current ${CUR}%"
            exit 0
        fi

        acquire
        # Re-check under the lock: no session may have appeared, and the
        # battery may have moved while the user was deciding.
        if [ -f "$DS_FILE" ]; then
            release
            notify "Battery Commander (BC)" "A discharge session is already active"
            exit 0
        fi
        CUR=$(get_pct); [ -z "$CUR" ] && { release; exit 1; }
        if [ "$T" -ge "$CUR" ]; then
            notify "Battery Commander (BC)" "Target ${T}% must be < current ${CUR}%"
            release
            exit 0
        fi
        DS_TMP="$DS_FILE.tmp.$$"
        {
            echo "MODE=user"
            echo "TARGET=$T"
            echo "STARTED=$(date +%s)"
            echo "STARTER=dispatch"
        } > "$DS_TMP" && mv "$DS_TMP" "$DS_FILE"
        # A manual start supersedes any stored sleep-resume intent.
        [ "$DS_SHADOW" = "0" ] && sd_intent_clear "dispatch.manual-start"
        DS_EXT="No"
        ioreg -rn AppleSmartBattery 2>/dev/null | grep -q '"ExternalConnected" = Yes' && DS_EXT="Yes"
        ds_log "SESSION_START_REQUESTED target=${T} cur=${CUR} ext=${DS_EXT} starter=dispatch"
        log "smart_discharge: session started (target=${T}, shadow=${DS_SHADOW}, ext=${DS_EXT})"
        release
        # Engagement-path latency (final cleanup 2026-11-18): kick
        # the watchdog->daemon chain so the session arms and
        # engages in seconds instead of the up-to-~84 s of cadence
        # waits measured tonight (20:16:32 -> 20:17:56).
        if [ "$DS_SHADOW" = "0" ]; then
            _bc_kick_session_chain "$(grep '^STARTED=' "$DS_FILE" 2>/dev/null | tail -1 | cut -d= -f2)"
        fi
        if [ "$DS_SHADOW" = "1" ]; then
            if [ "$DS_EXT" = "Yes" ]; then
                notify "Battery Commander (BC)" "Shadow discharge session started (log only) — parked on AC; would drain on battery"
            else
                notify "Battery Commander (BC)" "Shadow discharge session started (log only) — would drain to ${T}%"
            fi
        elif [ "$DS_EXT" = "Yes" ]; then
            notify "Battery Commander (BC)" "Discharge session started — parked on AC; unplug to drain to ${T}%"
        else
            notify "Battery Commander (BC)" "Discharge session started — draining to ${T}%"
        fi
        ;;

    limit_custom)
        CUR=$(get_pct)
        log "limit_custom: input requested"
        DEF=$(get_last_input LIMIT_CUSTOM "")
        [ -z "$DEF" ] && DEF="${LAST_UPPER}/${LAST_LOWER}"

        R=$(osascript <<AS
try
    set d to display dialog "Charge Limit

Current battery: ${CUR}%

Format: 85/75  (upper/lower)

Sailing: $([ "$SAILING" = "true" ] && echo ON || echo OFF)

Last saved: ${DEF}" default answer "$DEF" buttons {"Cancel", "OK"} default button "OK" with title "Battery Commander (BC) - Charge Limit"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$R" = "__CANCELLED__" ] && { exit 0; }
        U=$(echo "$R" | cut -d'/' -f1 | tr -d ' ')
        L=$(echo "$R" | cut -d'/' -f2 | tr -d ' ')
        { [ -z "$U" ] || [ -z "$L" ]; } && { notify "Battery Commander (BC)" "Empty input"; exit 0; }
        validate_int "$U" 15 100 || { notify "Battery Commander (BC)" "Upper must be 15-100"; exit 0; }
        validate_int "$L" 15 99 || { notify "Battery Commander (BC)" "Lower must be 15-99"; exit 0; }
        [ "$L" -ge "$U" ] && { notify "Battery Commander (BC)" "Lower must be below upper"; exit 0; }

        # === STEP 2: Mode ===
        MODE=$(osascript <<AS
try
    set d to display dialog "Mode after reaching limit

After reaching ${U}%:
Hold = freeze at ${U}% only
Sailing = oscillate between ${U}% and (${U} - gap)%" buttons {"Cancel","Hold","Sailing"} default button "Sailing" with title "Battery Commander (BC)"
    return button returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$MODE" = "__CANCELLED__" ] && { exit 0; }
        [ "$MODE" = "Cancel" ] && { exit 0; }

        GAP=10
        if [ "$MODE" = "Sailing" ]; then
            GSEL=$(osascript <<AS
try
    set opts to {"5","10","15","30","Custom"}
    set sel to choose from list opts with prompt "Sail gap in %:" default items {"10"} with title "Battery Commander (BC) - Sail Gap" OK button name "Select" cancel button name "Cancel"
    if sel is false then
        return "__CANCELLED__"
    else
        return item 1 of sel
    end if
on error
    return "__CANCELLED__"
end try
AS
)
            [ "$GSEL" = "__CANCELLED__" ] && { exit 0; }
            if [ "$GSEL" = "Custom" ]; then
                GSEL=$(osascript <<AS
try
    set d to display dialog "Custom sail gap (5-30):" default answer "$(get_last_input SAIL_GAP_CUSTOM 10)" buttons {"Cancel", "OK"} default button "OK" with title "Battery Commander (BC)"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
                [ "$GSEL" = "__CANCELLED__" ] && { exit 0; }
                validate_int "$GSEL" 5 30 || { notify "Battery Commander (BC)" "Invalid gap (5-30)"; exit 0; }
                save_last_input SAIL_GAP_CUSTOM "$GSEL"
            fi
            validate_int "$GSEL" 5 30 || { notify "Battery Commander (BC)" "Invalid gap"; exit 0; }
            GAP="$GSEL"
            save_last_input SD_SAIL_GAP "$GAP"
        fi

        save_last_input LIMIT_CUSTOM "$U/$L"

        # Lower limit computed here; the config is written by intent_apply (bc_apply_limit).
        if [ "$MODE" = "Hold" ]; then
            SAILING=false; SAIL_GAP=1
            LAST_LOWER=$((U - 1)); [ "$LAST_LOWER" -lt 15 ] && LAST_LOWER=15
        else
            SAILING=true; SAIL_GAP="$GAP"
            LAST_LOWER=$((U - GAP)); [ "$LAST_LOWER" -lt 15 ] && LAST_LOWER=15
        fi
        LAST_UPPER="$U"
        acquire
        intent_apply limit "$U" "$LAST_LOWER" "$MODE" "$GAP"
        release
        ;;

    sail_on)
        acquire; ensure_clean
        intent_apply sail_on
        release
        ;;

    sail_off)
        acquire; ensure_clean
        intent_apply sail_off
        release
        ;;

    sail_gap_set)
        G="$2"
        [ "$G" = "custom" ] && G=$(osascript <<AS
try
    set d to display dialog "Gap (5-30):" default answer "$(get_last_input GAP_CUSTOM 10)" buttons {"Cancel", "OK"} default button "OK" with title "Battery Commander (BC)"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$G" = "__CANCELLED__" ] && { exit 0; }
        [ -z "$G" ] && { exit 0; }
        validate_int "$G" 5 30 || { notify "Battery Commander (BC)" "Invalid gap (5-30)"; exit 0; }
        save_last_input GAP_CUSTOM "$G"
        acquire
        intent_apply sail_gap "$G"
        release
        ;;

    calibrate)
        # Calibrate build (2026-11-14, calibrate-design.md): the
        # Calibration start/cancel TOGGLE. With no run file it runs
        # the L0 preflight (auto-profile by battery health) and, on
        # the user's confirmation, creates the run file — the
        # watchdog run supervisor owns the run from there. With a
        # run file it is the cancel path. This action never writes
        # BCLM and never changes the config itself: the supervisor
        # applies the temporary 100/99 through bc_apply_limit and
        # restores the user's limit at close-out. No ensure_clean:
        # sd_session_invalidate would eat the run's own segment.
        CAL_RUN_FILE="$DASH/.calibration_run"
        if [ -f "$CAL_RUN_FILE" ]; then
            # --- CANCEL path ---
            CAL_LEG=$(grep '^LEG=' "$CAL_RUN_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
            CAL_CUR=$(get_pct)
            CONFIRM=$(osascript <<AS
try
    set d to display dialog "Calibration is RUNNING (leg ${CAL_LEG:-?})\n\nCurrent battery: ${CAL_CUR:-?}%\n\nCancel the run? Battery Commander restores your normal limit and power settings within a minute." buttons {"Keep Running", "Cancel Calibration"} default button "Keep Running" with title "Battery Commander (BC)"
    return button returned of d
on error
    return "__CANCELLED__"
end try
AS
)
            if [ "$CONFIRM" = "Cancel Calibration" ]; then
                kill_calibrate
                printf '[%s] RUN_CANCEL_REQUESTED by=dispatch leg=%s\n' \
                    "$(date '+%Y-%m-%d %H:%M:%S')" "${CAL_LEG:-?}" >> "$DASH/calibration.log" 2>/dev/null
                log "calibrate: run cancel requested (leg=${CAL_LEG:-?})"
            fi
            exit 0
        fi

        # --- START path: preflight refusals (design rules 4 + 10) ---
        if [ -f "$DASH/.discharge_session" ]; then
            notify "Battery Commander (BC)" "A discharge session is active — calibration cannot start until it ends"
            log "calibrate: start refused (discharge session active)"
            exit 0
        fi
        if [ -f "$DASH/.apg_paused" ]; then
            # Temp gate (2026-11-15, owner's rule): an APG pause
            # blocks the start only when it is THERMAL (battery temp
            # >= 38 C, the APG yellow threshold) or the temp is
            # unreadable (cannot verify = refuse). A load-only pause
            # (temp < 38 C) never blocks a user-initiated start.
            CAL_TEMP=$(bc_status_value "TempBatteryPack" 2>/dev/null | tr -dc '0-9.')
            CAL_TEMP_INT="${CAL_TEMP%.*}"
            case "$CAL_TEMP_INT" in ''|*[!0-9]*) CAL_TEMP_INT="" ;; esac
            if [ -z "$CAL_TEMP_INT" ] || [ "$CAL_TEMP_INT" -ge 38 ]; then
                notify "Battery Commander (BC)" "Battery too hot (APG thermal pause) — calibration can start when it cools below 38°C"
                log "calibrate: start refused (APG thermal pause, temp=${CAL_TEMP:-unknown})"
                exit 0
            fi
            log "calibrate: APG pause is load-only (temp=${CAL_TEMP}) — start allowed"
        fi
        # The supervisor lives in the watchdog: never start a run
        # it would not pick up (heartbeat older than 180 s).
        CAL_HB_OK=0
        if [ -f "$DASH/.enforce_hb" ]; then
            CAL_HB=$(cat "$DASH/.enforce_hb" 2>/dev/null | tr -d '[:space:]')
            case "$CAL_HB" in ''|*[!0-9]*) CAL_HB=0 ;; esac
            CAL_HB_AGE=$(( $(date +%s) - CAL_HB ))
            [ "$CAL_HB_AGE" -ge 0 ] && [ "$CAL_HB_AGE" -le 180 ] && CAL_HB_OK=1
        fi
        if [ "$CAL_HB_OK" != "1" ]; then
            notify "Battery Commander (BC)" "The BC watchdog is not running — calibration cannot start"
            log "calibrate: start refused (watchdog heartbeat stale)"
            exit 0
        fi
        CAL_PROF=$(calibration_profile) || {
            notify "Battery Commander (BC)" "Battery health data unreadable — calibration cannot start"
            log "calibrate: start refused (profile unreadable)"
            exit 0
        }
        set -- $CAL_PROF
        CAL_FLOOR=$1; CAL_ABS=$2; CAL_SUP=$3; CAL_BAND=$4; CAL_HX=$5; CAL_FCC=$6; CAL_DES=$7; CAL_CYC=$8
        CAL_CUR=$(get_pct)
        [ -z "$CAL_CUR" ] && { log "calibrate: no pct reading — start aborted"; exit 1; }
        read_config
        CAL_HDISP="$(( CAL_HX / 10 )).$(( CAL_HX % 10 ))"
        if [ "$CAL_SUP" -gt 0 ]; then
            CAL_SUPLINE="Stay nearby once the battery falls below ${CAL_SUP}%."
        else
            CAL_SUPLINE="No supervision line for this battery's health band."
        fi
        CONFIRM=$(osascript <<AS
try
    set d to display dialog "Battery Calibration — full cycle\n\nBattery health: ${CAL_HDISP}% (${CAL_FCC}/${CAL_DES} mAh, ${CAL_CYC} cycles)\nAuto-profile: drain floor ${CAL_FLOOR}%, emergency stop ${CAL_ABS}%\nYour limit (${LAST_UPPER}%/${LAST_LOWER}%) is restored automatically at the end.\n\nPlan: charge to 100% → rest 1 h → unplug and work normally while it drains → plug in at the floor → rest → recharge to 100%.\n${CAL_SUPLINE}\nTakes most of a day. No restart; nothing closes." buttons {"Cancel", "Start Calibration"} default button "Start Calibration" with title "Battery Commander (BC)"
    return button returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        if [ "$CONFIRM" != "Start Calibration" ]; then
            log "calibrate: start declined at dialog"
            exit 0
        fi

        acquire
        # Re-check under the lock: no run/session may have appeared
        # while the user was reading the dialog.
        if [ -f "$CAL_RUN_FILE" ] || [ -f "$DASH/.discharge_session" ]; then
            release
            notify "Battery Commander (BC)" "Calibration state changed — start cancelled"
            exit 0
        fi
        read_config
        CAL_NOW=$(date +%s)
        CAL_RID="$(date '+%Y%m%d-%H%M%S')-$$"
        CAL_TMP="$CAL_RUN_FILE.tmp.$$"
        {
            echo "RUN_ID=$CAL_RID"
            echo "LEG=L0"
            echo "PROFILE=$CAL_BAND"
            echo "FLOOR=$CAL_FLOOR"
            echo "ABS_FLOOR=$CAL_ABS"
            echo "SUPERVISION=$CAL_SUP"
            echo "HEALTH_X10=$CAL_HX"
            echo "CYCLES=$CAL_CYC"
            echo "BASE_MAXCAP=$CAL_FCC"
            echo "BASE_UPPER=$LAST_UPPER"
            echo "BASE_LOWER=$LAST_LOWER"
            echo "STARTED=$CAL_NOW"
            echo "HEARTBEAT=$CAL_NOW"
            echo "CONFIG_PHASE=base"
            echo "EXPECT_U=$LAST_UPPER"
            echo "EXPECT_L=$LAST_LOWER"
            echo "LEG_STARTED=$CAL_NOW"
        } > "$CAL_TMP" && mv "$CAL_TMP" "$CAL_RUN_FILE"
        printf 'calibration\n' > "$DASH/.active_mode.tmp.$$" \
            && mv "$DASH/.active_mode.tmp.$$" "$DASH/.active_mode"
        printf '[%s] RUN_CREATED run=%s profile=%s floor=%s abs_floor=%s supervision=%s health_x10=%s fcc=%s design=%s cycles=%s base=%s/%s pct=%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$CAL_RID" "$CAL_BAND" "$CAL_FLOOR" \
            "$CAL_ABS" "$CAL_SUP" "$CAL_HX" "$CAL_FCC" "$CAL_DES" "$CAL_CYC" \
            "$LAST_UPPER" "$LAST_LOWER" "$CAL_CUR" >> "$DASH/calibration.log" 2>/dev/null
        log "calibrate: run created ($CAL_RID, profile=$CAL_BAND floor=$CAL_FLOOR)"
        release
        # Engagement-path latency (final cleanup 2026-11-18): the
        # watchdog supervisor owns the run from here — kick it so
        # the first leg starts in seconds, not on the 60 s cadence.
        _bc_kick_watchdog
        notify "Battery Commander (BC)" "Calibration started — charging to 100% first (floor ${CAL_FLOOR}%, profile ${CAL_BAND})"
        ;;

    calibrate_resume)
        # Calibrate build: the user's explicit resume tap at a
        # checkpoint. Writes the marker only; the supervisor
        # re-checks every gate (120 s post-wake window, APG green,
        # pct >= floor+15, marker fresh) before the next segment.
        if [ ! -f "$DASH/.calibration_run" ]; then
            notify "Battery Commander (BC)" "No calibration run is active"
            exit 0
        fi
        if grep -q '^WAITING=1' "$DASH/.calibration_run" 2>/dev/null; then
            echo "$(date +%s)" > "$DASH/.calibration_resume_request"
            log "calibrate_resume: resume requested"
            notify "Battery Commander (BC)" "Calibration resume requested — safety checks run on the next watchdog tick"
            # Engagement-path latency (final cleanup 2026-11-18):
            # make that tick happen now.
            _bc_kick_watchdog
        else
            log "calibrate_resume: run not waiting at a checkpoint"
            notify "Battery Commander (BC)" "Calibration is not waiting at a checkpoint"
        fi
        ;;

    calibration_apply_limit)
        # INTERNAL (run-supervisor only): apply limits through the
        # single primitive bc_apply_limit and exit with its result.
        # No dialogs, no ensure_clean (it would eat the run's own
        # discharge segment via sd_session_invalidate).
        acquire
        read_config
        bc_apply_limit "$2" "$3"
        CAL_RC=$?
        release
        exit $CAL_RC
        ;;

    calibration_posture_on)
        # INTERNAL (run-supervisor only): assert the L2 anti-sleep
        # posture — system sleep OFF on battery scope only (display
        # sleep untouched; standby/hibernate untouched, design
        # section 5.5). Records the previous value for the verified
        # restore. Exit 0 only when the live value reads back 0.
        acquire
        CAL_PS="$DASH/.calibration_posture_state"
        if [ -f "$CAL_PS" ]; then
            CAL_CUR_SLEEP=$(_pmset_battery_sleep)
            if [ "$CAL_CUR_SLEEP" = "0" ]; then release; exit 0; fi
            log "calibration_posture_on: value drifted (sleep=$CAL_CUR_SLEEP) — re-asserting"
        else
            CAL_PREV=$(_pmset_battery_sleep)
            if ! validate_int "$CAL_PREV" 0 999; then
                log "calibration_posture_on: battery sleep unreadable — not asserting"
                release; exit 1
            fi
            printf 'PREV_SLEEP_B=%s\nASSERTED=%s\n' "$CAL_PREV" "$(date +%s)" \
                > "$CAL_PS.tmp.$$" && mv "$CAL_PS.tmp.$$" "$CAL_PS"
            log "calibration_posture_on: recorded previous battery sleep=${CAL_PREV} min"
        fi
        if ! sudo -n "$PMSET_BIN" -b sleep 0 >/dev/null 2>&1; then
            log "calibration_posture_on: pmset failed"
            release; exit 1
        fi
        CAL_CUR_SLEEP=$(_pmset_battery_sleep)
        if [ "$CAL_CUR_SLEEP" = "0" ]; then
            log "calibration_posture_on: asserted (battery sleep off, verified)"
            release; exit 0
        fi
        log "calibration_posture_on: verify failed (sleep=$CAL_CUR_SLEEP)"
        release; exit 1
        ;;

    calibration_posture_off)
        # INTERNAL (run-supervisor only): restore the battery-scope
        # system-sleep value recorded by calibration_posture_on,
        # verified by re-reading. Exit 0 also when nothing was
        # asserted. On any failure the state file is KEPT so the
        # restore can be retried and the failure stays visible.
        acquire
        CAL_PS="$DASH/.calibration_posture_state"
        if [ ! -f "$CAL_PS" ]; then release; exit 0; fi
        CAL_PREV=$(grep '^PREV_SLEEP_B=' "$CAL_PS" 2>/dev/null | tail -1 | cut -d= -f2)
        if ! validate_int "$CAL_PREV" 0 999; then
            log "calibration_posture_off: recorded value invalid (${CAL_PREV:-?}) — state kept"
            release; exit 1
        fi
        if ! sudo -n "$PMSET_BIN" -b sleep "$CAL_PREV" >/dev/null 2>&1; then
            log "calibration_posture_off: pmset failed"
            release; exit 1
        fi
        CAL_CUR_SLEEP=$(_pmset_battery_sleep)
        if [ "$CAL_CUR_SLEEP" = "$CAL_PREV" ]; then
            rm -f "$CAL_PS"
            log "calibration_posture_off: restored battery sleep=${CAL_PREV} min (verified)"
            release; exit 0
        fi
        log "calibration_posture_off: verify failed (sleep=$CAL_CUR_SLEEP want $CAL_PREV)"
        release; exit 1
        ;;

    cal_stop) acquire; log "cal_stop"; intent_apply calibration_stop; release ;;

    sched_on)  log "sched_on: not supported in BC yet";  notify "Battery Commander (BC)" "Schedule not supported in BC yet" ;;
    sched_off) log "sched_off: not supported in BC yet"; notify "Battery Commander (BC)" "Schedule not supported in BC yet" ;;
    clam0) log "clam0: not supported in BC yet"; notify "Battery Commander (BC)" "Clamshell not supported in BC yet" ;;
    clam1) log "clam1: not supported in BC yet"; notify "Battery Commander (BC)" "Clamshell not supported in BC yet" ;;
    clam2) log "clam2: not supported in BC yet"; notify "Battery Commander (BC)" "Clamshell not supported in BC yet" ;;

    shutdown)
        # --- SAFETY GATE (2026-11-17): this action is a full teardown ---
        # It stops every agent, releases the limit (config 100/99) and
        # purges state. It must never run from a blind or stale call --
        # a leftover process once invoked it unguarded on quit.
        # Deliberate arming path (human, manual; no UI does this today,
        # and that is intended):
        #   date +%s > "$DASH/.fullstop_armed"
        #   dispatch.sh shutdown --force        (within 120 s of arming)
        # The token is single-use: a passing gate consumes it BEFORE any
        # teardown step. No token / stale (>120 s) / unreadable token ->
        # log a refusal and exit 0 having changed nothing.
        # Probe: BC_FULLSTOP_PROBE=1 + a fresh token logs GATE PASS and
        # exits 0 before any teardown (safe end-to-end gate test).
        _fs_token="$DASH/.fullstop_armed"
        _fs_ts=$(cat "$_fs_token" 2>/dev/null | tr -dc '0-9')
        _fs_age=$(( $(date +%s) - ${_fs_ts:-0} ))
        if [ -z "$_fs_ts" ] || [ "$_fs_age" -lt 0 ] || [ "$_fs_age" -gt 120 ]; then
            log "shutdown: REFUSED — not armed (gate)"
            exit 0
        fi
        rm -f "$_fs_token"
        if [ "${BC_FULLSTOP_PROBE:-0}" = "1" ]; then
            log "shutdown: GATE PASS (probe — no teardown)"
            exit 0
        fi
        acquire
        guard_lock || { log "shutdown: guard_lock failed"; notify "Battery Commander (BC)" "Shutdown incomplete - check actions.log"; release; exit 1; }
        if [ "$2" != "--force" ]; then
            CONFIRM=$(osascript <<'AS'
try
    set d to display dialog "Shut Down Battery Commander?\n\nThis will stop all agents, release the battery limit,\nand remove the menu bar icon." buttons {"Cancel", "Shut Down"} default button "Shut Down" with icon caution with title "Battery Commander (BC) - Shutdown"
    return button returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$CONFIRM" != "Shut Down" ] && { guard_unlock 2>/dev/null || true; release; exit 0; }
        fi
        log "shutdown: START"
        START_TS=$(date +%s)

        SESSION_MODE=$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')
        [ -z "$SESSION_MODE" ] && SESSION_MODE="idle"

        atomic_write "$DASH/.last_session_mode" "LAST_UPPER=$LAST_UPPER
LAST_LOWER=$LAST_LOWER
ACTIVE_MODE=$SESSION_MODE
"

        # 1. Set flag FIRST
        touch "$DASH/.user_shutdown"

        # 1d. Invalidate discharge session under guard_lock BEFORE kills
        # .last_session_mode was already saved above, so writing idle here does not lose it.
        sd_session_invalidate 2>/dev/null || true
        rm -f "$DASH/.active_token" 2>/dev/null || true
        printf '%s\n' "idle" > "$DASH/.active_mode" 2>/dev/null || true
        log "shutdown: session invalidated before kills"

        # 1b. Grace period
        sleep 2

        # 1c. Kill Battery Commander (BC) app and remove from Login Items
        # App + login item are BatteryCommander (renamed 2026-11-10).
        pkill -f "/Applications/BatteryCommander.app" 2>/dev/null || true
        osascript -e 'tell application "System Events" to try' \
                -e 'delete login item "BatteryCommander"' \
                -e 'end try' 2>/dev/null || true

        # 2. Stop in-flight BC ops (clear session markers; no battopt to stop).
        # The BC enforcer is a LaunchDaemon, not a process to kill from the UI.
        rm -f "$DASH/.charge_target" "$DASH/.sd_session" 2>/dev/null || true
        log "shutdown: in-flight BC ops cleared"

        # 2b. Kill the force_reset watchdog if one is running (our own script).
        pkill -9 -f "force_reset" 2>/dev/null || true
        sleep 1

        # 3. Unload user agents FIRST + kill residual watchdogs.
        # Agent labels are com.batterycommander.* (renamed 2026-11-11).
        for plist in "$HOME/Library/LaunchAgents/"com.batterycommander.*.plist; do
            [ -f "$plist" ] || continue
            launchctl unload -w "$plist" 2>/dev/null
        done
        pkill -9 -f "$DASH/bc-watchdog.sh" 2>/dev/null || true
        pkill -9 -f "$DASH/self_healing.sh" 2>/dev/null || true
        pkill -9 -f "sd_watcher" 2>/dev/null || true
        log "shutdown: agents unloaded (bc-watchdog/self-healing/sd_watcher killed)"

        # 4. Release the limit via the BC backend: write 100/99 to the
        # canonical config. The enforcer (bc-limit, root LaunchDaemon)
        # applies BCLM=100 on its next 60 s run. There is no battopt
        # daemon to release through and no SMC "upper limit" to poll —
        # the release is async by design (config write now, BCLM=100
        # within 60 s). The enforcer is NOT loaded here (Phase C gate).
        log "shutdown: releasing limit via BC config (100/99)"
        SAILING=false
        SAIL_GAP=1
        if bc_apply_limit 100 99; then
            log "shutdown: limit released in config (100/99) — enforcer applies BCLM=100 within 60s"
            RELEASED=yes
        else
            log "shutdown: WARN limit release config write failed"
            RELEASED=unverified
        fi
        # Written but unverified still counts: bc_apply_limit writes the
        # config BEFORE verifying, so a transient read failure after the
        # write leaves 100/99 in place for the enforcer to apply.
        if [ "$RELEASED" = "unverified" ] && [ "$(grep '^LAST_UPPER=' "$CFG" 2>/dev/null | cut -d= -f2-)" = "100" ] && [ "$(grep '^LAST_LOWER=' "$CFG" 2>/dev/null | cut -d= -f2-)" = "99" ]; then
            log "shutdown: config holds 100/99 (written, verify lagged)"
            RELEASED=yes
        fi
        # If the BC enforcer is NOT loaded, a config write releases
        # nothing by itself — but nothing enforces the old limit
        # either (the pre-Phase C wording claimed an old daemon
        # still enforced 86/85; that has been false since Phase C,
        # 2026-11-13, and the user-domain launchctl test that fed
        # this branch could never see the system-domain daemon at
        # all — full-fix 2026-11-15). Report honestly: the release
        # is saved in config; no enforcer is running to apply or
        # hold anything until the daemon is loaded again.
        if [ "$RELEASED" = "yes" ] && ! _daemon_loaded; then
            log "shutdown: enforcer not loaded — config holds 100/99 (release saved); nothing enforces the old limit"
            RELEASED=pending-enforcer
        fi

        # 5. Verify the release path is readable (BCLM + %).
        # (No SMC upper-limit poll exists in BC — BCLM is 10/100 only.)
        if [ -n "$(bc_read_bclm)" ] && [ -n "$(get_pct)" ]; then
            log "shutdown: release path readable (BCLM + % OK)"
        else
            log "shutdown: WARN release path unreadable (BCLM or % missing)"
        fi

        # 6. Purge state files
        # NOTE: .sleep_mode/.sleep_profile are NOT purged -- they mirror
        # the live pmset profile, which shutdown does not change; purging
        # them would show Normal in the menu while Travel/Long delays
        # are still live in pmset.
        for _sf in .sd_session .sd_watch .active_mode .charge_target \
                   .hold_override .hold_token .pre_hold_config \
                   .layer4b_hold \
                   .armed_for_sleep .status_cache \
                   .enforce_hb .enforce_state .ac_state .ncr_state \
                   .drift_state .daemon_check_state .bc_apg_init \
                   .watchdog_consolidated_last .bclm_unreadable_last \
                   .wake_age_unknown_last .overshoot_state \
                   .sleep_prediction .current_power_mode \
                   .temp_alert_state; do
            rm -f "$DASH/$_sf" 2>/dev/null
        done
        rm -f "$DASH/.op.lock" "$DASH/.launch.lock" 2>/dev/null
        rm -rf "$DASH/.notify"/* 2>/dev/null
        mkdir -p "$DASH/.notify"
        : > "$DASH/.enforce.log" 2>/dev/null
        : > "$DASH/.guardian.log" 2>/dev/null
        : > "$DASH/.watchdog.log" 2>/dev/null
        log "shutdown: state files purged"

        # 7. Park plugin
        # Park the plugin (BC name since W2).
        mkdir -p "$DASH/disabled"
        for pf in "$HOME/SwiftBar/"battery-commander.*.sh; do
            [ -f "$pf" ] || continue
            mv "$pf" "$DASH/disabled/" 2>/dev/null
        done

        # 8. Kill SwiftBar
        killall SwiftBar 2>/dev/null

        # 9. Verification gate (BC: no battopt daemon, no battopt_cfg).
        sleep 1
        SURVIVORS=$(pgrep -fl 'bc-watchdog|sd_watcher' 2>/dev/null | grep -v "dispatch.sh" || true)
        NCR_NOW=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -oE '"NotChargingReason"=[0-9]+' | grep -oE '[0-9]+' | head -1)
        AGENTS_LEFT=$(launchctl list 2>/dev/null | grep -c "com.batterycommander" || true)
        LOGIN_LEFT=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -c "BattOpt\|BatteryCommander\|Battery Commander" || true)
        CRON_LEFT=$(crontab -l 2>/dev/null | grep -c "battopt" || true)
        FAIL=0
        [ -n "$SURVIVORS" ] && { log "shutdown: FAIL survivors pgrep: $SURVIVORS"; FAIL=1; }
        [ "$AGENTS_LEFT" -gt 0 ] && { log "shutdown: FAIL agents still loaded: $AGENTS_LEFT"; FAIL=1; }
        [ "$LOGIN_LEFT" -gt 0 ] && { log "shutdown: FAIL login item persists"; FAIL=1; }
        [ "$CRON_LEFT" -gt 0 ] && { log "shutdown: FAIL cron entry present"; FAIL=1; }
        [ "$NCR_NOW" = "14" ] && log "shutdown: WARN SMC still NCR=14"
        END_TS=$(date +%s)
        if [ "$FAIL" -eq 0 ] && [ "$RELEASED" = "yes" ]; then
            log "shutdown: COMPLETE VERIFIED in $((END_TS-START_TS))s (limit 100/99 in config; enforcer applies BCLM=100 within 60s)"
        elif [ "$FAIL" -eq 0 ] && [ "$RELEASED" = "pending-enforcer" ]; then
            log "shutdown: COMPLETE (tool off) - limit release saved in config (100/99); enforcer not loaded to apply it in $((END_TS-START_TS))s"
        elif [ "$FAIL" -eq 0 ]; then
            log "shutdown: COMPLETE (tool off) - limit release pending enforcer run in $((END_TS-START_TS))s"
        else
            log "shutdown: INCOMPLETE in $((END_TS-START_TS))s"
        fi
        if [ "$FAIL" -eq 0 ] && [ "$RELEASED" = "pending-enforcer" ]; then
            notify "Battery Commander (BC)" "Shut down. Limit release saved (100/99) — enforcer not loaded."
        elif [ "$FAIL" -eq 0 ]; then
            notify "Battery Commander (BC)" "Shut down. Open Battery Commander to restore."
        else
            notify "Battery Commander (BC)" "Shutdown incomplete - check actions.log"
        fi
        guard_unlock 2>/dev/null || true
        release
        ;;

    resume)
        acquire
        log "resume requested"

        # 1. Restore plugin file (BC name since W2).
        mkdir -p "$HOME/SwiftBar"
        if [ -f "$DASH/disabled/battery-commander.10s.sh" ]; then
            mv "$DASH/disabled/battery-commander.10s.sh" "$HOME/SwiftBar/"
            chmod +x "$HOME/SwiftBar/battery-commander.10s.sh"
        fi

        # 2. Clean stale flags
        rm -f "$DASH/.disabled" "$DASH/.paused" "$DASH/.user_shutdown" 2>/dev/null
        # 2b. Re-add Battery Commander (BC) app to Login Items.
        # Installed app is BatteryCommander.app (deploy swapped it
        # 2026-11-10); BattOpt.app is a dead fallback (deleted 2026-11-10).
        _APP="/Applications/BatteryCommander.app"
        [ -d "$_APP" ] || _APP="/Applications/BattOpt.app"
        if [ -d "$_APP" ]; then
            osascript -e 'tell application "System Events" to try' \
                    -e "make login item at end with properties {path:\"$_APP\", hidden:true}" \
                    -e 'end try' 2>/dev/null || true
        else
            log "resume: BatteryCommander.app not found — login item not added"
        fi
        defaults delete com.ameba.SwiftBar DisabledPlugins 2>/dev/null

        # 3. The BC enforcer (root LaunchDaemon) is NOT auto-started here.
        # Loading it is the Phase C gate (separate approval). Log it.
        log "resume: enforcer LaunchDaemon not auto-started (Phase C gate)"

        # 4. Reload all LaunchAgents (reverses shutdown unload -w)
        # Agent labels are com.batterycommander.* (renamed 2026-11-11).
        for plist in "$HOME/Library/LaunchAgents/"com.batterycommander.*.plist; do
            [ -f "$plist" ] || continue
            launchctl load -w "$plist" 2>/dev/null
        done

        # 5. Reapply limit via the BC backend (config write + enforcer signal).
        read_config
        if bc_apply_limit "${LAST_UPPER:-86}" "${LAST_LOWER:-85}"; then
            log "resume: limit re-applied ${LAST_UPPER:-86}/${LAST_LOWER:-85}"
        else
            log "resume: WARN limit re-apply failed"
        fi

        # 6. Launch SwiftBar if not running
        if ! pgrep -x SwiftBar >/dev/null 2>&1; then
            nohup /Applications/SwiftBar.app/Contents/MacOS/SwiftBar >/dev/null 2>&1 &
        fi

        # 7. Notify
        notify "Battery Commander (BC)" "Restored"
        release
        ;;

    restore)
        $DASH/dispatch.sh resume
        ;;

    details)
        # BC status: bc-status (Key: value) + BCLM + canonical config + ioreg.
        # Never battopt status, never free-text regex on battopt output.
        SNAP=$(bc_status_snapshot)
        PROCS=$(launchctl list 2>/dev/null | grep -E "batterycommander|battopt" | head -5 || true)
        MSG="=== Battery Commander (BC) Status ===

${SNAP}

=== Intent (saved) ===
Upper: ${LAST_UPPER}%
Lower: ${LAST_LOWER}%
Sailing: ${SAILING}
Sail Gap: ${SAIL_GAP}%

=== Active Agents ===
${PROCS:-none}"
        # Sanitise before the dialog (same pattern as power_saver_report).
        MSG=$(printf '%s' "$MSG" | tr '"`\\$' '____')
        osascript << A
display dialog "${MSG}" buttons {"OK"} default button "OK" with title "Battery Commander (BC) - Details" with icon note
A
        ;;

    about)
        LOGO="$DASH/icons/battery-commander.png"
        [ -f "$LOGO" ] || LOGO="$DASH/icons/battopt.png"
        [ -f "$LOGO" ] && osascript - "$LOGO" "${LAST_UPPER:-86}" "${LAST_LOWER:-85}" <<'A'
on run argv
    set logoPath to item 1 of argv
    set upperLimit to item 2 of argv
    set lowerLimit to item 3 of argv
    set aboutText to "Battery Commander (BC)" & return & ¬
        "Independent battery charge-limit tool." & return & return & ¬
        "Keeps your battery between the limits you set." & return & ¬
        "Limit: " & upperLimit & "% / " & lowerLimit & "% — hold at the upper, resume at the lower." & return & return & ¬
        "Sailing mode: keeps the battery between upper and lower." & return & return & ¬
        "Smart Discharge: drains to a target while on battery power." & return & ¬
        "Calibration: a guided full cycle that re-anchors the gauge."
    display dialog aboutText buttons {"OK"} default button "OK" with title "About Battery Commander (BC)" with icon (POSIX file logoPath)
end run
A
        ;;

    open_actions_log) open "$LOG" ;;

    login_toggle)
        acquire
        STATE=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -c "BattOpt\|BatteryCommander\|Battery Commander" || true)
        STATE=${STATE:-0}; case "$STATE" in ''|*[!0-9]*) STATE=0;; esac
        if [ "$STATE" -gt 0 ]; then
            osascript <<OSA
tell application "System Events"
    try
        delete login item "BatteryCommander"
    end try
    try
        delete login item "BatteryCommander"
    end try
end tell
OSA
            notify "Battery Commander (BC)" "Removed from Login Items"
        else
            _APP="/Applications/BatteryCommander.app"
            [ -d "$_APP" ] || _APP="/Applications/BattOpt.app"
            if [ ! -d "$_APP" ]; then
                log "login_toggle: BatteryCommander.app not found — login item not added"
                notify "Battery Commander (BC)" "Battery Commander app not found"
                release
                exit 1
            fi
            osascript <<OSA
tell application "System Events"
    try
        delete login item "BatteryCommander"
    end try
    try
        delete login item "BatteryCommander"
    end try
    make login item at end with properties {path:"$_APP", hidden:true}
end tell
OSA
            notify "Battery Commander (BC)" "Added to Login Items"
        fi
        release
        ;;

    open_app)
        # S4: Log open_app requests only - no guard, restore path must stay open
        log "open_app requested (shutdown flag: $([ -f "$DASH/.user_shutdown" ] && echo present || echo absent))"
        _APP="/Applications/BatteryCommander.app"
        [ -d "$_APP" ] || _APP="/Applications/BattOpt.app"
        if [ ! -d "$_APP" ]; then
            log "open_app: BatteryCommander.app not found"
            notify "Battery Commander (BC)" "Battery Commander app not found"
            exit 1
        fi
        open "$_APP"
        notify "Battery Commander (BC)" "Opening Battery Commander Control Center"
        ;;
    sleep_report)
        acquire
        REPORT="/tmp/battery-commander_sleep_report_$(date +%Y%m%d_%H%M).txt"
        {
            echo "=========================================="
            echo "  Battery Commander - Sleep & Battery Report"
            echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "=========================================="
            echo ""
            echo "--- BATTERY ---"
            bc_status_snapshot
            echo ""
            echo "--- SMC STATE ---"
            ioreg -rn AppleSmartBattery 2>/dev/null | grep -E '"(IsCharging|NotChargingReason|FullyCharged|ExternalChargeCapable)"'
            echo ""
            echo "--- POWER SETTINGS ---"
            pmset -g | grep -E "womp|powernap|tcpkeepalive|standbydelay|standby |hibernatemode|sleep |disksleep|displaysleep"
            echo ""
            echo "--- WAKE EVENTS (last 24h) ---"
            pmset -g log | grep -E "Wake from|DarkWake" | tail -30
            echo ""
            echo "--- WAKE REASONS SUMMARY ---"
            pmset -g log | awk '/Wake from|DarkWake/ { for (i = 1; i <= NF; i++) if ($i == "due" && $(i + 1) == "to") print $(i + 2) }' | sort | uniq -c | sort -rn | head -15
            echo ""
            echo "--- TOP PROCESSES (CPU) ---"
            ps aux | sort -rk 3 | head -8 | awk '{printf "%-8s %5s%% %5s%% %s\n", $1, $3, $4, $11}'
            echo ""
            echo "--- USB DEVICES ---"
            system_profiler SPUSBDataType 2>/dev/null | grep -E "^\s{4}\w+|Manufacturer" | head -15
            echo ""
            echo "--- BATTERY COMMANDER PROCESSES ---"
            pgrep -fl "bc-limit|battery-commander|battopt" | grep -v "pgrep\|pmset" || echo "none"
            echo ""
            echo "--- CURRENT ASSERTIONS ---"
            pmset -g assertions | head -25
            echo ""
            echo "=========================================="
            echo "  End of Report"
            echo "=========================================="
        } > "$REPORT" 2>&1
        log "sleep_report: $REPORT"
        open -e "$REPORT"
        release
        ;;

    overnight_report)
        # Overnight report: today's morning report (regenerate if missing so
        # the numbers are fresh, including the wake % after lid-open).
        acquire
        REPORT="$DASH/reports/morning-$(date +%Y%m%d).txt"
        if [ ! -s "$REPORT" ]; then
            "$DASH/morning_report.sh" 2>/dev/null
        fi
        if [ -s "$REPORT" ]; then
            open -e "$REPORT"
        else
            notify "Battery Commander (BC)" "Overnight report not available yet"
        fi
        release
        ;;

    verify_now)
        # Re-run Verification (design §5): tracker catch-up + a fresh
        # bc-verify scoring run (same code path as the 08:00 morning
        # step), then show the resulting one-line verdict.
        acquire
        if [ -x "$DASH/bc-verify-run.sh" ]; then
            "$DASH/bc-verify-run.sh" manual >/dev/null 2>&1 || true
            _vs=$(cat "$DASH/.verification_summary" 2>/dev/null)
            notify "Battery Commander (BC)" "${_vs:-Verification unavailable}"
        else
            notify "Battery Commander (BC)" "Verification not installed"
        fi
        release
        ;;

    verification_report)
        # Open today's verification report (design §6 submenu);
        # generate it on demand if the morning run has not yet.
        acquire
        REPORT="$DASH/reports/verification-$(date +%Y%m%d).txt"
        if [ ! -s "$REPORT" ] && [ -x "$DASH/bc-verify-run.sh" ]; then
            "$DASH/bc-verify-run.sh" manual >/dev/null 2>&1 || true
        fi
        if [ -s "$REPORT" ]; then
            open -e "$REPORT"
        else
            notify "Battery Commander (BC)" "Verification report not available yet"
        fi
        release
        ;;

    sleep_report_save)
        acquire
        DIR="$DASH/reports"
        mkdir -p "$DIR"
        REPORT="$DIR/report_$(date +%Y%m%d_%H%M).txt"
        {
            echo "Battery Commander Report - $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
            echo "--- BATTERY ---"
            bc_status_snapshot
            echo ""
            echo "--- POWER SETTINGS ---"
            pmset -g | grep -E "womp|powernap|tcpkeepalive|standbydelay|standby |hibernatemode|sleep "
            echo ""
            echo "--- WAKE EVENTS ---"
            pmset -g log | grep -E "Wake from|DarkWake" | tail -30
            echo ""
            echo "--- ASSERTIONS ---"
            pmset -g assertions | head -25
        } > "$REPORT" 2>&1
        log "report saved: $REPORT"
        notify "Battery Commander (BC)" "Report saved: $(basename "$REPORT")"
        release
        ;;

    open_reports)
        open "$DASH/reports/" 2>/dev/null || notify "Battery Commander (BC)" "No reports yet"
        ;;

        power_saver_on)
        acquire
        log "power_saver: on"
        if ! $DASH/power_saver.sh on; then
            log "power_saver: on FAILED (power_saver.sh/pmset error)"
            notify "Battery Commander (BC)" "Power Saver FAILED to enable (pmset error - see actions.log)"
            release
            exit 1
        fi
        notify "Battery Commander (BC)" "Power Saver enabled — deep sleep optimized"
        release
        ;;

    power_saver_off)
        acquire
        log "power_saver: off"
        if ! $DASH/power_saver.sh off; then
            log "power_saver: off FAILED (power_saver.sh/pmset error)"
            notify "Battery Commander (BC)" "Power Saver FAILED to disable (pmset error - see actions.log)"
            release
            exit 1
        fi
        notify "Battery Commander (BC)" "Power Saver disabled"
        release
        ;;

    power_saver_report)
        acquire
        # Summary for dialog
        PSAVER_STATE=$([ -f "$DASH/.power_saver" ] && echo "ENABLED" || echo "DISABLED")
        PCT=$(get_pct)
        HEALTH=$(bc_status_value "Health" | tr -d '%')
        WAKE_24H=$(pmset -g log 2>/dev/null | grep -cE "Wake from|DarkWake")
        WAKE_24H=${WAKE_24H:-0}
        TOP_REASON=$(pmset -g log | awk '/Wake from|DarkWake/ { for (i = 1; i <= NF; i++) if ($i == "due" && $(i + 1) == "to") print $(i + 2) }' | sort | uniq -c | sort -rn | head -1)
        USB_DEV=$(system_profiler SPUSBDataType 2>/dev/null | grep -A 2 "Wireless Device" | grep "Product ID" | head -1)
        
        # Build dialog content
        MSG="═══ Battery Commander Sleep Report ═══
        
🔋 Battery: ${PCT}%
💚 Health: ${HEALTH}%
⚙️ Power Saver: ${PSAVER_STATE}
        
📊 Last 24 hours:
  • Wake events: ${WAKE_24H}
  • Top reason: ${TOP_REASON}
        
🔌 USB devices:
${USB_DEV:-  none detected}
        
📋 Active Issues:"
        
        # Detect issues
        ISSUES=""
        [ "$([ -f "$DASH/.power_saver" ] && echo 1 || echo 0)" = "0" ] && ISSUES="${ISSUES}\n  ⚠️ Power Saver DISABLED"
        [ "$WAKE_24H" -gt 30 ] && ISSUES="${ISSUES}\n  🔴 High wake count (${WAKE_24H})"
        [ -n "$USB_DEV" ] && ISSUES="${ISSUES}\n  ⚠️ USB device may prevent deep sleep"
        
        [ -z "$ISSUES" ] && ISSUES="\n  ✅ No issues detected"
        
        MSG="${MSG}${ISSUES}"
        
        MSG=$(printf '%s' "$MSG" | tr '"`\\$' '____')
        RESULT=$(osascript << AS
try
    set d to display dialog "${MSG}" buttons {"Close", "Save Full Report", "Toggle Saver"} default button "Close" with title "Battery Commander Sleep Report" with icon note
    return button returned of d
on error
    return "cancelled"
end try
AS
)
        
        case "$RESULT" in
            "Save Full Report")
                $DASH/dispatch.sh sleep_report_save
                ;;
            "Toggle Saver")
                if [ -f "$DASH/.power_saver" ]; then
                    if ! $DASH/power_saver.sh off; then
                        log "power_saver_report: toggle off FAILED (power_saver.sh/pmset error)"
                        notify "Battery Commander (BC)" "Power Saver FAILED to disable (pmset error - see actions.log)"
                    else
                        notify "Battery Commander (BC)" "Power Saver disabled"
                    fi
                else
                    if ! $DASH/power_saver.sh on; then
                        log "power_saver_report: toggle on FAILED (power_saver.sh/pmset error)"
                        notify "Battery Commander (BC)" "Power Saver FAILED to enable (pmset error - see actions.log)"
                    else
                        notify "Battery Commander (BC)" "Power Saver enabled"
                    fi
                fi
                ;;
        esac
        release
        ;;

        auto_cleanup_toggle)
        acquire
        AUTO_FLAG="$DASH/.auto_cleanup"
        if [ -f "$AUTO_FLAG" ]; then
            rm -f "$AUTO_FLAG"
            log "auto_cleanup: OFF"
            notify "Battery Commander (BC)" "Auto Cleanup disabled"
        else
            touch "$AUTO_FLAG"
            log "auto_cleanup: ON"
            notify "Battery Commander (BC)" "Auto Cleanup enabled (15 min idle)"
        fi
        release
        ;;

    pre_sleep_now)
        acquire
        log "Manual pre-sleep cleanup"
        $DASH/pre_sleep_cleanup.sh
        notify "Battery Commander (BC)" "Pre-Sleep cleanup applied"
        release
        ;;

    post_wake_now)
        acquire
        log "Manual post-wake restore"
        $DASH/post_wake_restore.sh
        rm -f "$DASH/.pre_sleep_done"
        notify "Battery Commander (BC)" "Services restored"
        release
        ;;

        arm_sleep)
        acquire
        $DASH/arm_sleep.sh
        release
        ;;

    disarm_sleep)
        acquire
        $DASH/post_wake_restore.sh
        notify "Battery Commander (BC)" "Sleep disarmed — services restored"
        release
        ;;

        logs_ai_bundle)
        acquire
        DIR="$DASH/reports/ai_diagnostic"
        mkdir -p "$DIR"
        STAMP=$(date +%Y%m%d_%H%M%S)
        BUNDLE="$DIR/bundle_$STAMP.md"
        
        {
            echo "# Battery Commander - AI Diagnostic Bundle"
            echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
            echo "## System"
            echo '```'
            sw_vers
            uname -a
            uptime
            echo '```'
            echo ""
            echo "## Battery State"
            echo '```'
            bc_status_snapshot
            echo '```'
            echo ""
            echo "## pmset Settings"
            echo '```'
            pmset -g | grep -E "hibernatemode|standbydelay|autopoweroff|powernap|womp|tcpkeepalive|displaysleep|^ sleep"
            echo '```'
            echo ""
            echo "## LaunchAgents (Battery Commander)"
            echo '```'
            launchctl list | grep -E "batterycommander|battopt" 2>&1
            # NOTE: system (root) agents are not listed here - listing them needs root; returns in W5/Phase C.
            echo '```'
            echo ""
            echo "## Recent Actions (100 lines)"
            echo '```'
            tail -100 "$DASH/actions.log" 2>/dev/null
            echo '```'
            echo ""
            echo "## Sailing History"
            echo '```'
            cat "$DASH/.sailing_history" 2>/dev/null || echo "No transitions"
            echo '```'
            echo ""
            echo "## Arm Log"
            echo '```'
            tail -50 "$DASH/.arm_log" 2>/dev/null || echo "No data"
            echo '```'
            echo ""
            echo "## BC Daemon Log (last 50)"
            echo '```'
            tail -50 "$DASH/bc-limit-daemon.log" 2>/dev/null || echo "no bc-limit daemon log yet (daemon not loaded - Phase C gate)"
            echo '```'
            echo ""
            echo "## Wake Events (last 20)"
            echo '```'
            pmset -g log | grep -E "Wake from|DarkWake|Entering Sleep" | tail -20
            echo '```'
            echo ""
            echo "## Top CPU (10)"
            echo '```'
            ps -axo %cpu,%mem,command | sort -k1 -nr | head -10
            echo '```'
            echo ""
            echo "## Audio Contexts"
            echo '```'
            pmset -g assertions 2>/dev/null | grep -c "coreaudiod.*preventuseridlesleep"
            echo '```'
            echo ""
            echo "## Reports Folder"
            echo '```'
            ls -la "$DASH/reports/" 2>/dev/null
            echo '```'
        } > "$BUNDLE"
        
        log "logs_ai_bundle: $BUNDLE"
        notify "Battery Commander (BC)" "AI Bundle ready: $(basename "$BUNDLE")"
        open -R "$BUNDLE"
        release
        ;;

    logs_actions)
        open -e "$DASH/actions.log"
        ;;

    logs_sailing)
        open -e "$DASH/.sailing_history"
        ;;

    logs_arm)
        open -e "$DASH/.arm_log"
        ;;

    logs_daemon)
        open "$DASH" 2>/dev/null
        ;;

    logs_reports)
        open "$DASH/reports"
        ;;

        power_mode_fast)
        acquire
        $DASH/power_mode.sh fast
        notify "Battery Commander (BC)" "Power Mode: Fast Sleep"
        release
        ;;

    power_mode_balanced)
        acquire
        $DASH/power_mode.sh balanced
        notify "Battery Commander (BC)" "Power Mode: Balanced"
        release
        ;;

    power_mode_awake)
        acquire
        $DASH/power_mode.sh awake
        notify "Battery Commander (BC)" "Power Mode: Always Awake"
        release
        ;;

    power_mode_deep)
        acquire
        $DASH/power_mode.sh deep
        notify "Battery Commander (BC)" "Power Mode: Deep Only"
        release
        ;;

        project_health)
        acquire
        $DASH/project_health.sh > /dev/null 2>&1
        sleep 1
        PASS_LINE=$(grep "PASS:" /tmp/battery-commander_health_latest.txt | tail -1)
        STATUS_LINE=$(grep -E "Project is" /tmp/battery-commander_health_latest.txt | head -1)
        TEMP=$(bc_status_value "TempCPU")
        LOAD=$(sysctl -n vm.loadavg | awk '{print $2}')
        # Sanitise first (same pattern as details/power_saver_report):
        # the heredoc MUST be unquoted so the variables expand -- the old
        # quoted << 'AS' showed literal ${PASS_LINE} etc. in the dialog.
        PASS_LINE=$(printf '%s' "$PASS_LINE" | tr '"`\\$' '____')
        STATUS_LINE=$(printf '%s' "$STATUS_LINE" | tr '"`\\$' '____')
        TEMP=$(printf '%s' "$TEMP" | tr '"`\\$' '____')
        LOAD=$(printf '%s' "$LOAD" | tr '"`\\$' '____')
        BUTTON=$(osascript << AS
display dialog "Battery Commander Health Check

${PASS_LINE}
${STATUS_LINE}

Temperature: ${TEMP}
Load: ${LOAD}

Full report: /tmp/battery-commander_health_latest.txt" buttons {"Close", "Open Report"} default button "Close" with title "Battery Commander Diagnostics" with icon note
return button returned of result
AS
)
        [ "$BUTTON" = "Open Report" ] && /usr/bin/open -e /tmp/battery-commander_health_latest.txt
        release
        ;;

    conflict_check)
        acquire
        $DASH/conflict_check.sh > /tmp/battery-commander_conflicts_latest.txt 2>&1
        BUTTON=$(osascript << 'AS'
try
    set dialogResult to display dialog "Conflict Detection

Report saved to:
/tmp/battery-commander_conflicts_latest.txt" buttons {"Close", "Open"} default button "Close" with title "Battery Commander Conflicts" with icon note
    return button returned of dialogResult
on error
    return "Close"
end try
AS
)
        [ "$BUTTON" = "Open" ] && /usr/bin/open -e /tmp/battery-commander_conflicts_latest.txt
        release
        ;;

    predictive)
        acquire
        $DASH/predictive.sh
        notify "Battery Commander (BC)" "Predictive analysis complete"
        release
        ;;

    process_monitor)
        acquire
        $DASH/process_monitor.sh
        notify "Battery Commander (BC)" "Process monitor done"
        release
        ;;


    power_mode_custom)
        S=$(osascript << AS
try
    set msg to "STEP 1 of 2 — Sleep Timer

How many minutes of inactivity before your Mac enters Sleep?

  • 0   = Never sleep (Mac stays awake always)
  • 5   = Aggressive battery saving
  • 18  = Balanced (macOS default)
  • 60  = Keep awake for an hour

Recommended for daily use: 18"
    set d to display dialog msg default answer "$(get_last_input PM_SLEEP 18)" buttons {"Cancel", "Next"} default button "Next" with title "Power Mode — Custom"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$S" = "__CANCELLED__" ] && { exit 0; }
        validate_int "$S" 0 180 || { notify "Battery Commander (BC)" "Invalid sleep timer (0-180 min)"; exit 0; }
        save_last_input PM_SLEEP "$S"
        
        SD=$(osascript << AS
try
    set msg to "STEP 2 of 2 — Standby Delay

After entering Sleep, how many SECONDS should RAM stay powered
before it is written to Disk (Standby)?

  • 0    = Immediate (RAM → Disk instantly, saves power)
  • 300  = 5 minutes
  • 900  = 15 minutes (recommended)
  • 4200 = 70 minutes (macOS default, wastes power)

Recommended for battery saving: 900"
    set d to display dialog msg default answer "$(get_last_input PM_SB_DELAY 900)" buttons {"Cancel", "OK"} default button "OK" with title "Power Mode — Custom"
    return text returned of d
on error
    return "__CANCELLED__"
end try
AS
)
        [ "$SD" = "__CANCELLED__" ] && { exit 0; }
        validate_int "$SD" 0 86400 || { notify "Battery Commander (BC)" "Invalid standby delay (0-86400 s)"; exit 0; }
        save_last_input PM_SB_DELAY "$SD"
        acquire
        $DASH/power_mode.sh custom "$S" "$SD"
        notify "Battery Commander (BC)" "Custom Power Mode: sleep=$S min, standby=$SD sec"
        release
        ;;

    # Lock discipline (W1.7): branches that show a dialog run the dialog
    # BEFORE acquiring .op.lock (user think time must not hold the lock),
    # then acquire, re-validate, and run intent_apply under the lock.
    # Lock-free dialog branches: limit_custom, smart_discharge,
    # sail_gap_set, power_mode_custom, sleep_mode_*, reset_defaults.
    # All other branches acquire first, then work, then release.
    *)
        log "dispatch: unknown action '$1'"
        exit 1
        ;;
    esac


