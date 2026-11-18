#!/bin/sh
# test_bc_limit_acloss.sh - dry-run test matrix for bc-limit
# v1.7.1-acloss (AC-loss release of the manager discharge mode).
#
# The fix: while a session is live and the manager discharge mode
# is engaged, a tick that finds the physical adapter GONE (its own
# report - AdapterDetails / AppleRawAdapterDetails - vanished from
# the battery properties; the one signal the mode does not mask)
# releases the mode and drops the engage marker, so the session
# drains natively on battery and the header reads on-battery use.
#
# SAFETY: every bc-limit invocation is --dry-run (never --write),
# so no manager call is ever performed by this suite. The daemon
# binary is compiled from the production source with
# -DBC_LIMIT_TEST, which enables ONE test-only override
# (BC_TEST_ADAPTER_PRESENT) for the adapter-presence reading; the
# shipped binary is compiled WITHOUT the flag and provably lacks
# the hook (the suite asserts the strings evidence). All config/
# session files live in a scratch dir under /tmp removed on exit.
# The real state dir is never touched.
#
# Baseline assumptions (live machine, hold state): pct ~86 on AC,
# BCLM=10, ACEN=1. Cases whose live preconditions do not hold are
# SKIP, not FAIL.
#
#   L1  monitor-armed user session: WOULD ENGAGE, no AC LOST
#   L2  engaged, adapter present (real read): DISCHARGE MODE
#       PENDING inside the grace window, NO release - the fix
#       must not fire while the adapter is attached
#   L3  engaged, adapter simulated removed: WOULD RELEASE
#       (AC LOST during session)
#   L4  after the release, adapter simulated present again on
#       the live machine (ext=1): the ordinary engage path
#       re-engages - replug semantics, no AC LOST
#   L5  no session at all, adapter simulated removed: no
#       AC LOST, no release (the fix is session+mode scoped)
#
# Prints one PASS/FAIL/SKIP line per case. Exit 0 iff FAIL == 0
# and PASS >= 4.

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$DIR/bc-limit-v1.7.1.c"
if [ ! -f "$SRC" ] && [ -f "$DIR/../daemon/bc-limit-v1.7.1.c" ]; then
    SRC="$DIR/../daemon/bc-limit-v1.7.1.c"
fi

SCRATCH=$(mktemp -d /tmp/bc-acloss-test.XXXXXX) || exit 1
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM

BIN="$SCRATCH/bc-limit-test"
PROD="$SCRATCH/bc-limit-prod"
GSTATE="$SCRATCH/.bc-limit-last-pct"
ASTATE="$SCRATCH/.bc-limit-ac-state"

echo "== compiling bc-limit-v1.7.1.c with -DBC_LIMIT_TEST (zero warnings required) =="
if ! clang -Wall -Wextra -DBC_LIMIT_TEST -framework CoreFoundation -framework IOKit \
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
echo "compile(test): OK (no warnings)"

echo "== compiling production variant (no test flag) =="
if ! clang -Wall -Wextra -framework CoreFoundation -framework IOKit \
        -o "$PROD" "$SRC" 2> "$SCRATCH/clang-prod.log"; then
    echo "FAIL: production compilation failed"
    cat "$SCRATCH/clang-prod.log"
    exit 1
fi
if [ -s "$SCRATCH/clang-prod.log" ]; then
    echo "FAIL: production compilation produced warnings"
    cat "$SCRATCH/clang-prod.log"
    exit 1
fi
echo "compile(prod): OK (no warnings)"

PASS=0
FAIL=0
SKIP=0

# Hook separation: the shipped binary must NOT contain the test
# override; the test binary must.
ok=1
if strings "$PROD" | grep -q "BC_TEST_ADAPTER_PRESENT"; then ok=0; fi
if ! strings "$BIN" | grep -q "BC_TEST_ADAPTER_PRESENT"; then ok=0; fi
if [ "$ok" -eq 1 ]; then
    PASS=$((PASS + 1)); echo "CASE L0: PASS - test hook present in test build only, absent from production build"
else
    FAIL=$((FAIL + 1)); echo "CASE L0: FAIL - test-hook separation broken"
fi

run_bc() {
    "$BIN" --dry-run --config "$1/limit.conf" --log "$1/run.log" \
        > "$1/out.txt" 2>&1
    RC=$?
    OUT="$1/out.txt"
}

run_bc_noadapter() {
    BC_TEST_ADAPTER_PRESENT=0 "$BIN" --dry-run --config "$1/limit.conf" \
        --log "$1/run.log" > "$1/out.txt" 2>&1
    RC=$?
    OUT="$1/out.txt"
}

mkcfg() {
    mkdir -p "$1"
    printf 'LAST_UPPER=%s\nLAST_LOWER=%s\n' "$2" "$3" > "$1/limit.conf"
}

mksession() {
    printf 'MODE=%s\nTARGET=%s\nSTARTED=%s\nSTARTER=test\n' \
        "$2" "$3" "$4" > "$1/.discharge_session"
}

mkmon() {
    printf 'PHASE=%s\nSESSION_STARTED=%s\n' "$2" "$3" > "$1/.discharge_state"
}

reset_states() {
    printf '%s\n-1\n%s\n' "$1" "$2" > "$GSTATE"
    rm -f "$ASTATE"
}

has() { grep -Fq "$1" "$OUT"; }

report() {
    line=$(grep -F "$3" "$OUT" | head -n 1)
    if [ "$2" -eq 0 ]; then
        PASS=$((PASS + 1))
        echo "CASE $1: PASS - $line"
    else
        FAIL=$((FAIL + 1))
        echo "CASE $1: FAIL - decisive line: $line"
        echo "--- case $1 output ---"
        cat "$OUT"
        echo "----------------------"
    fi
}

skip() {
    SKIP=$((SKIP + 1))
    echo "CASE $1: SKIP - $2"
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

# L1-L4 share one case dir: engage, hold, release, re-engage.
D="$SCRATCH/l1"; mkcfg "$D" 86 85
mksession "$D" user "$TGT" "$NOW"
mkmon "$D" armed "$NOW"
reset_states "$P" "${CAP:-0}"

# L1. Armed user session engages on the first tick; no AC LOST.
run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD ENGAGE discharge mode" && ! has "AC LOST"; then ok=0; fi
report L1 $ok "WOULD ENGAGE discharge mode"

# L2. Engaged (dry-run state persisted), adapter really present:
# the ACEN grace reports PENDING; the AC-loss release must NOT fire.
run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "DISCHARGE MODE PENDING" && ! has "AC LOST" && ! has "WOULD RELEASE"; then ok=0; fi
report L2 $ok "DISCHARGE MODE PENDING"

# L3. Same engaged state, adapter simulated removed: the release
# fires on this tick, ahead of the ACEN supervision.
run_bc_noadapter "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD RELEASE discharge mode (AC LOST during session"; then ok=0; fi
report L3 $ok "WOULD RELEASE discharge mode (AC LOST during session"

# L4. The release persisted engaged=0. On the live machine the
# adapter is attached (ext=1 - the replug shape): the ordinary
# engage path re-engages; no AC LOST.
run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD ENGAGE discharge mode" && ! has "AC LOST"; then ok=0; fi
report L4 $ok "WOULD ENGAGE discharge mode"

# L5. No session, adapter simulated removed: the fix is scoped to
# live sessions with the mode engaged - nothing fires.
D="$SCRATCH/l5"; mkcfg "$D" 86 85
reset_states "$P" "${CAP:-0}"
run_bc_noadapter "$D"
ok=1
if [ "$RC" -eq 0 ] && ! has "AC LOST" && ! has "WOULD RELEASE"; then ok=0; fi
report L5 $ok "bc-limit 1.7.1-acloss starting"

echo "RESULT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && [ "$PASS" -ge 4 ]
