#!/bin/bash
# bc-tracker-live.sh — live episode tracker (design §9 step 1, deployed
# form; verification deployment 2026-11-14).
#
# Resolves the BC state dir, reads the recorded Phase C swap timestamp
# from verification/phase-c.env, and execs the Python live driver
# sitting next to this script (bc-tracker-live.py), which imports the
# unmodified bc-episode-tracker.py state machines.
#
# Called at the end of every bc-watchdog.sh tick (guarded + wrapped
# there so it can never fail the tick) and at the head of every
# bc-verify-run.sh run. Observe-and-score only: no SMC, no config
# writes, no agent changes.
if [ -n "${BC_DASH:-}" ]; then
    DASH="$BC_DASH"
elif [ -d "$HOME/.battery-commander" ]; then
    DASH="$HOME/.battery-commander"
else
    exit 0
fi
DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$DIR" ] || DIR="$DASH"
[ -f "$DIR/bc-tracker-live.py" ] || exit 0
[ -f "$DIR/bc-episode-tracker.py" ] || exit 0

PHASE_C_TS=""
if [ -f "$DASH/verification/phase-c.env" ]; then
    PHASE_C_TS=$(grep '^PHASE_C_TS=' "$DASH/verification/phase-c.env" 2>/dev/null | head -1 | cut -d= -f2-)
fi
[ -n "$PHASE_C_TS" ] || exit 0

PY="/usr/local/bin/python3"
[ -x "$PY" ] || PY="$(command -v python3 2>/dev/null)"
[ -n "$PY" ] || exit 0

exec "$PY" "$DIR/bc-tracker-live.py" \
    --state-dir "$DASH" \
    --watchdog-log "$DASH/.watchdog.log" \
    --daemon-log "$DASH/bc-limit-daemon.log" \
    --discharge-log "$DASH/discharge.log" \
    --phase-c-ts "$PHASE_C_TS" \
    --tracker-py "$DIR/bc-episode-tracker.py"
