#!/bin/bash
# bc-verify-run.sh — one verification scoring run (design §5, §6;
# verification deployment 2026-11-14).
#
# Hosts: (a) morning_report.sh, as the final step of the existing
# 08:00 morning-report agent run (no new agent — design §5 hosting
# decision); (b) dispatch actions verify_now / verification_report.
#
# What it does:
#   1. Tracker catch-up (bc-tracker-live.sh) so the episode store is
#      fresh — including last night's .sleep_episode sidecar.
#   2. bc-verify.py --write-state --report with the recorded Phase C
#      timestamp (verification/phase-c.env), so .verification_state,
#      .verification_summary, verdicts.jsonl and the daily report are
#      refreshed and §7.1 is evaluated.
#   3. Notification policy (design §6), state-based, once per event:
#      - a bc-limit FAIL episode -> ONE notification per episode,
#        deduplicated by marker .notify/verify_<episode_id>
#        (sleep verdict_sleep FAILs are suppressed — they ride the
#        morning report's own notification, never a second alert);
#      - Phase C VERIFIED -> ONE notification, once ever, marker
#        .notify/verify_phase_c_done.
#      PASS episodes are silent.
#
# Reader/judge only: never touches the SMC, the config, or any agent.
# Always exits 0 — a verification failure must never break its hosts.
if [ -n "${BC_DASH:-}" ]; then
    DASH="$BC_DASH"
elif [ -d "$HOME/.battery-commander" ]; then
    DASH="$HOME/.battery-commander"
else
    exit 0
fi
MODE="${1:-morning}"
VDIR="$DASH/verification"
VLOG="$DASH/.verification.log"
mkdir -p "$VDIR" "$DASH/.notify" 2>/dev/null || true

vlog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] verify-run($MODE): $1" >> "$VLOG" 2>/dev/null || true; }

notify() {
    # App-native transport (final cleanup 2026-11-18): queue one
    # title<TAB>body line; BatteryCommander.app posts it natively
    # under its own identity.
    local _t _b
    _t=$(printf '%s' "$1" | tr '\n\t' '  ')
    _b=$(printf '%s' "$2" | tr '\n\t' '  ')
    printf '%s\t%s\n' "$_t" "$_b" >> "$DASH/.notify_queue" 2>/dev/null || true
}

PY="/usr/local/bin/python3"
[ -x "$PY" ] || PY="$(command -v python3 2>/dev/null)"
if [ -z "$PY" ] || [ ! -f "$DASH/bc-verify.py" ]; then
    vlog "bc-verify.py or python3 missing — scoring skipped"
    exit 0
fi

PHASE_C_TS=""
if [ -f "$VDIR/phase-c.env" ]; then
    PHASE_C_TS=$(grep '^PHASE_C_TS=' "$VDIR/phase-c.env" 2>/dev/null | head -1 | cut -d= -f2-)
fi

# 1. Tracker catch-up (guarded; the watchdog also runs it per tick).
if [ -x "$DASH/bc-tracker-live.sh" ]; then
    "$DASH/bc-tracker-live.sh" >> "$VLOG" 2>&1 || true
fi

# 2. Scoring run.
PC_ARGS=()
[ -n "$PHASE_C_TS" ] && PC_ARGS=(--phase-c-ts "$PHASE_C_TS")
"$PY" "$DASH/bc-verify.py" --state-dir "$DASH" --write-state --report \
    "${PC_ARGS[@]}" \
    --watchdog-log "$DASH/.watchdog.log" \
    --daemon-log "$DASH/bc-limit-daemon.log" >> "$VLOG" 2>&1
VEXIT=$?
vlog "bc-verify exit=$VEXIT summary: $(cat "$DASH/.verification_summary" 2>/dev/null)"

# 3a. Phase C certification — one notification, once ever (design §6).
PC_STATE=$(grep '^PHASE_C=' "$DASH/.verification_state" 2>/dev/null | head -1 | cut -d= -f2-)
case "$PC_STATE" in
    VERIFIED*)
        if [ ! -f "$DASH/.notify/verify_phase_c_done" ]; then
            PC_DATE=$(printf '%s' "$PC_STATE" | sed 's/^VERIFIED *//')
            notify "Battery Commander (BC)" "Battery Commander is verified independent: first full cycle passed ($PC_DATE)."
            touch "$DASH/.notify/verify_phase_c_done" 2>/dev/null || true
            vlog "Phase C certification notification fired (once-ever marker set)"
        fi
        ;;
esac

# 3b. FAIL episodes (bc-limit only; sleep axis suppressed) — one
# notification per episode, deduplicated by marker (design §6).
FAILS=$("$PY" "$DASH/bc-verify.py" --state-dir "$DASH" --json --range 24h \
    "${PC_ARGS[@]}" \
    --watchdog-log "$DASH/.watchdog.log" \
    --daemon-log "$DASH/bc-limit-daemon.log" 2>/dev/null | \
    "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for e in d.get("episodes_in_range", []):
    if e.get("verdict") == "FAIL" and e.get("type") != "sleep":
        print("%s|%s|%s" % (e.get("id", ""), e.get("type", ""),
                            (e.get("start_ts", "") or "")[:10]))
' 2>/dev/null)
if [ -n "$FAILS" ]; then
    printf '%s\n' "$FAILS" | while IFS='|' read -r EP_ID EP_TYPE EP_DATE; do
        [ -n "$EP_ID" ] || continue
        MARKER="$DASH/.notify/verify_$EP_ID"
        if [ ! -f "$MARKER" ]; then
            notify "Battery Commander (BC)" "Verification: $EP_TYPE episode $EP_DATE FAILED. See Verification Report."
            touch "$MARKER" 2>/dev/null || true
            vlog "FAIL notification fired for episode $EP_ID ($EP_TYPE)"
        fi
    done
fi

exit 0
