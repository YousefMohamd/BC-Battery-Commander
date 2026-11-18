#!/bin/bash
# bc-watchdog-sentinel.sh — liveness + integrity sentinel
# (verification deployment 2026-11-14; daemon-liveness + integrity
# extension, hardening 2026-11-14).
#
# Why this exists: on 2026-11-13 23:12 the watchdog lost its execute
# bit in a deploy and died SILENTLY for ~15 h — APG froze yellow,
# .apg_paused was never cleared, and charging stayed suppressed while
# every individual component looked fine. Nothing watched the
# watcher. This sentinel watches three things, all with the same
# discipline: an alert must be EARNED by staleness/drift the sentinel
# itself observed continuously for >= 300 s across consecutive runs
# while the Mac was awake — never by pre-sleep history.
#
#   1. Watchdog heartbeat (~/.battery-commander/.watchdog.log, one
#      line per 60 s tick): stale > 240 s + observed >= 300 s ->
#      alert once per incident; resume is logged and closes it.
#   2. Enforcer daemon liveness (bc-limit-daemon.log mtime; the
#      daemon appends a state line every 60 s tick): same thresholds.
#      Before this extension, a dead bc-limit alerted NOBODY — the
#      watchdog kept heartbeating while enforcement was gone.
#   3. Deployed-file integrity: the deployed scripts must exist, be
#      executable, and match their repo sources (md5). Drift (the
#      2026-11-14 lost-exec-bit class) observed >= 300 s -> alert
#      once per incident. The 300 s window makes the check
#      deploy-proof: a deploy replaces files over seconds and can
#      never alert; only drift that PERSISTS is reported.
#
# Sleep honesty: the sentinel can only run while the Mac is awake.
# If the gap since its own previous run exceeds 600 s, the Mac was
# asleep or off — every observation window resets, so staleness that
# is merely old because the Mac slept can NEVER alert.
#
# Read-only toward BC: it never touches BCLM, the config, or any
# agent; its only writes are its own state + log files.
#
# Synthetic-test hooks (used by the tests only):
#   BC_SENTINEL_HB=<file>     watchdog heartbeat file to watch
#   BC_SENTINEL_DLOG=<file>   daemon log file to watch
#   BC_SENTINEL_REPO=<dir>    repo root for the integrity pairs
#   BC_SENTINEL_INTEGRITY=off skip the integrity check
#   BC_SENTINEL_NOW=<epoch>   override "now"
#   BC_SENTINEL_NOTIFY=log    notifications go to the sentinel log
#                             (+ .sentinel_last_notification) instead
#                             of the desktop notifier
if [ -n "${BC_DASH:-}" ]; then
    DASH="$BC_DASH"
elif [ -d "$HOME/.battery-commander" ]; then
    DASH="$HOME/.battery-commander"
else
    exit 0
fi
HB="${BC_SENTINEL_HB:-$DASH/.watchdog.log}"
DLOG="${BC_SENTINEL_DLOG:-$DASH/bc-limit-daemon.log}"
REPO="${BC_SENTINEL_REPO:-$HOME/Projects/BattOpt-CC-Release}"
STATE="$DASH/.watchdog_sentinel_state"
SLOG="$DASH/.watchdog_sentinel.log"
STALE_S=240
OBSERVE_S=300
WAKE_GAP_S=600

NOW="${BC_SENTINEL_NOW:-}"
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac

LAST_RUN=0; FIRST_STALE=0; ALERTED=0
DMN_FIRST=0; DMN_ALERTED=0
INT_FIRST=0; INT_ALERTED=0; INT_FP=""
if [ -f "$STATE" ]; then
    LAST_RUN=$(grep '^LAST_RUN=' "$STATE" 2>/dev/null | head -1 | cut -d= -f2)
    FIRST_STALE=$(grep '^FIRST_STALE=' "$STATE" 2>/dev/null | head -1 | cut -d= -f2)
    ALERTED=$(grep '^ALERTED=' "$STATE" 2>/dev/null | head -1 | cut -d= -f2)
    DMN_FIRST=$(grep '^DMN_FIRST=' "$STATE" 2>/dev/null | head -1 | cut -d= -f2)
    DMN_ALERTED=$(grep '^DMN_ALERTED=' "$STATE" 2>/dev/null | head -1 | cut -d= -f2)
    INT_FIRST=$(grep '^INT_FIRST=' "$STATE" 2>/dev/null | head -1 | cut -d= -f2)
    INT_ALERTED=$(grep '^INT_ALERTED=' "$STATE" 2>/dev/null | head -1 | cut -d= -f2)
    INT_FP=$(grep '^INT_FP=' "$STATE" 2>/dev/null | head -1 | cut -d= -f2-)
    case "$LAST_RUN" in ''|*[!0-9]*) LAST_RUN=0 ;; esac
    case "$FIRST_STALE" in ''|*[!0-9]*) FIRST_STALE=0 ;; esac
    case "$ALERTED" in ''|*[!0-9]*) ALERTED=0 ;; esac
    case "$DMN_FIRST" in ''|*[!0-9]*) DMN_FIRST=0 ;; esac
    case "$DMN_ALERTED" in ''|*[!0-9]*) DMN_ALERTED=0 ;; esac
    case "$INT_FIRST" in ''|*[!0-9]*) INT_FIRST=0 ;; esac
    case "$INT_ALERTED" in ''|*[!0-9]*) INT_ALERTED=0 ;; esac
fi

slog() { echo "[$(date -r "$NOW" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')] sentinel: $1" >> "$SLOG" 2>/dev/null || true; }

notify() {
    if [ "${BC_SENTINEL_NOTIFY:-}" = "log" ]; then
        slog "NOTIFICATION: $1 — $2"
        printf '%s — %s\n' "$1" "$2" > "$DASH/.sentinel_last_notification" 2>/dev/null || true
        return 0
    fi
    # App-native transport (final cleanup 2026-11-18): queue one
    # title<TAB>body line; BatteryCommander.app posts it natively.
    # No timeout/dismiss semantics — a queued alert persists in
    # Notification Center (the 2026-11-14 WS1-B discipline).
    local _t _b
    _t=$(printf '%s' "$1" | tr '\n\t' '  ')
    _b=$(printf '%s' "$2" | tr '\n\t' '  ')
    printf '%s\t%s\n' "$_t" "$_b" >> "$DASH/.notify_queue" 2>/dev/null || true
}

save_state() {
    local TMP="$STATE.tmp.$$"
    { echo "LAST_RUN=$NOW"; echo "FIRST_STALE=$FIRST_STALE"; echo "ALERTED=$ALERTED"
      echo "DMN_FIRST=$DMN_FIRST"; echo "DMN_ALERTED=$DMN_ALERTED"
      echo "INT_FIRST=$INT_FIRST"; echo "INT_ALERTED=$INT_ALERTED"; echo "INT_FP=$INT_FP"
    } > "$TMP" 2>/dev/null && mv "$TMP" "$STATE" 2>/dev/null || true
}

file_age() { # $1 = file -> age seconds (999999 when missing)
    local _m=0
    [ -f "$1" ] && _m=$(stat -f %m "$1" 2>/dev/null || echo 0)
    case "$_m" in ''|*[!0-9]*) _m=0 ;; esac
    if [ "$_m" -gt 0 ]; then
        local _a=$((NOW - _m)); [ "$_a" -lt 0 ] && _a=0
        printf '%s' "$_a"
    else
        printf '999999'
    fi
}

# Wake/off gap: the sentinel itself did not run for a long time, so
# the Mac was asleep or off. Any staleness is pre-sleep history —
# reset every observation window; it proves nothing about liveness.
if [ "$LAST_RUN" -gt 0 ]; then
    GAP=$((NOW - LAST_RUN))
    if [ "$GAP" -gt "$WAKE_GAP_S" ]; then
        if [ "$FIRST_STALE" -ne 0 ] || [ "$DMN_FIRST" -ne 0 ] || [ "$INT_FIRST" -ne 0 ]; then
            slog "wake/off gap of ${GAP}s — observation reset (pre-sleep staleness never alerts; all windows restarted)"
        fi
        FIRST_STALE=0; DMN_FIRST=0; INT_FIRST=0
    fi
fi

# --- 1. Watchdog heartbeat ---
HB_AGE=$(file_age "$HB")
if [ "$HB_AGE" -le "$STALE_S" ]; then
    if [ "$ALERTED" -eq 1 ]; then
        slog "heartbeat resumed (age ${HB_AGE}s) — incident cleared"
    elif [ "$FIRST_STALE" -ne 0 ]; then
        slog "heartbeat fresh again (age ${HB_AGE}s) before the alert threshold — observation cleared"
    fi
    FIRST_STALE=0
    ALERTED=0
else
    if [ "$FIRST_STALE" -eq 0 ]; then
        FIRST_STALE=$NOW
        slog "heartbeat stale (age ${HB_AGE}s > ${STALE_S}s) — observation started"
    elif [ "$ALERTED" -eq 0 ] && [ $((NOW - FIRST_STALE)) -ge "$OBSERVE_S" ]; then
        notify "Battery Commander (BC)" "Watchdog heartbeat stale ~$((HB_AGE / 60)) min while the Mac is awake — the watchdog may have stopped. Limit enforcement continues; monitoring is paused."
        ALERTED=1
        slog "ALERT: watchdog heartbeat stale (age ${HB_AGE}s, sentinel-observed $((NOW - FIRST_STALE))s) — notification sent (once per incident)"
    fi
fi

# --- 2. Enforcer daemon liveness (bc-limit state lines) ---
DMN_AGE=$(file_age "$DLOG")
if [ "$DMN_AGE" -le "$STALE_S" ]; then
    if [ "$DMN_ALERTED" -eq 1 ]; then
        slog "daemon log fresh again (age ${DMN_AGE}s) — daemon incident cleared"
    elif [ "$DMN_FIRST" -ne 0 ]; then
        slog "daemon log fresh again (age ${DMN_AGE}s) before the alert threshold — daemon observation cleared"
    fi
    DMN_FIRST=0
    DMN_ALERTED=0
else
    if [ "$DMN_FIRST" -eq 0 ]; then
        DMN_FIRST=$NOW
        slog "daemon log stale (age ${DMN_AGE}s > ${STALE_S}s) — daemon observation started"
    elif [ "$DMN_ALERTED" -eq 0 ] && [ $((NOW - DMN_FIRST)) -ge "$OBSERVE_S" ]; then
        notify "Battery Commander (BC)" "Enforcer daemon (bc-limit) has not logged for ~$((DMN_AGE / 60)) min while the Mac is awake — charge limits may NOT be enforced. The watchdog is alive; check the daemon."
        DMN_ALERTED=1
        slog "DAEMON NOTIFICATION: bc-limit log stale (age ${DMN_AGE}s, sentinel-observed $((NOW - DMN_FIRST))s) — notification sent (once per incident)"
    fi
fi

# --- 3. Deployed-file integrity ---
# Pairs: deployed file = repo source it must match (name|deployed|repo).
# Scripts (*.sh) must also be executable — a lost exec bit is what
# killed the watchdog on 2026-11-13. Python modules are invoked via
# interpreters/wrappers, so they are checked for presence + content.
if [ "${BC_SENTINEL_INTEGRITY:-on}" != "off" ]; then
    INT_DRIFT=""
    _pair() { # $1 name, $2 deployed, $3 repo
        if [ ! -f "$2" ]; then
            INT_DRIFT="${INT_DRIFT:+$INT_DRIFT,}missing:$1"
            return
        fi
        case "$2" in
            *.sh) [ -x "$2" ] || INT_DRIFT="${INT_DRIFT:+$INT_DRIFT,}noexec:$1" ;;
        esac
        if [ ! -f "$3" ]; then
            INT_DRIFT="${INT_DRIFT:+$INT_DRIFT,}repomissing:$1"
            return
        fi
        local _a _b
        _a=$(md5 -q "$2" 2>/dev/null || echo "?")
        _b=$(md5 -q "$3" 2>/dev/null || echo "?")
        [ "$_a" = "$_b" ] || INT_DRIFT="${INT_DRIFT:+$INT_DRIFT,}drift:$1"
    }
    _pair dispatch.sh        "$DASH/dispatch.sh"             "$REPO/src/daemon-helpers/dispatch.sh"
    _pair bc-watchdog.sh     "$DASH/bc-watchdog.sh"          "$REPO/src/daemon-helpers/bc-watchdog.sh"
    _pair display_state.sh   "$DASH/display_state.sh"        "$REPO/src/plugin/display_state.sh"
    _pair cleanup_logs.sh    "$DASH/cleanup_logs.sh"         "$REPO/src/daemon-helpers/cleanup_logs.sh"
    _pair project_health.sh  "$DASH/project_health.sh"       "$REPO/src/daemon-helpers/project_health.sh"
    _pair morning_report.sh  "$DASH/morning_report.sh"       "$REPO/src/daemon-helpers/morning_report.sh"
    _pair pre_sleep_cleanup.sh "$DASH/pre_sleep_cleanup.sh"  "$REPO/src/daemon-helpers/pre_sleep_cleanup.sh"
    _pair sentinel           "$DASH/bc-watchdog-sentinel.sh" "$REPO/battopt-project/bc-build/bc-watchdog-sentinel.sh"
    _pair tracker-live       "$DASH/bc-tracker-live.py"      "$REPO/battopt-project/bc-build/bc-tracker-live.py"
    _pair bc-verify          "$DASH/bc-verify.py"            "$REPO/battopt-project/bc-build/bc-verify.py"
    _pair state_guard.sh     "$DASH/state_guard.sh"          "$REPO/src/daemon-helpers/state_guard.sh"
    _pair tracker-live-sh    "$DASH/bc-tracker-live.sh"      "$REPO/battopt-project/bc-build/bc-tracker-live.sh"
    _pair bc-verify-run      "$DASH/bc-verify-run.sh"        "$REPO/battopt-project/bc-build/bc-verify-run.sh"
    if [ -z "$INT_DRIFT" ]; then
        if [ "$INT_ALERTED" -eq 1 ]; then
            slog "integrity restored — all deployed files match the repo again; incident cleared"
        elif [ "$INT_FIRST" -ne 0 ]; then
            slog "integrity clean again before the alert threshold — drift observation cleared"
        fi
        INT_FIRST=0; INT_ALERTED=0; INT_FP=""
    else
        if [ "$INT_FIRST" -eq 0 ] || [ "$INT_FP" != "$INT_DRIFT" ]; then
            if [ "$INT_FIRST" -eq 0 ]; then INT_FIRST=$NOW; fi
            slog "integrity drift observed: $INT_DRIFT"
            INT_FP="$INT_DRIFT"
        fi
        if [ "$INT_ALERTED" -eq 0 ] && [ $((NOW - INT_FIRST)) -ge "$OBSERVE_S" ]; then
            notify "Battery Commander (BC)" "Deployed-file integrity drift persists: $INT_DRIFT — a deployed script differs from the repo (or lost its execute bit). Monitoring continues; redeploy or investigate."
            INT_ALERTED=1
            slog "INTEGRITY NOTIFICATION: drift persisted $((NOW - INT_FIRST))s ($INT_DRIFT) — notification sent (once per incident)"
        fi
    fi
fi

save_state
exit 0
