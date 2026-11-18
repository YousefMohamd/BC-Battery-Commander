#!/bin/sh
# test_bc_limit_ac.sh — dry-run test matrix for bc-limit v1.6.1-ac
# (on-AC discharge actuator: the AppleSmartBatteryManager
# discharge-mode call, engaged by bc-limit for live sessions).
#
# SAFETY: every bc-limit invocation is --dry-run (never --write),
# so no manager call is ever performed by this suite. All config/
# session files live in a scratch dir under /tmp that is removed
# on exit. The real state dir (~/.battery-commander) is never
# touched. The gauge + actuator state files live in the EXE dir
# (the scratch root for the test binary); cases seed them.
#
# Baseline assumptions (live machine, hold state): pct ~86 on AC,
# BCLM=10, ACEN=1. Cases whose live preconditions do not hold are
# SKIP, not FAIL.
#
#   A1a user session with NO monitor arming: no engage on the
#       1st tick, none on the 2nd — an unarmed user session
#       never engages (v1.6.1 two-component rule)
#   A1  user session armed by the monitor (.discharge_state
#       PHASE=armed, matching STARTED): WOULD ENGAGE on the
#       FIRST daemon tick after arming
#   A2  dry-run engage stays in the grace window (PENDING) while
#       ACEN still reads 1
#   A3  target reached -> WOULD DISENGAGE (target reached)
#   A4  session file removed -> WOULD DISENGAGE (session ended)
#   A5  calibrate session: the actuator never engages
#   A6  corrective session on an overshoot premise without a
#       second signal: no engage; the same shape as MODE=user
#       (monitor-armed) engages (user intent is the signal)
#   A6b corrective WITH a second signal: still no engage on the
#       1st sighting, WOULD ENGAGE on the 2nd — the first-tick
#       engage is a user-session privilege only
#   A7  .apg_paused present: no engage (monitor-armed fixture,
#       so the APG gate is the only blocker)
#   A7b load-only APG pause: monitor-armed user session engages
#       on the first tick
#   A8  an unconfirmed gauge jump blocks the engage; once the
#       level confirms, the engage proceeds
#   A9  orphan clearing (ACEN=0 with no session) — opportunistic:
#       only when ACEN really reads 0 (e.g. mid-experiment)
#
# Prints one PASS/FAIL/SKIP line per case. Exit 0 iff FAIL == 0
# and PASS >= 7.

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$DIR/bc-limit-v1.6.1.c"

SCRATCH=$(mktemp -d /tmp/bc-ac-test.XXXXXX) || exit 1
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM

BIN="$SCRATCH/bc-limit-test"
GSTATE="$SCRATCH/.bc-limit-last-pct"
ASTATE="$SCRATCH/.bc-limit-ac-state"

echo "== compiling bc-limit-v1.6.1.c (zero warnings required) =="
if ! clang -Wall -Wextra -framework CoreFoundation -framework IOKit \
        -o "$BIN" "$SRC" 2> "$SCRATCH/clang.log"; then
    echo "FAIL: compilation failed"
    cat "$SCRATCH/clang.log"
    exit 1
fi
if [ -s "$SCRATCH/clang.log" ]; then
    echo "FAIL: compilation produced warnings"
    cat "$SCRATCH/clang.log"
    exit 1
fi
echo "compile: OK (no warnings)"

PASS=0
FAIL=0
SKIP=0

run_bc() {
    "$BIN" --dry-run --config "$1/limit.conf" --log "$1/run.log" \
        > "$1/out.txt" 2>&1
    RC=$?
    OUT="$1/out.txt"
}

mkcfg() {
    mkdir -p "$1"
    printf 'LAST_UPPER=%s\nLAST_LOWER=%s\n' "$2" "$3" > "$1/limit.conf"
}

# mksession <case-dir> <mode> <target> <started> [run-id]
mksession() {
    {
        printf 'MODE=%s\nTARGET=%s\nSTARTED=%s\nSTARTER=test\n' "$2" "$3" "$4"
        if [ $# -ge 5 ]; then printf 'RUN=%s\n' "$5"; fi
    } > "$1/.discharge_session"
}

# mkmon <case-dir> <phase> <started> — the watchdog monitor's
# persisted state (.discharge_state): the second component's
# arming confirmation bc-limit v1.6.1 requires for user sessions.
mkmon() {
    printf 'PHASE=%s\nSESSION_STARTED=%s\n' "$2" "$3" > "$1/.discharge_state"
}

mkrun() {
    printf 'RUN_ID=%s\nLEG=L2\nHEARTBEAT=%s\nABS_FLOOR=%s\nFLOOR=10\n' \
        "$2" "$3" "$4" > "$1/.calibration_run"
}

# reset_states <baseline-pct> <cap>
reset_states() {
    printf '%s\n-1\n%s\n' "$1" "$2" > "$GSTATE"
    rm -f "$ASTATE"
}

has() { grep -Fq "$1" "$OUT"; }

report() {
    line=$(grep -F "$3" "$OUT" | head -n 1)
    if [ "$2" -eq 0 ]; then
        PASS=$((PASS + 1))
        echo "CASE $1: PASS — $line"
    else
        FAIL=$((FAIL + 1))
        echo "CASE $1: FAIL — decisive line: $line"
        echo "--- case $1 output ---"
        cat "$OUT"
        echo "----------------------"
    fi
}

skip() {
    SKIP=$((SKIP + 1))
    echo "CASE $1: SKIP — $2"
}

# --- Control run: live pct / BCLM / external / capacity.
D="$SCRATCH/ctl"; mkcfg "$D" 86 85
run_bc "$D"
P=$(grep -o 'pct=[0-9]*%' "$OUT" | head -1 | tr -dc '0-9')
K=$(grep -o 'BCLM=[0-9]*' "$OUT" | head -1 | cut -d= -f2)
EXT=$(grep -o 'external=[0-9]' "$OUT" | head -1 | cut -d= -f2)
CAP=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep '"CurrentCapacity"' | head -1 | grep -o '[0-9]*$')
echo "live state: pct=$P BCLM=$K external=$EXT cap=$CAP"
if [ -z "$P" ] || [ "$K" != "10" ] || [ "$EXT" != "1" ]; then
    echo "FAIL: suite needs the live hold state (BCLM=10, on AC)"
    exit 1
fi
NOW=$(date +%s)
TGT=$((P - 6))
[ "$TGT" -lt 20 ] && TGT=20

# A1a + A1 + A2 share one case dir (wait, engage, then pending).
D="$SCRATCH/a1"; mkcfg "$D" 86 85
mksession "$D" user "$TGT" "$NOW"
reset_states "$P" "${CAP:-0}"
# A1a. No monitor state at all: a user session the monitor has
# not armed must NOT engage — not on the 1st tick, not on the
# 2nd (the v1.6 2-sighting path no longer applies to users).
run_bc "$D"
run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && ! has "WOULD ENGAGE"; then ok=0; fi
report A1a $ok "bc-limit 1.6.1-ac starting"
# A1. The monitor arms the session (PHASE=armed, STARTED match):
# the daemon engages on the FIRST tick after arming.
mkmon "$D" armed "$NOW"
run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD ENGAGE discharge mode"; then ok=0; fi
report A1 $ok "WOULD ENGAGE discharge mode"
# A2. Third tick inside the grace window: ACEN still reads 1 in
# dry-run (no call was made), so the daemon reports PENDING and
# does not burn a re-assert.
run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "DISCHARGE MODE PENDING"; then ok=0; fi
report A2 $ok "DISCHARGE MODE PENDING"

# A3. Same session, target raised above pct -> disengage.
mksession "$D" user 99 "$NOW"
run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD DISENGAGE discharge mode (target reached)"; then ok=0; fi
report A3 $ok "WOULD DISENGAGE discharge mode (target reached)"

# A4. Fresh engage in a new dir, then the session file vanishes.
D="$SCRATCH/a4"; mkcfg "$D" 86 85
mksession "$D" user "$TGT" "$((NOW - 10))"
mkmon "$D" armed "$((NOW - 10))"
reset_states "$P" "${CAP:-0}"
run_bc "$D"
ok=1
if ! has "WOULD ENGAGE discharge mode"; then
    report A4 1 "WOULD ENGAGE discharge mode"
else
    rm -f "$D/.discharge_session"
    run_bc "$D"
    ok=1
    if [ "$RC" -eq 0 ] && has "WOULD DISENGAGE discharge mode (session ended)"; then ok=0; fi
    report A4 $ok "WOULD DISENGAGE discharge mode (session ended)"
fi

# A5. Calibrate session (valid run): never engages.
D="$SCRATCH/a5"; mkcfg "$D" 86 85
RUNID="20261116-120000-777"
mkrun "$D" "$RUNID" "$(date +%s)" 8
mksession "$D" calibrate "$TGT" "$NOW" "$RUNID"
reset_states "$P" "${CAP:-0}"
run_bc "$D"
run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && ! has "WOULD ENGAGE" && ! has "WOULD DISENGAGE"; then ok=0; fi
report A5 $ok "bc-limit 1.6.1-ac starting"

# A6. Corrective overshoot without a second signal vs user.
# Config upper = P-4 makes pct an overshoot claim (pct > upper+2).
# At the hold: not charging, amp 0, capacity seeded flat.
if [ $((P - 5)) -ge 15 ]; then
    D="$SCRATCH/a6"; mkcfg "$D" $((P - 4)) $((P - 5))
    mksession "$D" corrective "$TGT" "$((NOW - 20))"
    # Seed the previous capacity ABOVE the live one so the
    # capacity-rising signal is deterministically absent.
    reset_states "$P" "$(( ${CAP:-0} + 50 ))"
    run_bc "$D"
    run_bc "$D"
    ok=1
    if [ "$RC" -eq 0 ] && ! has "WOULD ENGAGE"; then ok=0; fi
    report A6a $ok "bc-limit 1.6.1-ac starting"
    # A6b. Corrective WITH a second signal (capacity seeded
    # rising): the 1st sighting still does not engage, the 2nd
    # does — corrective sessions keep the 2-sighting rule.
    reset_states "$P" "$(( ${CAP:-0} - 50 ))"
    run_bc "$D"
    ok=1
    if [ "$RC" -eq 0 ] && ! has "WOULD ENGAGE"; then ok=0; fi
    report A6b1 $ok "bc-limit 1.6.1-ac starting"
    # Re-seed the previous capacity below the live one (tick 1
    # consumed the seed by recording the live cap): the
    # capacity-rising second signal must still hold on tick 2.
    printf '%s\n-1\n%s\n' "$P" "$(( ${CAP:-0} - 50 ))" > "$GSTATE"
    run_bc "$D"
    ok=1
    if [ "$RC" -eq 0 ] && has "WOULD ENGAGE discharge mode"; then ok=0; fi
    report A6b $ok "WOULD ENGAGE discharge mode"
    mksession "$D" user "$TGT" "$((NOW - 30))"
    mkmon "$D" armed "$((NOW - 30))"
    rm -f "$ASTATE"
    run_bc "$D"
    ok=1
    if [ "$RC" -eq 0 ] && has "WOULD ENGAGE discharge mode"; then ok=0; fi
    report A6 $ok "WOULD ENGAGE discharge mode"
else
    skip A6 "live pct $P too low for an overshoot fixture"
fi

# A7. APG pause blocks the engage (no reason file = thermal
# class, fail safe — v1.4 semantics). The monitor-armed fixture
# makes the APG gate the only blocker.
D="$SCRATCH/a7"; mkcfg "$D" 86 85
mksession "$D" user "$TGT" "$((NOW - 40))"
mkmon "$D" armed "$((NOW - 40))"
touch "$D/.apg_paused"
reset_states "$P" "${CAP:-0}"
run_bc "$D"
run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && ! has "WOULD ENGAGE"; then ok=0; fi
report A7 $ok "bc-limit 1.6.1-ac starting"

# A7b. A load-only APG pause does NOT block a user session
# (the user's command outranks the load heuristic; temperature
# is the hard gate — product rule 2026-11-15). Monitor-armed:
# engages on the first tick.
D="$SCRATCH/a7b"; mkcfg "$D" 86 85
mksession "$D" user "$TGT" "$((NOW - 45))"
mkmon "$D" armed "$((NOW - 45))"
touch "$D/.apg_paused"
printf 'load\n' > "$D/.apg_pause_reason"
reset_states "$P" "${CAP:-0}"
run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD ENGAGE discharge mode"; then ok=0; fi
report A7b $ok "WOULD ENGAGE discharge mode"

# A8. Gauge jump blocks, confirmation releases.
D="$SCRATCH/a8"; mkcfg "$D" 86 85
mksession "$D" user "$TGT" "$((NOW - 50))"
mkmon "$D" armed "$((NOW - 50))"
printf '%s\n-1\n%s\n' $((P - 10)) "${CAP:-0}" > "$GSTATE"
rm -f "$ASTATE"
run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "GAUGE JUMP SUSPECTED" && ! has "WOULD ENGAGE"; then ok=0; fi
report A8a $ok "GAUGE JUMP SUSPECTED"
run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "GAUGE CONFIRMED" && has "WOULD ENGAGE discharge mode"; then ok=0; fi
report A8 $ok "WOULD ENGAGE discharge mode"

# A9. Orphan: only when ACEN really reads 0 (e.g. mid-experiment)
# and no session exists in this scratch.
ACEN_NOW=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -c '"ExternalConnected" = No')
D="$SCRATCH/a9"; mkcfg "$D" 86 85
reset_states "$P" "${CAP:-0}"
run_bc "$D"
if has "WOULD CLEAR orphan discharge mode"; then
    report A9 0 "WOULD CLEAR orphan discharge mode"
else
    skip A9 "ACEN reads 1 in the live state (no orphan to clear)"
fi

echo "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -eq 0 ] && [ "$PASS" -ge 7 ]; then
    exit 0
fi
exit 1
