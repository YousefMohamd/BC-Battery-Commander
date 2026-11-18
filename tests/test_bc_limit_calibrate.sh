#!/bin/sh
# test_bc_limit_calibrate.sh — dry-run test matrix for bc-limit
# v1.3-calibrate (calibrate-design.md section 5.2 run contract).
#
# SAFETY: every bc-limit invocation is --dry-run (never --write).
# All config/session/run files live in a scratch dir under /tmp that
# is removed on exit. The real state dir (~/.battery-commander) is
# never touched — in particular no session or run file is ever
# created there.
#
# Baseline assumptions (live machine, hold state): pct ~86 (ioreg
# floor), BCLM=10. Scratch config 95/94 forces the resume decision
# (pct <= 94 with BCLM at the hold value), per the v1.1/v1.2
# precedent. A valid session then proves itself by suppressing that
# resume; an invalid one proves itself by the WOULD WRITE appearing.
#
# Cases R1-R4 re-run the decisive v1.2 routine cases against the
# v1.3 binary (routine behaviour must be byte-identical). Cases
# K1-K11 cover the calibrate contract: valid run honored; stale
# heartbeat, forged RUN id, TARGET below the run's ABS_FLOOR,
# missing run file, garbage run file, future heartbeat, forged
# ABS_FLOOR below the hard clamp, missing RUN line, TARGET exactly
# at ABS_FLOOR, and a stale session STARTED all degrade to
# "no session" (v1.2 behaviour).
#
# Prints one PASS/FAIL line per case. Exit 0 only if all pass.

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$DIR/bc-limit-v1.3.c"

SCRATCH=$(mktemp -d /tmp/bc-calibrate-test.XXXXXX) || exit 1
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM

BIN="$SCRATCH/bc-limit-test"

echo "== compiling bc-limit-v1.3.c (zero warnings required) =="
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

run_bc() {
    "$BIN" --dry-run --config "$1/limit.conf" --log "$1/run.log" \
        > "$1/out.txt" 2>&1
    RC=$?
}

mkcfg() {
    mkdir -p "$1"
    printf 'LAST_UPPER=%s\nLAST_LOWER=%s\n' "$2" "$3" > "$1/limit.conf"
    if [ $# -ge 4 ]; then
        printf '%s\n' "$4" >> "$1/limit.conf"
    fi
}

# mksession <case-dir> <mode> <target> <started> [run-id]
mksession() {
    {
        printf 'MODE=%s\nTARGET=%s\nSTARTED=%s\nSTARTER=test\n' "$2" "$3" "$4"
        if [ $# -ge 5 ]; then printf 'RUN=%s\n' "$5"; fi
    } > "$1/.discharge_session"
}

# mkrun <case-dir> <run-id> <heartbeat> <abs-floor>
mkrun() {
    printf 'RUN_ID=%s\nLEG=L2\nHEARTBEAT=%s\nABS_FLOOR=%s\nFLOOR=10\n' \
        "$2" "$3" "$4" > "$1/.calibration_run"
}

OUT=""
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

NOW=$(date +%s)
RUNID="20261114-190000-4242"

# --- Routine regression (v1.2 behaviour, v1.3 binary) ---

# R1. No session + 95/94 -> WOULD WRITE BCLM=100.
D="$SCRATCH/r1"; mkcfg "$D" 95 94
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100"; then ok=0; fi
report R1 $ok "WOULD WRITE BCLM=100"

# R2. Valid user session + 95/94 -> resume suppressed.
D="$SCRATCH/r2"; mkcfg "$D" 95 94
mksession "$D" user 85 "$(date +%s)"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "discharge session: resume suppressed (target=85)" \
        && ! has "WOULD WRITE"; then ok=0; fi
report R2 $ok "discharge session: resume suppressed (target=85)"

# R3. User session TARGET=10 (below routine floor 20) -> invalid.
D="$SCRATCH/r3"; mkcfg "$D" 95 94
mksession "$D" user 10 "$(date +%s)"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report R3 $ok "WOULD WRITE BCLM=100"

# R4. No session + real config (86/85) -> nothing to do.
D="$SCRATCH/r4"; mkcfg "$D" 86 85
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "nothing to do" && ! has "WOULD WRITE"; then ok=0; fi
report R4 $ok "nothing to do"

# --- Calibrate contract ---

# K1. Valid run + calibrate session TARGET=10, RUN match -> suppressed.
D="$SCRATCH/k1"; mkcfg "$D" 95 94
mkrun "$D" "$RUNID" "$(date +%s)" 8
mksession "$D" calibrate 10 "$(date +%s)" "$RUNID"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "discharge session: resume suppressed (target=10)" \
        && ! has "WOULD WRITE"; then ok=0; fi
report K1 $ok "discharge session: resume suppressed (target=10)"

# K2. Stale run heartbeat (15 min old) -> invalid, WOULD WRITE.
D="$SCRATCH/k2"; mkcfg "$D" 95 94
mkrun "$D" "$RUNID" "$((NOW - 900))" 8
mksession "$D" calibrate 10 "$(date +%s)" "$RUNID"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report K2 $ok "WOULD WRITE BCLM=100"

# K3. Forged RUN id (run file has a different id) -> WOULD WRITE.
D="$SCRATCH/k3"; mkcfg "$D" 95 94
mkrun "$D" "20260101-000000-9999" "$(date +%s)" 8
mksession "$D" calibrate 10 "$(date +%s)" "$RUNID"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report K3 $ok "WOULD WRITE BCLM=100"

# K4. TARGET=9 below the run's ABS_FLOOR=10 -> WOULD WRITE.
D="$SCRATCH/k4"; mkcfg "$D" 95 94
mkrun "$D" "$RUNID" "$(date +%s)" 10
mksession "$D" calibrate 9 "$(date +%s)" "$RUNID"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report K4 $ok "WOULD WRITE BCLM=100"

# K5. Missing run file -> WOULD WRITE.
D="$SCRATCH/k5"; mkcfg "$D" 95 94
mksession "$D" calibrate 10 "$(date +%s)" "$RUNID"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report K5 $ok "WOULD WRITE BCLM=100"

# K6. Garbage run file -> WOULD WRITE.
D="$SCRATCH/k6"; mkcfg "$D" 95 94
head -c 64 /dev/urandom > "$D/.calibration_run"
mksession "$D" calibrate 10 "$(date +%s)" "$RUNID"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report K6 $ok "WOULD WRITE BCLM=100"

# K7. Run heartbeat 1 h in the future -> WOULD WRITE.
D="$SCRATCH/k7"; mkcfg "$D" 95 94
mkrun "$D" "$RUNID" "$((NOW + 3600))" 8
mksession "$D" calibrate 10 "$(date +%s)" "$RUNID"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report K7 $ok "WOULD WRITE BCLM=100"

# K8. Forged ABS_FLOOR=1 (below the hard clamp) + TARGET=10 -> WOULD WRITE.
D="$SCRATCH/k8"; mkcfg "$D" 95 94
mkrun "$D" "$RUNID" "$(date +%s)" 1
mksession "$D" calibrate 10 "$(date +%s)" "$RUNID"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report K8 $ok "WOULD WRITE BCLM=100"

# K9. Calibrate session without a RUN line -> WOULD WRITE.
D="$SCRATCH/k9"; mkcfg "$D" 95 94
mkrun "$D" "$RUNID" "$(date +%s)" 8
mksession "$D" calibrate 10 "$(date +%s)"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report K9 $ok "WOULD WRITE BCLM=100"

# K10. TARGET exactly at ABS_FLOOR (10 == 10) -> suppressed (inclusive).
D="$SCRATCH/k10"; mkcfg "$D" 95 94
mkrun "$D" "$RUNID" "$(date +%s)" 10
mksession "$D" calibrate 10 "$(date +%s)" "$RUNID"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "discharge session: resume suppressed (target=10)" \
        && ! has "WOULD WRITE"; then ok=0; fi
report K10 $ok "discharge session: resume suppressed (target=10)"

# K11. Valid run but session STARTED 300 min ago (session staleness
#      bound still applies) -> WOULD WRITE.
D="$SCRATCH/k11"; mkcfg "$D" 95 94
mkrun "$D" "$RUNID" "$(date +%s)" 8
mksession "$D" calibrate 10 "$((NOW - 300 * 60))" "$RUNID"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report K11 $ok "WOULD WRITE BCLM=100"

echo "== summary: PASS=$PASS FAIL=$FAIL =="
if [ "$FAIL" -eq 0 ] && [ "$PASS" -eq 15 ]; then
    exit 0
fi
exit 1
