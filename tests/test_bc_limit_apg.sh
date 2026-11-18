#!/bin/sh
# test_bc_limit_apg.sh — dry-run test matrix for bc-limit
# v1.4-apggate (the M6 APG resume gate's pause-REASON branch).
#
# SAFETY: every bc-limit invocation is --dry-run (never --write).
# All config/pause files live in a scratch dir under /tmp that is
# removed on exit. The real state dir (~/.battery-commander) is
# never touched — in particular no pause file is ever created there.
#
# Baseline assumptions (live machine, hold state): pct ~86 (ioreg),
# BCLM=10. The scratch config 95/94 forces the resume decision
# (pct <= 94 with BCLM at the hold value), per the v1.1 M6 test
# precedent in test_bc_limit_discharge.sh.
#
# Contract under test (v1.4): while .apg_paused exists next to the
# config, the resume write is suppressed UNLESS .apg_pause_reason
# contains exactly "load". "thermal", a missing reason file, an
# empty one, or garbage all suppress (fail safe, v1.3 behaviour).
# The discharge-session gate is a separate, earlier branch and
# must keep precedence over the APG gate in every pause state.
#
# Prints one PASS/FAIL line per case with the decisive log line.
# Exit code 0 only if all cases pass.

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$DIR/bc-limit-v1.4.c"

SCRATCH=$(mktemp -d /tmp/bc-apg-test.XXXXXX) || exit 1
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM

BIN="$SCRATCH/bc-limit-test"

echo "== compiling bc-limit-v1.4.c (zero warnings required) =="
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

# run_bc <case-dir> : runs the test binary dry-run against the
# config in <case-dir>/limit.conf; output in <case-dir>/out.txt,
# exit code in $RC.
run_bc() {
    "$BIN" --dry-run --config "$1/limit.conf" --log "$1/run.log" \
        > "$1/out.txt" 2>&1
    RC=$?
}

# mkcfg <case-dir> <upper> <lower>
mkcfg() {
    mkdir -p "$1"
    printf 'LAST_UPPER=%s\nLAST_LOWER=%s\n' "$2" "$3" > "$1/limit.conf"
}

# mkpause <case-dir> [reason] : creates .apg_paused; when a reason
# argument is given, also writes it (plus newline) to
# .apg_pause_reason. "EMPTY" writes a zero-length reason file.
mkpause() {
    touch "$1/.apg_paused"
    if [ $# -ge 2 ]; then
        if [ "$2" = "EMPTY" ]; then
            : > "$1/.apg_pause_reason"
        else
            printf '%s\n' "$2" > "$1/.apg_pause_reason"
        fi
    fi
}

# mksession <case-dir> <mode> <target> <started>
mksession() {
    printf 'MODE=%s\nTARGET=%s\nSTARTED=%s\nSTARTER=test\n' \
        "$2" "$3" "$4" > "$1/.discharge_session"
}

has() { grep -Fq "$1" "$OUT"; }

# report <case-no> <ok:0/1> <decisive-pattern>
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

# 1. Paused + reason=load + 95/94 -> resume ALLOWED:
#    bypass line + WOULD WRITE BCLM=100.
D="$SCRATCH/case1"; mkcfg "$D" 95 94
mkpause "$D" load
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "APG load-pause: resume allowed (reason=load)" \
        && has "WOULD WRITE BCLM=100" && ! has "resume suppressed"; then ok=0; fi
report 1 $ok "APG load-pause: resume allowed (reason=load)"

# 2. Paused + reason=thermal + 95/94 -> suppressed (reason=thermal),
#    no would-write.
D="$SCRATCH/case2"; mkcfg "$D" 95 94
mkpause "$D" thermal
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "APG paused: resume suppressed (reason=thermal)" \
        && ! has "WOULD WRITE"; then ok=0; fi
report 2 $ok "APG paused: resume suppressed (reason=thermal)"

# 3. Paused + reason file MISSING + 95/94 -> suppressed
#    (reason=unknown), no would-write. (Pre-v1.4 watchdog state:
#    a pause with no reason writer must fail safe.)
D="$SCRATCH/case3"; mkcfg "$D" 95 94
mkpause "$D"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "APG paused: resume suppressed (reason=unknown)" \
        && ! has "WOULD WRITE"; then ok=0; fi
report 3 $ok "APG paused: resume suppressed (reason=unknown)"

# 4. Paused + reason=garbage + 95/94 -> suppressed (reason=unknown).
D="$SCRATCH/case4"; mkcfg "$D" 95 94
mkpause "$D" "lukewarm"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "APG paused: resume suppressed (reason=unknown)" \
        && ! has "WOULD WRITE"; then ok=0; fi
report 4 $ok "APG paused: resume suppressed (reason=unknown)"

# 5. Paused + reason file EMPTY + 95/94 -> suppressed (reason=unknown).
D="$SCRATCH/case5"; mkcfg "$D" 95 94
mkpause "$D" EMPTY
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "APG paused: resume suppressed (reason=unknown)" \
        && ! has "WOULD WRITE"; then ok=0; fi
report 5 $ok "APG paused: resume suppressed (reason=unknown)"

# 6. No pause + 95/94 -> normal resume decision, no APG line at all.
D="$SCRATCH/case6"; mkcfg "$D" 95 94
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && ! has "APG load-pause" && ! has "APG paused"; then ok=0; fi
report 6 $ok "WOULD WRITE BCLM=100"

# 7. Stale reason=load WITHOUT .apg_paused + 95/94 -> the reason
#    file alone never engages the gate: normal resume, no APG line.
D="$SCRATCH/case7"; mkcfg "$D" 95 94
printf 'load\n' > "$D/.apg_pause_reason"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && ! has "APG load-pause" && ! has "APG paused"; then ok=0; fi
report 7 $ok "WOULD WRITE BCLM=100"

# 8. Valid session + paused + reason=load + 95/94 -> the SESSION
#    gate (separate, earlier branch) still wins: session
#    suppression only, no would-write, no resume-allowed line.
D="$SCRATCH/case8"; mkcfg "$D" 95 94
mksession "$D" user 85 "$(date +%s)"
mkpause "$D" load
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "discharge session: resume suppressed (target=85)" \
        && ! has "WOULD WRITE" && ! has "resume allowed"; then ok=0; fi
report 8 $ok "discharge session: resume suppressed (target=85)"

# 9. Paused + reason=load + real config 86/85 -> nothing to do:
#    the gate only guards the resume decision; it must not
#    manufacture a write when no resume is pending.
D="$SCRATCH/case9"; mkcfg "$D" 86 85
mkpause "$D" load
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "nothing to do" && ! has "WOULD WRITE"; then ok=0; fi
report 9 $ok "nothing to do"

echo "== summary: PASS=$PASS FAIL=$FAIL =="
if [ "$FAIL" -eq 0 ] && [ "$PASS" -eq 9 ]; then
    exit 0
fi
exit 1
