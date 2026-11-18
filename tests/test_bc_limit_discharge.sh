#!/bin/sh
# test_bc_limit_discharge.sh — dry-run test matrix for bc-limit
# v1.2-discharge (discharge-design.md section 4.2 session contract).
#
# SAFETY: every bc-limit invocation is --dry-run (never --write).
# All config/session files live in a scratch dir under /tmp that is
# removed on exit. The real state dir (~/.battery-commander) is
# never touched — in particular no session file is ever created there.
#
# Baseline assumptions (live machine, hold state): pct ~88 (ioreg
# floor), BCLM=10. Real config values 86/85 give a nothing-to-do
# decision; the scratch config 95/94 forces the resume decision
# (pct <= 94 with BCLM at the hold value), per the v1.1 M6 test
# precedent.
#
# Prints one PASS/FAIL line per case with the decisive log line.
# Exit code 0 only if all cases pass.

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$DIR/bc-limit-v1.2.c"

SCRATCH=$(mktemp -d /tmp/bc-discharge-test.XXXXXX) || exit 1
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM

BIN="$SCRATCH/bc-limit-test"

echo "== compiling bc-limit-v1.2.c (zero warnings required) =="
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

# mkcfg <case-dir> <upper> <lower> [extra-config-line]
mkcfg() {
    mkdir -p "$1"
    printf 'LAST_UPPER=%s\nLAST_LOWER=%s\n' "$2" "$3" > "$1/limit.conf"
    if [ $# -ge 4 ]; then
        printf '%s\n' "$4" >> "$1/limit.conf"
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

NOW=$(date +%s)

# 1. No session + real config (86/85) -> nothing to do.
D="$SCRATCH/case1"; mkcfg "$D" 86 85
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "nothing to do" && ! has "WOULD WRITE"; then ok=0; fi
report 1 $ok "nothing to do"

# 2. No session + 95/94 -> WOULD WRITE BCLM=100.
D="$SCRATCH/case2"; mkcfg "$D" 95 94
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100"; then ok=0; fi
report 2 $ok "WOULD WRITE BCLM=100"

# 3. Valid session (user, target 85, started now) + 95/94 ->
#    resume suppressed, session log line, no would-write.
D="$SCRATCH/case3"; mkcfg "$D" 95 94
mksession "$D" user 85 "$(date +%s)"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "discharge session: resume suppressed (target=85)" \
        && ! has "WOULD WRITE"; then ok=0; fi
report 3 $ok "discharge session: resume suppressed (target=85)"

# 4. Valid session + real config -> nothing to do.
# (v1.6: reset the actuator state — a fresh daemon context.)
rm -f "$SCRATCH/.bc-limit-ac-state"
D="$SCRATCH/case4"; mkcfg "$D" 86 85
mksession "$D" user 85 "$(date +%s)"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "nothing to do" && ! has "WOULD WRITE" \
        && ! has "resume suppressed"; then ok=0; fi
report 4 $ok "nothing to do"

# 5. Stale session (started 300 min ago; default max 240) + 95/94 ->
#    WOULD WRITE BCLM=100.
# (v1.6: reset the actuator state — a fresh daemon context.)
rm -f "$SCRATCH/.bc-limit-ac-state"
D="$SCRATCH/case5"; mkcfg "$D" 95 94
mksession "$D" user 85 "$((NOW - 300 * 60))"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report 5 $ok "WOULD WRITE BCLM=100"

# 6. Future session (started now+3600) + 95/94 -> WOULD WRITE 100.
D="$SCRATCH/case6"; mkcfg "$D" 95 94
mksession "$D" user 85 "$((NOW + 3600))"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report 6 $ok "WOULD WRITE BCLM=100"

# 7. Garbage session file + 95/94 -> WOULD WRITE 100 +
#    invalid-ignored line + exit 0.
D="$SCRATCH/case7"; mkcfg "$D" 95 94
head -c 64 /dev/urandom > "$D/.discharge_session"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report 7 $ok "discharge session: invalid file ignored"

# 8. TARGET=10 session (below floor 20) + 95/94 -> WOULD WRITE 100.
D="$SCRATCH/case8"; mkcfg "$D" 95 94
mksession "$D" user 10 "$(date +%s)"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report 8 $ok "WOULD WRITE BCLM=100"

# 9. TARGET=99 MODE=corrective + real config -> nothing to do
#    (no spurious write).
D="$SCRATCH/case9"; mkcfg "$D" 86 85
mksession "$D" corrective 99 "$(date +%s)"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "nothing to do" && ! has "WOULD WRITE"; then ok=0; fi
report 9 $ok "nothing to do"

# 10. Valid session + .apg_paused both present + 95/94 ->
#     suppressed, with exactly ONE suppression line (the session
#     check takes precedence over the APG gate).
D="$SCRATCH/case10"; mkcfg "$D" 95 94
mksession "$D" user 85 "$(date +%s)"
touch "$D/.apg_paused"
OUT="$D/out.txt"; run_bc "$D"
ok=1
# Exactly one suppression source: every "suppressed" mention in the
# output is the discharge-session one (log line + its stdout echo,
# mirroring the v1.1 APG gate's log/printf pair); the APG line must
# not appear at all.
nsup_all=$(grep -c "suppressed" "$OUT")
nsup_sess=$(grep -c "discharge session: resume suppressed" "$OUT")
if [ "$RC" -eq 0 ] && has "discharge session: resume suppressed (target=85)" \
        && ! has "WOULD WRITE" && ! has "APG paused" \
        && [ "$nsup_all" -eq "$nsup_sess" ] && [ "$nsup_sess" -ge 1 ]; then ok=0; fi
report 10 $ok "discharge session: resume suppressed (target=85)"

# 11. Config DISCHARGE_MAX_MINUTES=60 + session started 120 min ago
#     + 95/94 -> WOULD WRITE 100 (config-driven staleness).
D="$SCRATCH/case11"; mkcfg "$D" 95 94 "DISCHARGE_MAX_MINUTES=60"
mksession "$D" user 85 "$((NOW - 120 * 60))"
OUT="$D/out.txt"; run_bc "$D"
ok=1
if [ "$RC" -eq 0 ] && has "WOULD WRITE BCLM=100" \
        && has "discharge session: invalid file ignored"; then ok=0; fi
report 11 $ok "WOULD WRITE BCLM=100"

echo "== summary: PASS=$PASS FAIL=$FAIL =="
if [ "$FAIL" -eq 0 ] && [ "$PASS" -eq 11 ]; then
    exit 0
fi
exit 1
