#!/bin/bash
# test_discharge.sh — T1 sandbox suite for the discharge-session monitor
# layer in bc-watchdog.sh (discharge build D2, design §§4-8).
#
# Follows the test_bc_watchdog.sh pattern: a sandbox state dir (DASH),
# stubbed external commands first on PATH, and a fake tick driver. The
# battery is fully scripted through control files (pct/cap/ext/ischg/
# amp/temp/load/bclm); state-file epochs are forged instead of sleeping.
# No real battery, no SMC writes, no sudo.
set -u
TEST_ROOT=$(mktemp -d /tmp/bc-discharge-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
DASH="$TEST_ROOT/.battery-commander"
mkdir -p "$DASH"
BIN="$TEST_ROOT/bin"
mkdir -p "$BIN"
export TEST_ROOT
CUM_LOG="$TEST_ROOT/cumulative_discharge.log"
: > "$CUM_LOG"

write_config() {
    printf 'LAST_UPPER=86\nLAST_LOWER=85\nSAILING=false\nSAIL_GAP=1\n' > "$DASH/config"
}
write_config
printf 'idle\n' > "$DASH/.active_mode"

# --- control files ---
echo "88"  > "$TEST_ROOT/pct"
echo "880" > "$TEST_ROOT/cap"
echo "No"  > "$TEST_ROOT/ext"
echo "No"  > "$TEST_ROOT/ischg"
echo "0"   > "$TEST_ROOT/amp"
echo "30.0" > "$TEST_ROOT/pack_temp"
echo "1"   > "$TEST_ROOT/load"
echo "10"  > "$TEST_ROOT/bclm"
BASE_EPOCH=1763000000
echo "$BASE_EPOCH" > "$TEST_ROOT/now"

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
echo "TempBatteryPack: $(cat "$TEST_ROOT/pack_temp" 2>/dev/null || echo 30.0)°C"
echo "TempCPU: 45.0°C"
echo "Health: 75.6%"
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

cat > "$BIN/launchctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN/launchctl"

cat > "$BIN/sysctl" <<'EOF'
#!/bin/bash
L=$(cat "$TEST_ROOT/load" 2>/dev/null || echo 1)
echo "$L $L $L"
EOF
chmod +x "$BIN/sysctl"

for c in pmset sleep pkill osascript; do
    printf '#!/bin/bash\nexit 0\n' > "$BIN/$c"; chmod +x "$BIN/$c"
done
cat > "$BIN/pgrep" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$BIN/pgrep"
cat > "$BIN/stat" <<'EOF'
#!/bin/bash
cat "$TEST_ROOT/now" 2>/dev/null || echo 0
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

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS_DIR="$SRC_DIR/../../src/daemon-helpers"
[ -d "$HELPERS_DIR" ] || HELPERS_DIR="$SRC_DIR"
cp "$HELPERS_DIR/state_guard.sh" "$DASH/state_guard.sh" \
    || { echo "FAIL: state_guard.sh not found in $HELPERS_DIR"; exit 1; }
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
set_pct() { # pct [cap] — cap defaults to pct*10 (flat, consistent)
    echo "$1" > "$TEST_ROOT/pct"
    if [ -n "${2:-}" ]; then echo "$2" > "$TEST_ROOT/cap"; else echo $(( $1 * 10 )) > "$TEST_ROOT/cap"; fi
}
set_ext() { echo "$1" > "$TEST_ROOT/ext"; }
write_session() { # target started [file]
    local _f="${3:-$DASH/.discharge_session}"
    printf 'MODE=user\nTARGET=%s\nSTARTED=%s\nSTARTER=test\n' "$1" "$2" > "$_f"
}
write_session_mode() { # mode target started [file]
    local _f="${4:-$DASH/.discharge_session}"
    printf 'MODE=%s\nTARGET=%s\nSTARTED=%s\nSTARTER=test\n' "$1" "$2" "$3" > "$_f"
}
forge_state() { # key value — rewrite one key in .discharge_state
    grep -v "^$1=" "$DASH/.discharge_state" > "$DASH/.ds.tmp" 2>/dev/null || : > "$DASH/.ds.tmp"
    printf '%s=%s\n' "$1" "$2" >> "$DASH/.ds.tmp"
    mv "$DASH/.ds.tmp" "$DASH/.discharge_state"
}
state_val() { grep "^$1=" "$DASH/.discharge_state" 2>/dev/null | cut -d= -f2; }
config_sig() {
    if command -v md5 >/dev/null 2>&1; then md5 -q "$DASH/config" 2>/dev/null
    else md5sum "$DASH/config" 2>/dev/null | awk '{print $1}'; fi
}

# --- assertion helpers ---
FAIL=0; PASS_COUNT=0; FAIL_COUNT=0; CASE_OK=1; CASE_NAME=""
begin_case() {
    CASE_NAME="$1"; CASE_OK=1
    [ -f "$DASH/discharge.log" ] && cat "$DASH/discharge.log" >> "$CUM_LOG"
    rm -f "$DASH/.discharge_session" "$DASH/.discharge_session.shadow" \
        "$DASH/.discharge_shadow" "$DASH/.discharge_state" \
        "$DASH/.discharge_intent" "$DASH/.discharge_intent_block" \
        "$DASH/.calibration_run" "$DASH/.calibration_cancel_request" \
        "$DASH/.discharge_cooldown" "$DASH/discharge.log" \
        "$DASH/.apg_paused" "$DASH/.apg_state" "$DASH/.bc_apg_init" \
        "$DASH/.last_wake" "$DASH/.enforce_state" \
        "$DASH/.enforce_last_discharge" "$DASH/.enforce_last_critical" \
        "$DASH/.enforce_crit_count" "$DASH/.drift_state" \
        "$DASH/.overshoot_state" "$DASH/.watchdog_prev_pct" \
        "$DASH/.watchdog_prev_cur" "$DASH/.daemon_check_state" \
        "$DASH/.wake_age_unknown_last" "$DASH/.bclm_unreadable_last" \
        "$DASH/.charge_target"
    rm -rf "$DASH/.notify"; rm -f "$DASH"/.notify_* 2>/dev/null
    printf 'idle\n' > "$DASH/.active_mode"
    write_config
    set_pct 88; set_ext No
    echo "No" > "$TEST_ROOT/ischg"; echo "0" > "$TEST_ROOT/amp"
    echo "30.0" > "$TEST_ROOT/pack_temp"; echo "1" > "$TEST_ROOT/load"
    echo "10" > "$TEST_ROOT/bclm"
    rm -f "$TEST_ROOT/ioreg_fail"
    : > "$NOTIF_HITS"
}
chk() { # chk <desc> <cmd...>
    local _desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  ok: $_desc"
    else
        echo "  NOT-OK: $_desc"; CASE_OK=0
    fi
}
chk_grep() { chk "$2" grep -q "$1" "$DASH/discharge.log"; }
chk_absent() { chk "$2" test ! -e "$1"; }
chk_present() { chk "$2" test -e "$1"; }
end_case() {
    if [ "$CASE_OK" = "1" ]; then
        echo "PASS: $CASE_NAME"; PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: $CASE_NAME"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAIL=1
    fi
}

DLOG="$DASH/discharge.log"
SESS="$DASH/.discharge_session"
INTENT="$DASH/.discharge_intent"
write_intent() { # target original_started expires
    printf 'TARGET=%s\nORIGINAL_STARTED=%s\nEXPIRES=%s\n' "$1" "$2" "$3" > "$INTENT"
}

# ================= walk =================
begin_case "walk"
write_session 85 "$NOW"
tick                                   # init + confirm 1 (88>85)
chk "armed after tick1" test "$(state_val PHASE)" = "armed"
tick                                   # confirm 2 -> ACTIVE
chk "active after tick2" test "$(state_val PHASE)" = "active"
chk_grep "SESSION_ACTIVE" "SESSION_ACTIVE logged"
set_pct 87; tick
set_pct 86; tick
set_pct 85; tick                       # completion count 1
chk "still active at first 85" test "$(state_val PHASE)" = "active"
set_pct 85; tick                       # completion count 2 -> completed
chk_grep "EPISODE id=.* result=completed" "EPISODE completed"
chk_absent "$SESS" "session file gone after completion"
chk "phase idle after completion" test "$(state_val PHASE)" = "idle"
chk "completion notified" grep -q "Discharge complete" "$NOTIF_HITS"
end_case

# ============ R2 user extended arming (hardening 2026-11-14) ============
# The 2026-11-11 19:00 replay shape (settled gauge jump, no charge
# signal) used to REFUSE a user session outright — and on 2026-11-14
# 21:37 it silently ate Yousef's own Smart Discharge exactly this
# way: on AC in hold, no second signal can EVER exist. Design rule 2
# still stands (never ACTIVE on % alone), but a USER session now
# stays ARMED (extended arming) until a signal appears or the
# reading settles back inside the +2 band. MODE=corrective claims
# keep the hard refusal — see R2-corrective-refusal below.
begin_case "R2-user-extended"
set_pct 93; set_ext Yes                # gauge jump settled at 93, no charge signal
write_session 86 "$NOW"
for i in 1 2 3 4 5 6; do tick; done    # armed budget expires, no second signal
chk "session file kept (extended arming)" test -f "$SESS"
chk_grep "SESSION_ARMING_EXTENDED" "extended arming logged"
chk "no refusal episode" bash -c "! grep -q 'result=refused' '$DLOG'"
chk "no SESSION_ACTIVE yet" bash -c "! grep -q SESSION_ACTIVE '$DLOG'"
set_pct 93 940                         # capacity rising = second signal arrives
tick; tick
chk "active once the signal appears" test "$(state_val PHASE)" = "active"
chk_grep "SESSION_ACTIVE" "SESSION_ACTIVE logged after signal"
end_case

begin_case "R2-user-settle"
set_pct 93; set_ext Yes
write_session 86 "$NOW"
for i in 1 2 3 4 5 6; do tick; done    # extended arming engages
chk_grep "SESSION_ARMING_EXTENDED" "extended arming logged"
set_pct 88                             # settles to UPPER+2: claim dissolves
tick; tick                             # first tick absorbs the >=5pt gauge-jump deferral; second evaluates
chk_grep "OVERSHOOT_CLAIM_CLEARED" "claim dissolve logged"
chk "active after the reading settles" test "$(state_val PHASE)" = "active"
end_case

# ============ R2 corrective refusal (design rule 2, unchanged) ============
begin_case "R2-corrective-refusal"
set_pct 93; set_ext Yes                # gauge jump settled at 93, no charge signal
write_session_mode corrective 86 "$NOW"
for i in 1 2 3 4 5 6; do tick; done    # armed budget expires, no second signal
chk_absent "$SESS" "session file removed"
chk_grep "result=refused reason=no-second-signal" "EPISODE refused no-second-signal"
chk "no SESSION_ACTIVE" bash -c "! grep -q SESSION_ACTIVE '$DLOG'"
end_case

# ================= R2 grant (capacity rising) =================
begin_case "R2-grant"
set_pct 93; set_ext Yes
write_session 86 "$NOW"
tick                                   # init + confirm 1, cap flat
set_pct 93 940                         # capacity rising = second signal
tick                                   # confirm 2 + signal -> ACTIVE
chk "active after rising capacity" test "$(state_val PHASE)" = "active"
chk_grep "SESSION_ACTIVE" "SESSION_ACTIVE logged"
end_case

# ================= R3 gauge symmetry =================
begin_case "R3-gauge"
set_pct 88
write_session 85 "$NOW"
tick                                   # init + confirm 1
set_pct 95; tick                       # +7 gauge tick during ARMED
chk_grep "GAUGE_DEFER" "GAUGE_DEFER logged in ARMED"
chk "still armed after gauge tick" test "$(state_val PHASE)" = "armed"
chk "confirm frozen on gauge tick" test "$(state_val CONFIRM_COUNT)" = "1"
set_pct 88; tick                       # back to real level -> confirm 2 -> ACTIVE
chk "active after gauge clears" test "$(state_val PHASE)" = "active"
set_pct 81; tick                       # -7 gauge tick during ACTIVE
chk "still active after gauge tick" test "$(state_val PHASE)" = "active"
chk "no completion count on gauge tick" test "$(state_val COMP_COUNT)" = "0"
set_pct 84; tick                       # delta vs frozen 88 = 4: real tick, comp 1
set_pct 84; tick                       # comp 2 -> completed
chk_grep "result=completed" "completed after gauge sequence"
end_case

# ================= R4 APG =================
# First half REWORKED by the APG fix (2026-11-14): a MODE=user
# session paused by APG used to be REFUSED reason=apg at
# armed_ticks=6 (the 2026-11-14 22:40 live death). Now the armed
# budget PAUSES for user sessions: no increment, one
# ARMING_BLOCKED_APG line per block episode, normal arming when
# the pause clears. MODE=corrective keeps the refusal — see
# R4d-corrective-apg.
# REWORKED AGAIN by the temp gate (full-fix 2026-11-15): the block
# now applies only to a THERMAL pause (temp >= 38 C). The setups
# below therefore drive the pause with pack_temp 39, not load —
# a load-only pause no longer blocks a user session at all (that
# is case N1). The ACTIVE-phase half is reworked the same way:
# suspension + 15-min abort are thermal-only for user sessions.
begin_case "R4-apg"
echo "39.0" > "$TEST_ROOT/pack_temp"   # APG yellow via TEMP (thermal)
set_pct 88
write_session 85 "$NOW"
touch "$DASH/.apg_paused"           # paused from tick 1 (temp 39 sustains it)
for i in 1 2 3 4 5 6 7 8; do tick; done  # paused throughout, past the old budget
chk_present "$SESS" "user session survives an APG pause (no refusal)"
chk "still armed under the APG block" test "$(state_val PHASE)" = "armed"
chk "armed budget frozen at 0" test "$(state_val ARMED_TICKS)" = "0"
chk "ARMING_BLOCKED_APG logged once per episode" bash -c "[ \$(grep -c ARMING_BLOCKED_APG '$DLOG') -eq 1 ]"
chk "no refusal episode" bash -c "! grep -q 'result=refused' '$DLOG'"
chk "no SESSION_ACTIVE" bash -c "! grep -q SESSION_ACTIVE '$DLOG'"
echo "30.0" > "$TEST_ROOT/pack_temp"; tick     # temp falls: pause clears, arming resumes
chk_grep "ARMING_RESUMED_APG" "arming resumed when the pause cleared"
tick                                   # confirm 2 -> ACTIVE
chk "active after APG clears + confirmation" test "$(state_val PHASE)" = "active"
chk_grep "SESSION_ACTIVE" "SESSION_ACTIVE logged"
# mid-ACTIVE suspension + abort (thermal)
rm -f "$DASH/.discharge_state" "$DLOG"; echo "1" > "$TEST_ROOT/load"
rm -f "$DASH/.apg_paused" "$DASH/.apg_state" "$DASH/.bc_apg_init"
echo "30.0" > "$TEST_ROOT/pack_temp"
set_pct 88
write_session 85 "$NOW"
tick; tick                             # -> ACTIVE
chk "active before APG" test "$(state_val PHASE)" = "active"
echo "39.0" > "$TEST_ROOT/pack_temp"; tick     # thermal APG pause appears
chk_grep "SESSION_SUSPENDED" "SESSION_SUSPENDED logged"
echo "30.0" > "$TEST_ROOT/pack_temp"; tick     # pause clears
chk_grep "SESSION_RESUMED" "SESSION_RESUMED logged"
chk "still active after resume" test "$(state_val PHASE)" = "active"
echo "39.0" > "$TEST_ROOT/pack_temp"; tick     # suspend again
_AS=$(state_val APG_SINCE); forge_state APG_SINCE $(( _AS - 901 ))
tick                                   # 15-min APG abort
chk_grep "result=aborted reason=apg" "aborted reason=apg after 15 min"
chk_absent "$SESS" "session file removed on APG abort"
end_case

# ================= R5 AC flips + cooldown =================
begin_case "R5-flip"
set_pct 88
write_session 85 "$NOW"
tick; tick                             # -> ACTIVE on battery
set_ext Yes; tick                      # flip 1 -> parked
chk_grep "SESSION_PARKED" "parked on first flip"
set_ext No; tick                       # flip 2 within 300s -> abort
chk_grep "result=aborted reason=ac-flip" "aborted reason=ac-flip"
chk_present "$DASH/.discharge_cooldown" "cooldown file written"
_UNTIL=$(grep '^UNTIL=' "$DASH/.discharge_cooldown" | cut -d= -f2)
chk "cooldown ~ +1800s" bash -c "[ $(( $_UNTIL - NOW )) -ge 1700 ] && [ $(( $_UNTIL - NOW )) -le 1800 ]"
write_session 85 "$NOW"                # new session during cooldown
tick
chk_grep "result=refused reason=cooldown" "refused reason=cooldown"
end_case

# ================= R6 validation + floor =================
begin_case "R6-floor"
printf 'MODE=user\nTARGET=10\nSTARTED=%s\nSTARTER=test\n' "$NOW" > "$SESS"
tick
chk_grep "SESSION_INVALID" "SESSION_INVALID for target 10"
chk_absent "$SESS" "invalid session removed"
# floor abort from a forged ACTIVE state
write_session 85 "$NOW"
cat > "$DASH/.discharge_state" <<EOF
PHASE=active
SESSION_STARTED=$NOW
CONFIRM_COUNT=2
CONFIRM_SIGNAL=1
OVERSHOOT_CLAIM=0
ARMED_TICKS=2
COMP_COUNT=0
START_PCT=88
PARKED_TOTAL_S=0
PARK_SINCE=0
APG_SINCE=0
LAST_PCT=22
LAST_CAP=220
LAST_EXT=No
FLIP_TIMES=
UNREADABLE=0
TEMP_MIN=30.0
TEMP_MAX=30.0
LAST_TICK=$NOW
CONFIG_SIG=$(config_sig)
SHADOW_CLAIM_COUNT=0
SHADOW_SIGNAL=0
EOF
set_pct 20
tick
chk_grep "result=aborted reason=floor" "aborted reason=floor at PCT=20"
chk_absent "$SESS" "session removed on floor abort"
end_case

# ================= R8 stale =================
begin_case "R8-stale"
set_pct 88
write_session 85 $((NOW - 18000))      # STARTED 300 min ago
tick
chk_grep "result=refused reason=stale" "refused reason=stale"
chk_absent "$SESS" "stale session removed"
end_case

# ================= R9 cancel =================
begin_case "R9-cancel"
set_pct 88
write_session 85 "$NOW"
tick                                   # ARMED
rm -f "$SESS"                          # user cancel during ARMED
tick
chk_grep "result=cancelled" "EPISODE cancelled during ARMED"
chk_absent "$DASH/.discharge_cooldown" "no cooldown after cancel (armed)"
rm -f "$DASH/.discharge_state" "$DLOG"
write_session 85 "$NOW"
tick; tick                             # ACTIVE
rm -f "$SESS"                          # user cancel during ACTIVE
tick
chk_grep "result=cancelled" "EPISODE cancelled during ACTIVE"
chk_absent "$DASH/.discharge_cooldown" "no cooldown after cancel (active)"
end_case

# ================= R11 bad data =================
begin_case "R11-baddata"
printf 'garbage!!!\nnot a session file\n' > "$SESS"
tick
chk "SESSION_INVALID exactly once" bash -c "[ \$(grep -c SESSION_INVALID '$DLOG') -eq 1 ]"
chk_absent "$SESS" "garbage session removed"
tick
chk "still exactly one SESSION_INVALID" bash -c "[ \$(grep -c SESSION_INVALID '$DLOG') -eq 1 ]"
# unreadable snapshot x2 mid-session
rm -f "$DASH/.discharge_state" "$DLOG"
set_pct 88
write_session 85 "$NOW"
tick                                   # ARMED
touch "$TEST_ROOT/ioreg_fail"
tick                                   # unreadable 1
chk_present "$SESS" "session survives 1 unreadable tick"
tick                                   # unreadable 2 -> abort
chk_grep "result=aborted reason=data-unreadable" "aborted reason=data-unreadable"
chk_absent "$SESS" "session removed on unreadable abort"
rm -f "$TEST_ROOT/ioreg_fail"
end_case

# ================= park timeout =================
begin_case "park-timeout"
set_pct 88; set_ext Yes
write_session 85 "$NOW"
tick; tick                             # -> ACTIVE, parked from the start
chk "active+parked" test "$(state_val PHASE)" = "active"
chk "PARK_SINCE set" bash -c "[ \$(grep '^PARK_SINCE=' '$DASH/.discharge_state' | cut -d= -f2) -gt 0 ]"
forge_state PARK_SINCE $((NOW - 1860)) # 31 min of continuous park
tick
chk_grep "result=incomplete reason=park-timeout" "ended incomplete park-timeout"
chk_absent "$SESS" "session removed on park timeout"
chk "ended notification sent" grep -q "ended incomplete" "$NOTIF_HITS"
end_case

# ================= supersede =================
begin_case "supersede"
set_pct 88
write_session 85 "$NOW"
tick; tick                             # ACTIVE
printf 'LAST_UPPER=86\nLAST_LOWER=84\nSAILING=false\nSAIL_GAP=1\n' > "$DASH/config"
tick                                   # config changed mid-session
chk_grep "result=ended reason=superseded" "ended reason=superseded"
chk_absent "$SESS" "session removed on supersede"
end_case

# ================= shadow mode =================
begin_case "shadow"
touch "$DASH/.discharge_shadow"
set_pct 93; set_ext Yes                # overshoot claim, no second signal
tick; tick
chk_grep "SHADOW_EVAL overshoot pct=93 signal=absent -> corrective entry WOULD REFUSE" "shadow eval refuses gauge pattern"
tick                                   # claim continues: still one eval line
chk "one SHADOW_EVAL only" bash -c "[ \$(grep -c SHADOW_EVAL '$DLOG') -eq 1 ]"
set_pct 86; tick                       # claim resets
set_pct 93 930; tick                   # claim tick 1, cap flat vs 930
set_pct 93 940; tick                   # cap rising -> signal
chk_grep "signal=present -> corrective entry WOULD GRANT" "shadow eval grants with signal"
# shadow session supervision: shadow file only, no notifications
_NH_BEFORE=$(wc -l < "$NOTIF_HITS")
set_pct 88; set_ext No
write_session 85 "$NOW" "$DASH/.discharge_session.shadow"
tick; tick
chk_grep "SESSION_ACTIVE" "shadow session reaches ACTIVE"
chk_absent "$SESS" "real session file never created in shadow mode"
_NH_AFTER=$(wc -l < "$NOTIF_HITS")
chk "no notifications in shadow mode" bash -c "[ $_NH_BEFORE -eq $_NH_AFTER ]"
end_case

# ================= R4b completion beats APG suspend (2026-11-13 live replay) =================
begin_case "R4b-complete-at-target"
set_pct 88
write_session 80 "$NOW"
tick; tick                             # -> ACTIVE (target 80)
chk "active before drain" test "$(state_val PHASE)" = "active"
set_pct 85; tick                       # draining, APG green
set_pct 82; tick
echo "39.0" > "$TEST_ROOT/pack_temp"   # APG turns yellow (THERMAL) on the target tick
set_pct 80; tick                       # pct reaches target as APG pauses
chk "no SESSION_SUSPENDED at target" bash -c "! grep -q SESSION_SUSPENDED '$DLOG'"
chk "APG_SINCE still 0 at target" test "$(state_val APG_SINCE)" = "0"
chk "completion count 1 at target" test "$(state_val COMP_COUNT)" = "1"
chk "still active at target" test "$(state_val PHASE)" = "active"
set_pct 79; tick                       # APG still yellow (thermal), count 2 -> complete
chk_grep "SESSION_COMPLETE" "SESSION_COMPLETE logged under APG pause"
chk_grep "EPISODE id=.* result=completed" "EPISODE completed under APG pause"
chk_absent "$SESS" "session file gone after completion"
chk "no SESSION_SUSPENDED in whole case" bash -c "! grep -q SESSION_SUSPENDED '$DLOG'"
end_case

# ================= R4c completion during APG suspension beats the 15-min abort =================
begin_case "R4c-complete-while-suspended"
set_pct 88
write_session 85 "$NOW"
tick; tick                             # -> ACTIVE
echo "39.0" > "$TEST_ROOT/pack_temp"; tick     # THERMAL APG pause -> suspended above target
chk_grep "SESSION_SUSPENDED" "suspended while above target"
_AS=$(state_val APG_SINCE); forge_state APG_SINCE $(( _AS - 840 ))
set_pct 84; tick                       # drifts to target as 900s of suspension elapse
chk "no APG abort at target" bash -c "! grep -q 'result=aborted reason=apg' '$DLOG'"
chk "completion count 1 during suspension" test "$(state_val COMP_COUNT)" = "1"
set_pct 83; tick                       # count 2 -> complete, past the 900s mark
chk_grep "SESSION_COMPLETE" "SESSION_COMPLETE during suspension"
chk_grep "EPISODE id=.* result=completed" "EPISODE completed during suspension"
chk_absent "$SESS" "session file gone after suspended completion"
end_case

# ============ R4d corrective APG refusal (unchanged behaviour) ============
begin_case "R4d-corrective-apg"
echo "9" > "$TEST_ROOT/load"           # APG paused throughout
set_pct 88
write_session_mode corrective 85 "$NOW"
touch "$DASH/.apg_paused"
for i in 1 2 3 4 5 6; do tick; done    # budget counts while paused -> expires
chk_grep "result=refused reason=apg" "corrective refused reason=apg (byte-identical)"
chk_absent "$SESS" "corrective session removed on apg refusal"
end_case

# ============ R4e APG block + overshoot claim combined (user) ============
# Both silent-death traps at once: the session must survive the
# APG block (budget paused), then the no-second-signal budget
# expiry (extended arming), then activate when the reading settles.
# REWORKED by the temp gate (2026-11-15): the block phase is driven
# THERMALLY (pack_temp 39) — a load-only pause no longer blocks a
# user session at all (case N1 covers that path).
begin_case "R4e-apg-overshoot"
echo "39.0" > "$TEST_ROOT/pack_temp"
set_pct 93; set_ext Yes                # overshoot claim, no second signal
write_session 86 "$NOW"
touch "$DASH/.apg_paused"
for i in 1 2 3 4 5 6 7 8; do tick; done  # APG-blocked throughout (thermal)
chk_present "$SESS" "session survives APG block with a claim pending"
chk "ARMING_BLOCKED_APG logged once" bash -c "[ \$(grep -c ARMING_BLOCKED_APG '$DLOG') -eq 1 ]"
chk "no refusal during the block" bash -c "! grep -q 'result=refused' '$DLOG'"
echo "30.0" > "$TEST_ROOT/pack_temp"
for i in 1 2 3 4 5 6; do tick; done    # budget expires, claim unconfirmed
chk_grep "SESSION_ARMING_EXTENDED reason=no-second-signal" "extended arming after the block"
chk_present "$SESS" "session kept in extended arming"
chk "still no refusal" bash -c "! grep -q 'result=refused' '$DLOG'"
set_pct 88                             # settles inside the +2 band
tick; tick                             # gauge deferral absorbs one tick
chk_grep "OVERSHOOT_CLAIM_CLEARED" "claim dissolved after the block"
chk "active after settle" test "$(state_val PHASE)" = "active"
end_case

# ============ R4f APG forever -> max-age ABORT, never refusal ============
# REWORKED by the temp gate (2026-11-15): the forever-pause is
# THERMAL (pack_temp 39) — a forever LOAD-only pause no longer
# blocks a user session (it bypasses; case N1), so only a thermal
# block can still reach the max-age bound.
begin_case "R4f-apg-forever-maxage"
echo "39.0" > "$TEST_ROOT/pack_temp"   # thermal APG never clears
set_pct 88
write_session 85 $((NOW - 14340))      # 239 min old: inside the stale bound
touch "$DASH/.apg_paused"
tick                                   # arms, APG-blocked (age 14400, not over)
chk_grep "ARMING_BLOCKED_APG" "blocked on the first tick"
chk_present "$SESS" "session alive at the max-age boundary"
tick                                   # age 14460 > 14400 -> max-age abort
chk_grep "SESSION_ABORT reason=max-age" "max-age abort under a permanent APG block"
chk_grep "result=aborted reason=max-age" "EPISODE aborted max-age (not refused)"
chk "no refusal" bash -c "! grep -q 'result=refused' '$DLOG'"
chk_absent "$SESS" "session removed on max-age abort"
end_case

# ============ I1 intent resume: success ============
begin_case "I1-intent-resume"
set_pct 88; set_ext No
_I1_ORIG=$((NOW - 3600))               # captured pre-tick: tick() advances NOW
write_intent 85 $_I1_ORIG $((_I1_ORIG + 43200))
tick                                   # gates pass -> recreate + arm same tick
chk_grep "SESSION_RESUMED target=85" "SESSION_RESUMED logged"
chk_present "$SESS" "session recreated"
chk "starter is resume" bash -c "grep -q '^STARTER=resume' '$SESS'"
chk "original started preserved" bash -c "grep -q '^ORIGINAL_STARTED=$_I1_ORIG' '$SESS'"
chk_absent "$INTENT" "intent consumed"
chk_grep "SESSION_ARMED" "resumed session armed under the full rules"
end_case

# ============ I2 intent resume blocked by APG, then succeeds ============
# REWORKED by the temp gate (2026-11-15): the blocking pause is
# THERMAL (pack_temp 39) — a load-only pause no longer blocks an
# intent resume at all (case I9 covers that path).
begin_case "I2-intent-blocked-apg"
echo "39.0" > "$TEST_ROOT/pack_temp"   # thermal APG pause
set_pct 88; set_ext No
write_intent 85 $((NOW - 3600)) $((NOW - 3600 + 43200))
touch "$DASH/.apg_paused"           # paused from tick 1 (temp 39 sustains it)
tick; tick; tick
chk_absent "$SESS" "no session while APG blocks the resume"
chk_present "$INTENT" "intent kept while blocked"
chk "INTENT_RESUME_BLOCKED reason=apg once" bash -c "[ \$(grep -c 'INTENT_RESUME_BLOCKED reason=apg' '$DLOG') -eq 1 ]"
echo "30.0" > "$TEST_ROOT/pack_temp"; tick     # temp falls: APG clears
chk_grep "SESSION_RESUMED" "resumed once APG cleared"
chk_present "$SESS" "session recreated after the block"
end_case

# ============ I3 intent resume blocked post-wake, then succeeds ============
begin_case "I3-intent-blocked-post-wake"
set_pct 88; set_ext No
write_intent 85 $((NOW - 3600)) $((NOW - 3600 + 43200))
echo "$NOW" > "$DASH/.last_wake"       # woke just now
tick                                   # wake age 60 < 120 -> blocked
chk_grep "INTENT_RESUME_BLOCKED reason=post-wake" "blocked inside the post-wake window"
chk_absent "$SESS" "no session inside the post-wake window"
tick                                   # wake age 120 -> gate passes
chk_grep "SESSION_RESUMED" "resumed at the post-wake boundary"
chk_present "$SESS" "session recreated after the window"
end_case

# ============ I4 intent dropped: expired ============
begin_case "I4-intent-expired"
set_pct 88; set_ext No
write_intent 85 $((NOW - 50000)) $((NOW - 6800))
tick
chk_grep "INTENT_DROPPED reason=expired" "expired intent dropped"
chk_absent "$INTENT" "intent removed"
chk_absent "$SESS" "no session from an expired intent"
end_case

# ============ I5 intent dropped: goal already met ============
begin_case "I5-intent-goal-met"
set_pct 84; set_ext No                 # already below the target
write_intent 85 $((NOW - 3600)) $((NOW - 3600 + 43200))
tick
chk_grep "INTENT_DROPPED reason=goal-met" "goal-met intent dropped"
chk_absent "$INTENT" "intent removed"
chk_absent "$SESS" "no session when the goal is already met"
end_case

# ============ I6 intent dropped: calibration run live ============
begin_case "I6-intent-calibration"
set_pct 88; set_ext No
printf 'RUN_ID=testrun1\nLEG=L2\nHEARTBEAT=%s\nABS_FLOOR=10\n' "$NOW" > "$DASH/.calibration_run"
write_intent 85 $((NOW - 3600)) $((NOW - 3600 + 43200))
tick                                   # monitor runs before the supervisor
chk_grep "INTENT_DROPPED reason=calibration" "intent dropped while a run is live"
chk_absent "$INTENT" "intent removed"
chk "no SESSION_RESUMED" bash -c "! grep -q SESSION_RESUMED '$DLOG'"
end_case

# ============ I7 pre_sleep_cleanup writes intent (user only) ============
begin_case "I7-intent-written"
set_pct 88; set_ext No
write_session 85 "$NOW"
BC_DASH="$DASH" bash "$HELPERS_DIR/pre_sleep_cleanup.sh" >/dev/null 2>&1
chk_absent "$SESS" "session torn down by pre_sleep_cleanup"
chk_present "$INTENT" "intent written for a user session"
chk "intent target" bash -c "grep -q '^TARGET=85' '$INTENT'"
chk "intent original started" bash -c "grep -q '^ORIGINAL_STARTED=$NOW' '$INTENT'"
chk "intent expires +12h" bash -c "grep -q '^EXPIRES=$((NOW + 43200))' '$INTENT'"
chk_grep "INTENT_SAVED" "INTENT_SAVED logged"
# corrective session: NO intent
rm -f "$INTENT"
write_session_mode corrective 85 "$NOW"
BC_DASH="$DASH" bash "$HELPERS_DIR/pre_sleep_cleanup.sh" >/dev/null 2>&1
chk_absent "$SESS" "corrective session torn down"
chk_absent "$INTENT" "no intent for a corrective session"
# calibrate session: NO intent
write_session_mode calibrate 30 "$NOW"
BC_DASH="$DASH" bash "$HELPERS_DIR/pre_sleep_cleanup.sh" >/dev/null 2>&1
chk_absent "$INTENT" "no intent for a calibrate session"
end_case

# ============ I8 full chain: sleep -> resume -> complete -> no resurrection ============
begin_case "I8-intent-chain"
set_pct 88; set_ext No
write_session 85 "$NOW"
tick; tick                             # -> ACTIVE
chk "active before sleep" test "$(state_val PHASE)" = "active"
BC_DASH="$DASH" bash "$HELPERS_DIR/pre_sleep_cleanup.sh" >/dev/null 2>&1
chk_present "$INTENT" "intent saved at sleep"
tick                                   # monitor closes the vanished episode
tick                                   # resume gates pass -> recreate
chk_grep "SESSION_RESUMED" "session resumed after the wake"
chk_present "$SESS" "session recreated"
tick                                   # confirm 2 -> ACTIVE again
chk "active after resume" test "$(state_val PHASE)" = "active"
set_pct 85; tick                       # completion count 1
set_pct 85; tick                       # completion count 2 -> completed
chk_grep "result=completed" "resumed session completed"
chk_absent "$SESS" "session gone after completion"
tick; tick
chk "no resurrection after completion" bash -c "[ \$(grep -c SESSION_RESUMED '$DLOG') -eq 1 ]"
chk_absent "$SESS" "no new session after completion"
chk_absent "$INTENT" "no intent left after completion"
end_case

# ============ N1 load-only APG pause bypassed in the armed phase (full-fix 2026-11-15) ============
# Tonight's live replay: APG red from CPU load alone (Min ~87%),
# battery temp 30 C, user session armed on AC behind a gauge-drift
# overshoot claim. The pause must NOT block arming: counting
# proceeds under the bypass, the budget expires into extended
# arming, and the session is never refused.
begin_case "N1-load-bypass-armed"
echo "9" > "$TEST_ROOT/load"           # APG red via LOAD, temp stays 30C
set_pct 99; set_ext Yes                # overshoot claim on AC
write_session 85 "$NOW"
touch "$DASH/.apg_paused"           # paused from tick 1 (load 9 sustains it)
tick
chk_grep "ARMING_APG_LOAD_BYPASSED" "load-only pause bypassed for a user session"
chk "no ARMING_BLOCKED_APG" bash -c "! grep -q ARMING_BLOCKED_APG '$DLOG'"
chk "APG_BLOCK marks the bypass (2)" test "$(state_val APG_BLOCK)" = "2"
chk "budget counts under the bypass" test "$(state_val ARMED_TICKS)" = "1"
chk "confirmation counts under the bypass" test "$(state_val CONFIRM_COUNT)" = "1"
for i in 1 2 3 4 5; do tick; done      # budget expires, claim unconfirmed
chk_grep "SESSION_ARMING_EXTENDED reason=no-second-signal" "extended arming after the bypassed budget"
chk "bypass logged once per episode" bash -c "[ \$(grep -c ARMING_APG_LOAD_BYPASSED '$DLOG') -eq 1 ]"
chk_present "$SESS" "session alive in extended arming (never refused)"
chk "no refusal" bash -c "! grep -q 'result=refused' '$DLOG'"
end_case

# ============ N2 unplug activation + drain + complete (full-fix 2026-11-15) ============
# The 2026-11-15 evening failure, replayed: an overshoot-claim user
# session armed on AC under a load-only APG pause. Before the fix
# it could NEVER activate on battery (the only confirmation signal
# detected CHARGING evidence, which cannot exist while draining).
# Now drain evidence activates it on the first sampled battery tick.
begin_case "N2-unplug-activation"
echo "9" > "$TEST_ROOT/load"           # load-only APG pause the whole case
set_pct 99; set_ext Yes
write_session 85 "$NOW"
touch "$DASH/.apg_paused"
tick; tick                             # armed on AC under the bypass, claim pending
chk "still armed on AC" test "$(state_val PHASE)" = "armed"
set_ext No                             # the user unplugs
echo "18446744073709550616" > "$TEST_ROOT/amp"   # wrapped negative = discharge current
set_pct 98                             # capacity already falling
tick                                   # FIRST sampled battery tick
chk_grep "SESSION_ON_BATTERY" "battery observation latched"
chk_grep "SESSION_DRAIN_SIGNAL" "drain evidence logged"
chk "active on the first battery tick" test "$(state_val PHASE)" = "active"
chk "SEEN_BATT latched" test "$(state_val SEEN_BATT)" = "1"
set_pct 94; tick
set_pct 90; tick
set_pct 86; tick
set_pct 85; tick                       # completion count 1
set_pct 85; tick                       # completion count 2 -> completed
chk_grep "EPISODE id=.* result=completed" "EPISODE completed after the unplug drain"
chk_absent "$SESS" "session file gone after completion"
end_case

# ============ N3 short unplug is latched, never invisible (full-fix 2026-11-15) ============
begin_case "N3-short-unplug-latch"
set_pct 93; set_ext Yes                # claim pending, APG green
write_session 86 "$NOW"
tick                                   # armed on AC
set_ext No; tick                       # ONE sampled battery tick, no drain (amp 0, pct flat)
chk_grep "SESSION_ON_BATTERY source=watchdog" "battery tick latched"
chk "SEEN_BATT=1" test "$(state_val SEEN_BATT)" = "1"
chk "still armed (no drain evidence)" test "$(state_val PHASE)" = "armed"
set_ext Yes; tick                      # replug
chk_grep "SESSION_BACK_ON_AC" "return to AC logged"
chk "latch survives the replug" test "$(state_val SEEN_BATT)" = "1"
chk_present "$SESS" "session still armed after the short unplug"
end_case

# ============ N4 daemon-log cross-latch (full-fix 2026-11-15) ============
# An unplug only the daemon's phase-offset sampler saw still
# latches SEEN_BATT from its state lines.
begin_case "N4-daemon-log-latch"
set_pct 93; set_ext Yes
write_session 86 "$NOW"
printf '[2026-01-01 12:00:00] state: pct=93%% BCLM=10 charging=0 external=0\n' > "$DASH/bc-limit-daemon.log"
tick
chk_grep "SESSION_ON_BATTERY source=daemon-log" "daemon-log cross-latch fired"
chk "SEEN_BATT=1 via the daemon log" test "$(state_val SEEN_BATT)" = "1"
chk "still armed (the watchdog itself is on AC)" test "$(state_val PHASE)" = "armed"
end_case

# ============ N5 active phase ignores a load-only pause (full-fix 2026-11-15) ============
begin_case "N5-active-load-bypass"
set_pct 88; set_ext No
write_session 85 "$NOW"
tick; tick                             # -> ACTIVE on battery
chk "active before the load pause" test "$(state_val PHASE)" = "active"
echo "9" > "$TEST_ROOT/load"; touch "$DASH/.apg_paused"   # load-only pause, temp 30C
tick; tick
chk "no SESSION_SUSPENDED under a load-only pause" bash -c "! grep -q SESSION_SUSPENDED '$DLOG'"
chk "still active" test "$(state_val PHASE)" = "active"
set_pct 85; tick                       # completion count 1
set_pct 85; tick                       # completion count 2 -> completed
chk_grep "EPISODE id=.* result=completed" "drained to target under the load pause"
chk_absent "$SESS" "session file gone after completion"
end_case

# ============ N6 temp 38 C is the thermal boundary (full-fix 2026-11-15) ============
begin_case "N6-temp38-boundary"
echo "38.0" > "$TEST_ROOT/pack_temp"   # exactly the yellow threshold = thermal
set_pct 93; set_ext Yes
write_session 86 "$NOW"
touch "$DASH/.apg_paused"
tick; tick; tick
chk_grep "ARMING_BLOCKED_APG" "temp 38 blocks (thermal boundary)"
chk "no bypass at temp 38" bash -c "! grep -q ARMING_APG_LOAD_BYPASSED '$DLOG'"
chk "budget frozen at the boundary" test "$(state_val ARMED_TICKS)" = "0"
chk_present "$SESS" "session alive at the boundary"
end_case

# ============ I9 intent resume under a load-only pause (full-fix 2026-11-15) ============
begin_case "I9-intent-load-bypass"
echo "9" > "$TEST_ROOT/load"           # load-only APG pause, temp 30C
set_pct 88; set_ext No
write_intent 85 $((NOW - 3600)) $((NOW - 3600 + 43200))
touch "$DASH/.apg_paused"
tick
chk_grep "SESSION_RESUMED" "intent resumed despite the load-only pause"
chk "no INTENT_RESUME_BLOCKED" bash -c "! grep -q INTENT_RESUME_BLOCKED '$DLOG'"
chk_present "$SESS" "session recreated under the load pause"
end_case

# ================= R12 log completeness =================
begin_case "R12-log"
[ -f "$DASH/discharge.log" ] && cat "$DASH/discharge.log" >> "$CUM_LOG"
for _t in SESSION_ARMED SESSION_ACTIVE SESSION_PARKED SESSION_SUSPENDED \
          SESSION_RESUMED GAUGE_DEFER SESSION_INVALID SHADOW_EVAL EPISODE; do
    chk "cumulative log has $_t" grep -q "$_t" "$CUM_LOG"
done
_EP=$(grep -c "EPISODE " "$CUM_LOG")
chk "at least 10 EPISODE lines (got $_EP)" bash -c "[ $_EP -ge 10 ]"
for _r in completed refused aborted incomplete ended cancelled; do
    chk "cumulative log has result=$_r" grep -q "result=$_r" "$CUM_LOG"
done
end_case

echo "----------------------------------------"
echo "test_discharge: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
[ "$FAIL" -eq 0 ] && { echo "PASS"; exit 0; } || exit 1

