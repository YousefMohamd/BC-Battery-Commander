#!/bin/bash
# test_calibration.sh — T1 sandbox suite for the calibration build
# (2026-11-14, calibrate-design.md sections 6-8).
#
# Part A drives bc-watchdog.sh (discharge monitor + calibration run
# supervisor) exactly like test_discharge.sh: sandbox state dir,
# stubbed commands first on PATH, a fake clock, and scripted battery
# control files (pct/cap/ext/ischg/amp/volt/temp/load/bclm). The
# supervisor's dispatch calls land on a STUB dispatch.sh in the
# sandbox state dir that records calls and applies config/posture
# to the sandbox only. No real battery, no SMC writes, no sudo.
#
# Part B drives the real dispatch.sh like test_charge_persistence.sh
# (BC_DASH/BC_BUILD_DIR sandboxes, stubbed osascript/pmset/sudo):
# auto-profile bands, start refusals, cancel/resume markers, the
# power-posture actions, the Smart Discharge guard, and the
# supervisor's config primitive.
#
# The LIVE state dir is never touched (config md5 asserted at the
# end). Prints PASS/FAIL per case; exit 0 only if all pass.

set -u
SRC_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SRC_DIR/../.." && pwd)
HELPERS_DIR="$REPO_ROOT/src/daemon-helpers"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi }
check_grep(){ if grep -q "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 (pattern [$2] not in $3)"; fi }
check_absent(){ if [ ! -e "$2" ]; then ok "$1"; else bad "$1 ($2 still exists)"; fi }
check_present(){ if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 missing)"; fi }

REAL_HOME="$HOME"
LIVE_CFG_MD5_BEFORE=$(md5 -q "$REAL_HOME/.battery-commander/config" 2>/dev/null || echo "none")

# =================================================================
# PART A — watchdog supervisor sandbox
# =================================================================
TEST_ROOT=$(mktemp -d /tmp/bc-calibration-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
DASH="$TEST_ROOT/.battery-commander"
BIN="$TEST_ROOT/bin"
mkdir -p "$DASH" "$BIN"
export TEST_ROOT

write_config() {
    printf 'LAST_UPPER=86\nLAST_LOWER=85\nSAILING=false\nSAIL_GAP=1\n' > "$DASH/config"
}
write_config
printf 'idle\n' > "$DASH/.active_mode"

# --- control files ---
echo "88"   > "$TEST_ROOT/pct"
echo "880"  > "$TEST_ROOT/cap"
echo "No"   > "$TEST_ROOT/ext"
echo "No"   > "$TEST_ROOT/ischg"
echo "0"    > "$TEST_ROOT/amp"
echo "12193" > "$TEST_ROOT/volt"
echo "30.0" > "$TEST_ROOT/pack_temp"
echo "1"    > "$TEST_ROOT/load"
echo "10"   > "$TEST_ROOT/bclm"
BASE_EPOCH=1763000000
echo "$BASE_EPOCH" > "$TEST_ROOT/now"
echo "$BASE_EPOCH" > "$TEST_ROOT/resume_mtime"

cat > "$BIN/date" <<'EOF'
#!/bin/bash
N="${TEST_ROOT}/now"
case "$*" in
  *%s*) cat "$N" 2>/dev/null || echo 0 ;;
  *%H:%M:%S*) echo "2026-01-01 12:00:00" ;;
  *%H*) echo 12 ;;
  *) echo "2026-01-01 12:00:00" ;;
esac
EOF
chmod +x "$BIN/date"

cat > "$BIN/ioreg" <<'EOF'
#!/bin/bash
[ -f "$TEST_ROOT/ioreg_fail" ] && exit 1
cat <<X
"CurrentCapacity" = $(cat "$TEST_ROOT/cap" 2>/dev/null || echo 880)
"MaxCapacity" = 1000
"Voltage" = $(cat "$TEST_ROOT/volt" 2>/dev/null || echo 12193)
"DesignCapacity" = 6900
"CycleCount" = 568
"IsCharging" = $(cat "$TEST_ROOT/ischg" 2>/dev/null || echo No)
"ExternalConnected" = $(cat "$TEST_ROOT/ext" 2>/dev/null || echo No)
"Amperage" = $(cat "$TEST_ROOT/amp" 2>/dev/null || echo 0)
"NotChargingReason"=0
X
EOF
chmod +x "$BIN/ioreg"

cat > "$BIN/bc-candidates" <<'EOF'
#!/bin/bash
echo "BCLM: size=1 type=ui8 bytes=64 value=$(cat "$TEST_ROOT/bclm" 2>/dev/null || echo 10)"
EOF
chmod +x "$BIN/bc-candidates"

cat > "$BIN/bc-status" <<'EOF'
#!/bin/bash
echo "Capacity: $(cat "$TEST_ROOT/pct" 2>/dev/null || echo 88).0%"
echo "Voltage: 12.193V"
echo "TempBatteryPack: $(cat "$TEST_ROOT/pack_temp" 2>/dev/null || echo 30.0)°C"
echo "TempCPU: 45.0°C"
echo "Health: 75.5%"
echo "Cycle: 568"
echo "BCLM: $(cat "$TEST_ROOT/bclm" 2>/dev/null || echo 10)"
echo "Backend: bclm"
echo "READ-ONLY DONE"
EOF
chmod +x "$BIN/bc-status"

cat > "$BIN/bc-limit" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--probe" ]; then echo "backend=bclm"; fi
exit 0
EOF
chmod +x "$BIN/bc-limit"

printf '#!/bin/bash\nexit 0\n' > "$BIN/launchctl"; chmod +x "$BIN/launchctl"

cat > "$BIN/sysctl" <<'EOF'
#!/bin/bash
L=$(cat "$TEST_ROOT/load" 2>/dev/null || echo 1)
echo "$L $L $L"
EOF
chmod +x "$BIN/sysctl"

for c in pmset sleep pkill osascript; do
    printf '#!/bin/bash\nexit 0\n' > "$BIN/$c"; chmod +x "$BIN/$c"
done
printf '#!/bin/bash\nexit 1\n' > "$BIN/pgrep"; chmod +x "$BIN/pgrep"

cat > "$BIN/stat" <<'EOF'
#!/bin/bash
case "$*" in
  *calibration_resume_request*) cat "$TEST_ROOT/resume_mtime" 2>/dev/null || echo 0 ;;
  *) cat "$TEST_ROOT/now" 2>/dev/null || echo 0 ;;
esac
EOF
chmod +x "$BIN/stat"

NOTIF_HITS="$TEST_ROOT/notifier_hits"
: > "$NOTIF_HITS"
NOTIF_DIR="$TEST_ROOT/terminal-notifier.app/Contents/MacOS"
mkdir -p "$NOTIF_DIR"
cat > "$NOTIF_DIR/terminal-notifier" <<'EOF'
#!/bin/bash
echo "$*" >> "$TEST_ROOT/notifier_hits"
exit 0
EOF
chmod +x "$NOTIF_DIR/terminal-notifier"

for _c in sailing_tracker.sh adaptive.sh ensure_limit.sh system_guard.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$DASH/$_c"
    chmod +x "$DASH/$_c"
done

# Stub dispatch.sh — the supervisor's only delegate. Records calls,
# applies config/posture inside the sandbox.
cat > "$DASH/dispatch.sh" <<'EOF'
#!/bin/bash
D="${BC_DASH:?}"
echo "$*" >> "$TEST_ROOT/dispatch_calls"
case "$1" in
  calibration_apply_limit)
    [ -f "$TEST_ROOT/apply_fail" ] && exit 1
    grep -v '^LAST_UPPER=\|^LAST_LOWER=' "$D/config" > "$D/config.tmp" 2>/dev/null || : > "$D/config.tmp"
    printf 'LAST_UPPER=%s\nLAST_LOWER=%s\n' "$2" "$3" >> "$D/config.tmp"
    mv "$D/config.tmp" "$D/config"
    exit 0 ;;
  calibration_posture_on)
    printf 'PREV_SLEEP_B=18\nASSERTED=1\n' > "$D/.calibration_posture_state"
    exit 0 ;;
  calibration_posture_off)
    rm -f "$D/.calibration_posture_state"
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$DASH/dispatch.sh"
: > "$TEST_ROOT/dispatch_calls"

cp "$HELPERS_DIR/state_guard.sh" "$DASH/state_guard.sh" \
    || { echo "FAIL: state_guard.sh not found"; exit 1; }
SCRIPT_SRC="$HELPERS_DIR/bc-watchdog.sh"
[ -f "$SCRIPT_SRC" ] || { echo "FAIL: bc-watchdog.sh not found"; exit 1; }
SCRIPT_RUN="$TEST_ROOT/bc-watchdog.sh"
export BC_DASH="$DASH"
export SG_DIR="$DASH"
sed \
    -e "s|^BC_BUILD_DIR=.*|BC_BUILD_DIR=\"$BIN\"|" \
    -e "s|/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier|$NOTIF_DIR/terminal-notifier|g" \
    "$SCRIPT_SRC" > "$SCRIPT_RUN"
chmod +x "$SCRIPT_RUN"
export PATH="$BIN:$PATH"
export HOME="$TEST_ROOT"

# --- drivers ---
NOW=$BASE_EPOCH
tick() {
    NOW=$((NOW + 60))
    echo "$NOW" > "$TEST_ROOT/now"
    bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
}
set_pct() {
    echo "$1" > "$TEST_ROOT/pct"
    if [ -n "${2:-}" ]; then echo "$2" > "$TEST_ROOT/cap"; else echo $(( $1 * 10 )) > "$TEST_ROOT/cap"; fi
}
set_ext()   { echo "$1" > "$TEST_ROOT/ext"; }
set_ischg() { echo "$1" > "$TEST_ROOT/ischg"; }
set_volt()  { echo "$1" > "$TEST_ROOT/volt"; }
run_val()   { grep "^$1=" "$DASH/.calibration_run" 2>/dev/null | tail -1 | cut -d= -f2; }
cfg_val()   { grep "^$1=" "$DASH/config" 2>/dev/null | tail -1 | cut -d= -f2; }
forge_run() {
    grep -v "^$1=" "$DASH/.calibration_run" > "$DASH/.cr.tmp" 2>/dev/null || : > "$DASH/.cr.tmp"
    printf '%s=%s\n' "$1" "$2" >> "$DASH/.cr.tmp"
    mv "$DASH/.cr.tmp" "$DASH/.calibration_run"
}
write_run() { # leg [extra k=v ...] — config matches the leg's EXPECT
    local _leg=$1; shift
    local _phase=base _eu=86 _el=85
    case "$_leg" in L0) ;; *) _phase=temp; _eu=100; _el=99 ;; esac
    {
        printf 'RUN_ID=TESTRUN1\nLEG=%s\nPROFILE=mid\nFLOOR=10\nABS_FLOOR=8\nSUPERVISION=30\n' "$_leg"
        printf 'HEALTH_X10=755\nCYCLES=568\nBASE_MAXCAP=5209\nBASE_UPPER=86\nBASE_LOWER=85\n'
        printf 'STARTED=%s\nHEARTBEAT=%s\nCONFIG_PHASE=%s\nEXPECT_U=%s\nEXPECT_L=%s\n' "$NOW" "$NOW" "$_phase" "$_eu" "$_el"
        printf 'LEG_STARTED=%s\nL2_STARTED=%s\n' "$NOW" "$NOW"
        local _kv; for _kv in "$@"; do printf '%s\n' "$_kv"; done
    } > "$DASH/.calibration_run"
    if [ "$_phase" = "temp" ]; then
        printf 'LAST_UPPER=100\nLAST_LOWER=99\nSAILING=false\nSAIL_GAP=1\n' > "$DASH/config"
    else
        write_config
    fi
    printf 'calibration\n' > "$DASH/.active_mode"
}
begin_case() {
    rm -f "$DASH/.discharge_session" "$DASH/.discharge_session.shadow" \
        "$DASH/.discharge_shadow" "$DASH/.discharge_state" \
        "$DASH/.discharge_cooldown" "$DASH/discharge.log" \
        "$DASH/calibration.log" "$DASH/.calibration_run" \
        "$DASH/.calibration_cancel_request" "$DASH/.calibration_resume_request" \
        "$DASH/.calibration_posture_state" "$DASH/.calibration_data_fails" \
        "$DASH/.apg_paused" "$DASH/.apg_state" "$DASH/.bc_apg_init" \
        "$DASH/.last_wake" "$DASH/.enforce_state" \
        "$DASH/.enforce_last_discharge" "$DASH/.enforce_last_critical" \
        "$DASH/.enforce_crit_count" "$DASH/.drift_state" \
        "$DASH/.overshoot_state" "$DASH/.watchdog_prev_pct" \
        "$DASH/.watchdog_prev_cur" "$DASH/.daemon_check_state" \
        "$DASH/.wake_age_unknown_last" "$DASH/.bclm_unreadable_last" \
        "$DASH/.charge_target"
    rm -rf "$DASH/.notify" "$DASH/reports"; rm -f "$DASH"/.notify_* 2>/dev/null
    printf 'idle\n' > "$DASH/.active_mode"
    write_config
    set_pct 88; set_ext No; set_ischg No; set_volt 12193
    echo "0" > "$TEST_ROOT/amp"
    echo "30.0" > "$TEST_ROOT/pack_temp"; echo "1" > "$TEST_ROOT/load"
    echo "10" > "$TEST_ROOT/bclm"
    rm -f "$TEST_ROOT/ioreg_fail" "$TEST_ROOT/apply_fail"
    : > "$NOTIF_HITS"; : > "$TEST_ROOT/dispatch_calls"
}

echo "=== PART A: run supervisor ==="

# --- A1: happy path L0 -> L5 ---
begin_case
write_run L0
set_ext Yes; set_pct 86
tick
check "A1 L0->L1 leg" "L1" "$(run_val LEG)"
check "A1 temp config applied" "100" "$(cfg_val LAST_UPPER)"
set_pct 100; set_ischg No
tick; tick; tick
check "A1 L1->L1R at verified full" "L1R" "$(run_val LEG)"
check_grep "A1 ENDPOINT_FULL logged" "ENDPOINT_FULL leg=L1" "$DASH/calibration.log"
forge_run REST_REMAIN 120
tick; tick
check "A1 L1R->L2 after rest" "L2" "$(run_val LEG)"
set_ext No; set_pct 96
tick
check_present "A1 segment issued" "$DASH/.discharge_session"
check "A1 segment mode" "calibrate" "$(grep '^MODE=' "$DASH/.discharge_session" | cut -d= -f2)"
check "A1 segment target = floor" "10" "$(grep '^TARGET=' "$DASH/.discharge_session" | cut -d= -f2)"
check_present "A1 posture asserted" "$DASH/.calibration_posture_state"
set_pct 92; tick
set_pct 88; tick
# Descend in <= 4-point steps: a >= 5-point one-tick move is a gauge
# jump to the monitor (deferral freezes its LAST_PCT by design), so
# realistic drain steps are required — production drain is ~1%/tick.
for _p in 84 80 76 72 68 64 60 56 52 48 44 40 36 32 28 24 20 16 12; do set_pct $_p; tick; done
set_volt 10500; set_pct 10; tick
set_pct 10; tick
check "A1 floor reached -> L3" "L3" "$(run_val LEG)"
check_grep "A1 ENDPOINT_FLOOR logged" "ENDPOINT_FLOOR" "$DASH/calibration.log"
check_absent "A1 posture released at floor" "$DASH/.calibration_posture_state"
set_ext Yes
tick
check_present "A1 park session issued" "$DASH/.discharge_session"
check "A1 park flag" "1" "$(grep '^PARK=' "$DASH/.discharge_session" | cut -d= -f2)"
forge_run REST_REMAIN 60
tick
check "A1 L3->L4 after low rest" "L4" "$(run_val LEG)"
check_absent "A1 park session removed" "$DASH/.discharge_session"
set_pct 100; set_ischg No
tick; tick; tick
check "A1 L4->L5 at verified full" "L5" "$(run_val LEG)"
forge_run REST_REMAIN 60
tick
check_absent "A1 run file removed at close-out" "$DASH/.calibration_run"
check "A1 config restored" "86" "$(cfg_val LAST_UPPER)"
check_grep "A1 RUN_COMPLETE logged" "RUN_COMPLETE" "$DASH/calibration.log"
check_present "A1 run report written" "$DASH/reports/calibration-TESTRUN1.md"

# --- A2: abort at L1 (leg bound) ---
begin_case
write_run L1 "LEG_STARTED=$((NOW - 21601))"
set_ext Yes; set_pct 90; set_ischg Yes
tick
check_absent "A2 run removed" "$DASH/.calibration_run"
check_grep "A2 abort reason" "RUN_ABORT reason=leg-timeout leg=L1" "$DASH/calibration.log"
check "A2 config restored" "86" "$(cfg_val LAST_UPPER)"

# --- A3: abort at L2 (AC-flip episode) ---
begin_case
write_run L2 "SEG_STARTED=424242" "SEG_LOG_LINE=0"
printf '[2026-01-01 12:00:00] [REAL] EPISODE id=424242 result=aborted reason=ac-flip start_pct=50 end_pct=48\n' > "$DASH/discharge.log"
set_ext No; set_pct 48
tick
check_absent "A3 run removed" "$DASH/.calibration_run"
check_grep "A3 abort reason" "RUN_ABORT reason=ac-flip" "$DASH/calibration.log"
check "A3 config restored" "86" "$(cfg_val LAST_UPPER)"

# --- A4: abort at L3 (leg bound) ---
begin_case
write_run L3 "LEG_STARTED=$((NOW - 7201))" "REST_REMAIN=1800"
set_ext Yes; set_pct 10
tick
check_absent "A4 run removed" "$DASH/.calibration_run"
check_grep "A4 abort reason" "RUN_ABORT reason=leg-timeout leg=L3" "$DASH/calibration.log"

# --- A5: abort at L4 (APG pause over 15 min) ---
# REWORKED by the temp gate (full-fix 2026-11-15): the abort clock
# now runs only on a THERMAL pause, so the pause is driven with
# pack_temp 43 (APG red via temp) instead of load 7 — a load-only
# pause no longer aborts a charge leg.
begin_case
write_run L4 "APG_SINCE=$((NOW - 901))"
echo "43.0" > "$TEST_ROOT/pack_temp"
set_ext Yes; set_pct 90; set_ischg Yes
tick
check_absent "A5 run removed" "$DASH/.calibration_run"
check_grep "A5 abort reason" "RUN_ABORT reason=apg leg=L4" "$DASH/calibration.log"

# --- A6: stale run heartbeat is revived, not fatal ---
begin_case
write_run L1 "HEARTBEAT=$((NOW - 3600))"
set_ext Yes; set_pct 90; set_ischg Yes
tick
check_present "A6 run survives" "$DASH/.calibration_run"
check "A6 heartbeat refreshed" "$NOW" "$(run_val HEARTBEAT)"
check "A6 still L1" "L1" "$(run_val LEG)"

# --- A7: sleep checkpoint + resume gates ---
begin_case
write_run L2
set_ext No; set_pct 50
tick
_SEG=$(run_val SEG_STARTED)
check_present "A7 segment issued" "$DASH/.discharge_session"
rm -f "$DASH/.discharge_session"
printf '[2026-01-01 12:00:00] [REAL] EPISODE id=%s result=ended-by-sleep reason=sleep start_pct=50 end_pct=49\n' "$_SEG" >> "$DASH/discharge.log"
echo "$NOW" > "$DASH/.last_wake"
tick
check "A7 checkpoint waiting" "1" "$(run_val WAITING)"
check_grep "A7 checkpoint logged" "RUN_CHECKPOINT reason=sleep" "$DASH/calibration.log"
check_absent "A7 posture released at checkpoint" "$DASH/.calibration_posture_state"
# gate 1: wake too recent (< 120 s)
echo "$NOW" > "$TEST_ROOT/resume_mtime"
echo "$NOW" > "$DASH/.calibration_resume_request"
echo "$((NOW - 30))" > "$DASH/.last_wake"
set_pct 30
tick
check "A7 resume refused (wake window)" "1" "$(run_val WAITING)"
check_absent "A7 no segment yet (wake)" "$DASH/.discharge_session"
# gate 2: pct below floor+15
echo "$((NOW - 300))" > "$DASH/.last_wake"
set_pct 20
tick
check "A7 resume refused (pct < floor+15)" "1" "$(run_val WAITING)"
check_absent "A7 no segment yet (pct)" "$DASH/.discharge_session"
# all gates pass
set_pct 30
tick
check "A7 resumed" "0" "$(run_val WAITING)"
check_present "A7 segment re-issued" "$DASH/.discharge_session"

# --- A8: stale segment after supervisor death -> safe abort ---
begin_case
_STALE_STARTED=$((NOW - 15000))
write_run L2 "SEG_STARTED=$_STALE_STARTED" "SEG_LOG_LINE=0"
printf 'MODE=calibrate\nTARGET=10\nSTARTED=%s\nRUN=TESTRUN1\nSTARTER=supervisor\n' "$_STALE_STARTED" > "$DASH/.discharge_session"
set_ext No; set_pct 50
tick
check_absent "A8 run removed" "$DASH/.calibration_run"
check_grep "A8 abort reason" "RUN_ABORT reason=segment-refused-stale" "$DASH/calibration.log"
check "A8 config restored" "86" "$(cfg_val LAST_UPPER)"

# --- A9: corrupt run file = no run ---
begin_case
printf 'LAST_UPPER=100\nLAST_LOWER=99\nSAILING=false\nSAIL_GAP=1\n' > "$DASH/config"
printf 'garbage\x01\x02not-a-run' > "$DASH/.calibration_run"
printf 'MODE=calibrate\nTARGET=10\nSTARTED=%s\nRUN=TESTRUN1\n' "$NOW" > "$DASH/.discharge_session"
tick
check_absent "A9 corrupt run deleted" "$DASH/.calibration_run"
check_absent "A9 ghost session deleted" "$DASH/.discharge_session"
check_grep "A9 corrupt logged" "RUN_CORRUPT" "$DASH/calibration.log"
check "A9 config untouched (rule 11)" "100" "$(cfg_val LAST_UPPER)"

# --- A10: mid-run user config change supersedes ---
begin_case
write_run L1
printf 'LAST_UPPER=90\nLAST_LOWER=89\nSAILING=false\nSAIL_GAP=1\n' > "$DASH/config"
set_ext Yes; set_pct 90; set_ischg Yes
tick
check_absent "A10 run removed" "$DASH/.calibration_run"
check_grep "A10 superseded" "RUN_ABORT reason=superseded" "$DASH/calibration.log"
check "A10 user config survives" "90" "$(cfg_val LAST_UPPER)"

# --- A11: two unreadable ticks abort the run ---
begin_case
write_run L1
touch "$TEST_ROOT/ioreg_fail"
tick; tick
check_absent "A11 run removed" "$DASH/.calibration_run"
check_grep "A11 abort reason" "RUN_ABORT reason=data-unreadable" "$DASH/calibration.log"
check "A11 config restored" "86" "$(cfg_val LAST_UPPER)"

# --- A12: routine session refused while a run is live (rule 10) ---
begin_case
write_run L1
printf 'MODE=user\nTARGET=85\nSTARTED=%s\nSTARTER=test\n' "$NOW" > "$DASH/.discharge_session"
set_ext Yes; set_pct 90; set_ischg Yes
tick
check_absent "A12 routine session refused+removed" "$DASH/.discharge_session"
check_grep "A12 refusal logged" "SESSION_REFUSED reason=calibration" "$DASH/discharge.log"
check_present "A12 run unaffected" "$DASH/.calibration_run"

# --- A13: calibrate session refused when the run heartbeat is stale ---
# The monitor refuses + deletes the forged session (its heartbeat
# check runs before the supervisor refreshes anything); the
# supervisor then issues its OWN fresh segment in the same tick,
# so assert the refusal in the log and that no file still carries
# the forged STARTED.
begin_case
write_run L2 "HEARTBEAT=$((NOW - 3600))"
printf 'MODE=calibrate\nTARGET=10\nSTARTED=%s\nRUN=TESTRUN1\nSTARTER=supervisor\n' "$NOW" > "$DASH/.discharge_session"
_FORGED_STARTED=$NOW
set_ext No; set_pct 50
tick
check_grep "A13 invalid logged" "SESSION_INVALID" "$DASH/discharge.log"
_NOW_STARTED=$(grep '^STARTED=' "$DASH/.discharge_session" 2>/dev/null | cut -d= -f2)
[ "${_NOW_STARTED:-$_FORGED_STARTED}" != "$_FORGED_STARTED" ] \
    && ok "A13 forged session gone (replaced by supervisor issue or absent)" \
    || bad "A13 forged session gone (STARTED still $_FORGED_STARTED)"

# --- A14: gauge floor unconfirmed -> continuation at ABS_FLOOR ---
begin_case
write_run L2
set_ext No; set_volt 12500; set_pct 60
tick
check_present "A14 segment issued" "$DASH/.discharge_session"
tick; set_pct 56; tick
set_pct 52; tick
for _p in 48 44 40 36 32 28 24 20 16 12; do set_pct $_p; tick; done
set_pct 10; tick
set_pct 10; tick
check_grep "A14 finding logged" "FINDING gauge-floor-unconfirmed" "$DASH/calibration.log"
tick
check "A14 continuation target = abs floor" "8" "$(grep '^TARGET=' "$DASH/.discharge_session" 2>/dev/null | cut -d= -f2)"
set_pct 9; tick
tick
set_volt 10400; set_pct 8; tick
set_pct 8; tick
check "A14 floor reached at bound -> L3" "L3" "$(run_val LEG)"

# --- A15: L4 completion is checked before the leg bound ---
begin_case
write_run L4 "LEG_STARTED=$((NOW - 28801))" "FULL_TICKS=1"
set_ext Yes; set_pct 100; set_ischg No
tick
check "A15 completed into L5 (not aborted)" "L5" "$(run_val LEG)"

echo ""
echo "=== PART B: dispatch (profile, toggle, posture) ==="

# Part B uses REAL system tools (date/stat/sleep): restore a clean
# PATH so Part A's stubs (fake clock, instant sleep) cannot leak
# into dispatch — its lock watchdog and heartbeat checks depend on
# real time.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# =================================================================
# PART B — dispatch sandbox (mirrors test_charge_persistence.sh)
# =================================================================
TEST_ROOT_B=$(mktemp -d /tmp/bc-calibration-dispatch.XXXXXX)
trap 'rm -rf "$TEST_ROOT" "$TEST_ROOT_B"' EXIT
DASHB="$TEST_ROOT_B/.battery-commander"
BINB="$TEST_ROOT_B/bin"
BUILDB="$TEST_ROOT_B/build"
mkdir -p "$DASHB" "$BINB" "$BUILDB"
export TEST_ROOT_B

cp "$HELPERS_DIR/dispatch.sh" "$DASHB/dispatch.sh"
cp "$HELPERS_DIR/state_guard.sh" "$DASHB/state_guard.sh"
chmod +x "$DASHB/dispatch.sh"
printf 'LAST_UPPER=86\nLAST_LOWER=85\nSAILING=false\nSAIL_GAP=1\n' > "$DASHB/config"
printf 'idle\n' > "$DASHB/.active_mode"
date +%s > "$DASHB/.enforce_hb"

# --- control files ---
echo "720" > "$TEST_ROOT_B/cap"        # 72%
echo "750" > "$TEST_ROOT_B/fcc"        # profile inputs
echo "1000" > "$TEST_ROOT_B/des"
echo "568" > "$TEST_ROOT_B/cyc"
echo "Start Calibration" > "$TEST_ROOT_B/osa_answer"
echo "18" > "$TEST_ROOT_B/sleep_b"     # battery-scope sleep minutes
echo "120" > "$TEST_ROOT_B/sleep_a"

cat > "$BINB/ioreg" <<'EOF'
#!/bin/bash
cat <<X
"CurrentCapacity" = $(cat "$TEST_ROOT_B/cap" 2>/dev/null || echo 720)
"MaxCapacity" = 1000
"IsCharging" = No
"ExternalConnected" = Yes
"Amperage" = 0
"NotChargingReason"=0
X
EOF
chmod +x "$BINB/ioreg"

cat > "$BINB/osascript" <<'EOF'
#!/bin/bash
case "$*" in
  *-e*) exit 0 ;;
esac
cat > /dev/null 2>&1 || true
cat "$TEST_ROOT_B/osa_answer" 2>/dev/null || echo ""
exit 0
EOF
chmod +x "$BINB/osascript"

cat > "$BINB/sudo" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-n" ] && shift
exec "$@"
EOF
chmod +x "$BINB/sudo"

cat > "$BINB/pmset" <<'EOF'
#!/bin/bash
echo "pmset $*" >> "$TEST_ROOT_B/pmset_calls"
case "$*" in
  "-g custom")
    printf 'Battery Power:\n sleep                %s\n displaysleep         10\nAC Power:\n sleep                %s\n' \
        "$(cat "$TEST_ROOT_B/sleep_b" 2>/dev/null || echo 18)" \
        "$(cat "$TEST_ROOT_B/sleep_a" 2>/dev/null || echo 120)"
    ;;
  "-b sleep "*)
    echo "${3:-}" > "$TEST_ROOT_B/sleep_b"
    ;;
esac
exit 0
EOF
chmod +x "$BINB/pmset"

for c in launchctl pkill; do
    printf '#!/bin/bash\nexit 0\n' > "$BINB/$c"; chmod +x "$BINB/$c"
done

cat > "$BUILDB/bc-candidates" <<'EOF'
#!/bin/bash
echo "BCLM: size=1 type=ui8 bytes=0a value=10"
EOF
chmod +x "$BUILDB/bc-candidates"
cat > "$BUILDB/bc-status" <<'EOF'
#!/bin/bash
echo "Capacity: 72.0%"
echo "Voltage: 12.193V"
echo "TempBatteryPack: 30.0°C"
echo "Health: 75.0%"
echo "Cycle: $(cat "$TEST_ROOT_B/cyc" 2>/dev/null || echo 568)"
echo "FullCharge: $(cat "$TEST_ROOT_B/fcc" 2>/dev/null || echo 750) mAh"
echo "Design: $(cat "$TEST_ROOT_B/des" 2>/dev/null || echo 1000) mAh"
echo "BCLM: 10"
echo "Backend: bclm"
echo "READ-ONLY DONE"
EOF
chmod +x "$BUILDB/bc-status"
cat > "$BUILDB/bc-limit" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--probe" ]; then echo "backend=bclm"; fi
exit 0
EOF
chmod +x "$BUILDB/bc-limit"

run_dispatch() { # action [args...] — returns dispatch's exit code
    BC_DASH="$DASHB" BC_BUILD_DIR="$BUILDB" BC_PMSET="$BINB/pmset" \
    PATH="$BINB:$PATH" HOME="$TEST_ROOT_B" \
        bash "$DASHB/dispatch.sh" "$@" >/dev/null 2>&1
    return $?
}
run_val_b() { grep "^$1=" "$DASHB/.calibration_run" 2>/dev/null | tail -1 | cut -d= -f2; }
reset_b() {
    rm -f "$DASHB/.calibration_run" "$DASHB/.discharge_session" \
        "$DASHB/.calibration_cancel_request" "$DASHB/.calibration_resume_request" \
        "$DASHB/.calibration_posture_state" "$DASHB/.apg_paused"
    printf 'idle\n' > "$DASHB/.active_mode"
    date +%s > "$DASHB/.enforce_hb"
    echo "Start Calibration" > "$TEST_ROOT_B/osa_answer"
}

# --- B1: auto-profile bands (85% / 75% / 55% / cycles 1200) ---
echo "850" > "$TEST_ROOT_B/fcc"; echo "100" > "$TEST_ROOT_B/cyc"
reset_b; run_dispatch calibrate
check "B1 high band floor" "10" "$(run_val_b FLOOR)"
check "B1 high band abs" "8" "$(run_val_b ABS_FLOOR)"
check "B1 high band supervision" "0" "$(run_val_b SUPERVISION)"
check "B1 high band name" "high" "$(run_val_b PROFILE)"
check "B1 run starts at L0" "L0" "$(run_val_b LEG)"
echo "750" > "$TEST_ROOT_B/fcc"; echo "568" > "$TEST_ROOT_B/cyc"
reset_b; run_dispatch calibrate
check "B1 mid band floor" "10" "$(run_val_b FLOOR)"
check "B1 mid band supervision" "30" "$(run_val_b SUPERVISION)"
check "B1 mid band name" "mid" "$(run_val_b PROFILE)"
check "B1 mid health_x10" "750" "$(run_val_b HEALTH_X10)"
echo "550" > "$TEST_ROOT_B/fcc"
reset_b; run_dispatch calibrate
check "B1 low band floor" "15" "$(run_val_b FLOOR)"
check "B1 low band abs" "12" "$(run_val_b ABS_FLOOR)"
check "B1 low band supervision" "35" "$(run_val_b SUPERVISION)"
echo "850" > "$TEST_ROOT_B/fcc"; echo "1200" > "$TEST_ROOT_B/cyc"
reset_b; run_dispatch calibrate
check "B1 cycles>1000 forces low floor" "15" "$(run_val_b FLOOR)"
check "B1 cycles>1000 band name" "low" "$(run_val_b PROFILE)"

# --- B2: start refused while a discharge session is active ---
reset_b
printf 'MODE=user\nTARGET=85\nSTARTED=1\n' > "$DASHB/.discharge_session"
run_dispatch calibrate
check_absent "B2 no run created over a session" "$DASHB/.calibration_run"

# --- B3: start refused when the watchdog heartbeat is stale ---
reset_b
echo "$(( $(date +%s) - 1000 ))" > "$DASHB/.enforce_hb"
run_dispatch calibrate
check_absent "B3 no run created with stale watchdog" "$DASHB/.calibration_run"

# --- B4: cancel path writes the cancel marker ---
reset_b
printf 'RUN_ID=X1\nLEG=L2\nFLOOR=10\nABS_FLOOR=8\n' > "$DASHB/.calibration_run"
echo "Cancel Calibration" > "$TEST_ROOT_B/osa_answer"
run_dispatch calibrate
check_present "B4 cancel marker written" "$DASHB/.calibration_cancel_request"

# --- B5: resume action only at a checkpoint ---
reset_b
printf 'RUN_ID=X1\nLEG=L2\nWAITING=1\n' > "$DASHB/.calibration_run"
run_dispatch calibrate_resume
check_present "B5 resume marker at checkpoint" "$DASHB/.calibration_resume_request"
rm -f "$DASHB/.calibration_resume_request"
printf 'RUN_ID=X1\nLEG=L2\nWAITING=0\n' > "$DASHB/.calibration_run"
run_dispatch calibrate_resume
check_absent "B5 no resume marker when not waiting" "$DASHB/.calibration_resume_request"

# --- B6: posture on/off round-trip (verified restore) ---
reset_b
echo "18" > "$TEST_ROOT_B/sleep_b"
run_dispatch calibration_posture_on
check "B6 posture_on exit" "0" "$?"
check "B6 battery sleep now 0" "0" "$(cat "$TEST_ROOT_B/sleep_b")"
check "B6 previous value recorded" "18" "$(grep '^PREV_SLEEP_B=' "$DASHB/.calibration_posture_state" | cut -d= -f2)"
run_dispatch calibration_posture_off
check "B6 posture_off exit" "0" "$?"
check "B6 battery sleep restored" "18" "$(cat "$TEST_ROOT_B/sleep_b")"
check_absent "B6 posture state cleared" "$DASHB/.calibration_posture_state"

# --- B7: Smart Discharge refuses over a calibration session ---
reset_b
printf 'MODE=calibrate\nTARGET=10\nSTARTED=1\nRUN=X1\n' > "$DASHB/.discharge_session"
run_dispatch smart_discharge
check_present "B7 calibration session untouched" "$DASHB/.discharge_session"
check_grep "B7 refusal logged" "calibration session active" "$DASHB/actions.log"

# --- B8: the supervisor's config primitive ---
reset_b
run_dispatch calibration_apply_limit 100 99
check "B8 apply exit" "0" "$?"
check "B8 config upper" "100" "$(grep '^LAST_UPPER=' "$DASHB/config" | cut -d= -f2)"
run_dispatch calibration_apply_limit 86 85
check "B8 config restored" "86" "$(grep '^LAST_UPPER=' "$DASHB/config" | cut -d= -f2)"

# --- live state dir untouched ---
LIVE_CFG_MD5_AFTER=$(md5 -q "$REAL_HOME/.battery-commander/config" 2>/dev/null || echo "none")
check "LIVE config untouched by the whole suite" "$LIVE_CFG_MD5_BEFORE" "$LIVE_CFG_MD5_AFTER"

echo ""
echo "test_calibration: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$FAIL"
