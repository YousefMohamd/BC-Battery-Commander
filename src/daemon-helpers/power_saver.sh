#!/bin/bash
# Battery Commander Power Saver — optimizes macOS for deep sleep
# Reduces battery drain during Sleep by ~60-70%
# W4.3: base is the INSTALLED copy (3,730 B — the live one), not the repo
# copy (4,796 B, diverged). Dead `long`/`travel` profiles REMOVED
# (approved decision 5 — `long` was an exact copy of default; `travel`
# had distinct battery delays (3600) which are also removed per the
# approval). 2026-11-11: `long`/`travel` REDEFINED with distinct values
# (Yousef approved 2026-11-11) — see apply_delays() below.
# `off` no longer calls enforce_sleep_policy (it applied the power-saver
# profile while turning OFF). Every pmset call is failure-checked: if any
# fails, the ENABLED flag is NOT written (on) / NOT removed (off), the
# failure is logged, and the command reports it — never print success
# when pmset failed. `status` reads real pmset values, not just the flag.
# No pmset changes are made by the build verification (read-only `pmset -g`
# only). The pmset sudo lines (`sudo -n /usr/bin/pmset`) are KEPT (W1.9 —
# sleep modes need them; the sudoers NOPASSWD pmset entry is the existing
# mechanism).

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
FLAG="$DASH/.power_saver"
PMSET_BIN="${PMSET_BIN:-/usr/bin/pmset}"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }

# _ps — pmset with failure tracking. Runs `sudo -n pmset "$@"`; on failure
# sets PMSET_FAILED=1 and logs. Callers check PMSET_FAILED before claiming
# success or writing/removing the ENABLED flag.
PMSET_FAILED=0
_ps() {
    if ! sudo -n "$PMSET_BIN" "$@" >>"$LOG" 2>&1; then
        PMSET_FAILED=1
        log "power_saver: pmset FAILED: $*"
    fi
}

apply_delays() {
    local profile="${1:-default}"
    local battery_high battery_low battery_auto
    local ac_high ac_low ac_auto ac_sleep

    case "$profile" in
        default)
            battery_high=600
            battery_low=600
            battery_auto=1800
            ac_high=10800
            ac_low=10800
            ac_auto=3600
            ac_sleep=90
            ;;
        long)
            # Long work sessions: keep the Mac ready on both battery and AC
            # (2026-11-11, Yousef approved distinct values).
            battery_high=3600
            battery_low=3600
            battery_auto=3600
            ac_high=14400
            ac_low=14400
            ac_auto=7200
            ac_sleep=90
            ;;
        travel)
            # Short trips: keep the session alive on battery. Battery
            # hibernates after 4h (14400) instead of 30min — the dialog's
            # promise (2026-11-11, Yousef approved distinct values).
            battery_high=3600
            battery_low=3600
            battery_auto=14400
            ac_high=10800
            ac_low=10800
            ac_auto=3600
            ac_sleep=90
            ;;
        *)
            # Unknown profile names fall back to default — never fail silently.
            log "apply_delays: unknown profile '$profile' — using default"
            profile=default
            battery_high=600
            battery_low=600
            battery_auto=1800
            ac_high=10800
            ac_low=10800
            ac_auto=3600
            ac_sleep=90
            ;;
    esac

    _ps -b standbydelayhigh "$battery_high"
    _ps -b standbydelaylow "$battery_low"
    _ps -b autopoweroffdelay "$battery_auto"
    _ps -b standbydelay "$battery_high"
    _ps -b disksleep 10

    _ps -c standbydelayhigh "$ac_high"
    _ps -c standbydelaylow "$ac_low"
    _ps -c autopoweroffdelay "$ac_auto"
    _ps -c standbydelay "$ac_high"
    _ps -c sleep "$ac_sleep"
    _ps -c disksleep 10

    log "apply_delays: profile=$profile battery=$battery_high/$battery_low/$battery_auto ac=$ac_high/$ac_low/$ac_auto sleep=$ac_sleep"
}

# _active_profile — the sleep-mode profile that owns the standby delays
# (audit 2026-11-11, M2). `.sleep_mode` is written by dispatch (travel /
# long / default); the delay profile must follow it, or `on` /
# enforce_sleep_policy silently clobbers Travel/Long Day delays with the
# default profile. Unknown values fall back to default.
_active_profile() {
    local _m
    _m=$(cat "$DASH/.sleep_mode" 2>/dev/null | tr -d '[:space:]')
    case "$_m" in
        travel|long) printf '%s' "$_m" ;;
        *) printf '%s' "default" ;;
    esac
}

enforce_sleep_policy() {
    apply_delays "$(_active_profile)"
}

case "$1" in
    apply-delays)
        apply_delays "${2:-$(_active_profile)}"
        if [ "$PMSET_FAILED" -ne 0 ]; then
            echo "Power Saver: apply-delays FAILED (pmset error — see actions.log)" >&2
            exit 1
        fi
        ;;
    enforce-sleep-policy)
        enforce_sleep_policy
        if [ "$PMSET_FAILED" -ne 0 ]; then
            echo "Power Saver: enforce-sleep-policy FAILED (pmset error — see actions.log)" >&2
            exit 1
        fi
        ;;
    on)
        [ -f "$DASH/.user_shutdown" ] && exit 0
        log "power_saver: ON"
        ARCH=$(uname -m)
        _ps -a powernap 0
        _ps -a womp 0
        _ps -a tcpkeepalive 0
        _ps -a acwake 0
        _ps -a lidwake 1
        enforce_sleep_policy
        _ps -a standby 1
        _ps -a disksleep 10
        _ps schedule cancelall 2>/dev/null
        if [ "$ARCH" = "x86_64" ]; then
            _ps -a hibernatemode 25
        fi
        _ps -a autopoweroff 1
        if [ "$PMSET_FAILED" -ne 0 ]; then
            log "power_saver: ON FAILED — not writing ENABLED flag"
            echo "Power Saver: FAILED to enable (pmset error — see actions.log)" >&2
            exit 1
        fi
        printf "ENABLED" > "$FLAG.tmp" && mv "$FLAG.tmp" "$FLAG"
        echo "Power Saver: ENABLED"
        ;;
    off)
        [ -f "$DASH/.user_shutdown" ] && exit 0
        log "power_saver: OFF"
        # NOTE: `off` does NOT call enforce_sleep_policy (W4.3 fix). The old
        # code applied the power-saver default profile while turning OFF —
        # the `off`-still-applies contradiction. `off` restores the feature
        # flags (powernap/womp on, hibernatemode 3, autopoweroff off,
        # standby off); with standby 0 / autopoweroff 0 the delay values
        # are inert, so no delay profile is applied here.
        _ps -a powernap 1
        _ps -a womp 1
        _ps -a tcpkeepalive 1
        _ps -a acwake 1
        _ps -a lidwake 1
        _ps -a hibernatemode 3
        _ps -a autopoweroff 0
        _ps -a standby 0
        if [ "$PMSET_FAILED" -ne 0 ]; then
            log "power_saver: OFF FAILED — keeping ENABLED flag (still on)"
            echo "Power Saver: FAILED to disable (pmset error — see actions.log)" >&2
            exit 1
        fi
        rm -f "$FLAG"
        echo "Power Saver: DISABLED"
        ;;
    status)
        if [ -f "$FLAG" ]; then echo "ENABLED"; else echo "DISABLED"; fi
        # Live values (read-only) — the flag alone does not prove the
        # settings match, so report what pmset actually says.
        echo "Live pmset values:"
        "$PMSET_BIN" -g 2>/dev/null | grep -E '^\s*(standby|hibernatemode|powernap|womp|autopoweroff|standbydelay|standbydelayhigh|standbydelaylow|autopoweroffdelay|sleep|disksleep)' | sed 's/^/  /'
        ;;
esac
