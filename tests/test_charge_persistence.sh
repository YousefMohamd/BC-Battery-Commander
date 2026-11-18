#!/bin/bash
# test_charge_persistence.sh — sandbox suite for the charge build
# (2026-11-14): last-state-wins persistence for the charge/limit actions.
#
# Follows the test_discharge.sh / test_bc_watchdog.sh pattern: a sandbox
# state dir (BC_DASH), a stub build dir (BC_BUILD_DIR), stubbed external
# commands first on PATH, control files for the battery. The script under
# test is copied from src/daemon-helpers/ (or $DISPATCH_SRC) into the
# sandbox; the LIVE state dir is never touched (asserted by md5 at the
# end). No SMC writes, no sudo, no dialogs (osascript is stubbed).
#
# Cases:
#   C0 source invariant: in intent_apply charge_full, .active_mode is
#      written BEFORE .charge_target (watchdog stale-clear race guard).
#   C1 charge_full  -> config 100/99 exactly, mode=charge_full, flag=100.
#   C2 disable_limit-> config 100/99 exactly, mode=idle, flag absent.
#   C3 stop_now     -> config = pct/(pct-1) (hold at current), mode=hold,
#                      .hold_since present, flag absent.
#   C4 remove_limit_hold after C1 -> config stays 100/99 (returns to the
#                      CONFIGURED limit — the last state set), mode=idle.
#   C5 limit_custom (stubbed dialogs 90/89 + Hold) -> config 90/89,
#                      SAILING=false, mode=idle.
#   C6 static evidence: the enforcer source (bc-limit-v1.2.c) contains
#                      zero references to .charge_target / .active_mode,
#                      i.e. the flag can never reach enforcement.
set -u
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
HELPERS_DIR="$REPO_ROOT/src/daemon-helpers"
DISPATCH_SRC="${DISPATCH_SRC:-$HELPERS_DIR/dispatch.sh}"
[ -f "$DISPATCH_SRC" ] || { echo "FAIL: dispatch.sh not found ($DISPATCH_SRC)"; exit 1; }
[ -f "$HELPERS_DIR/state_guard.sh" ] || { echo "FAIL: state_guard.sh not found"; exit 1; }

TEST_ROOT=$(mktemp -d /tmp/bc-charge-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
DASH="$TEST_ROOT/.battery-commander"
BIN="$TEST_ROOT/bin"
BUILD="$TEST_ROOT/build"
mkdir -p "$DASH" "$BIN" "$BUILD"
export TEST_ROOT

LIVE_CFG_MD5_BEFORE=$(md5 -q "$HOME/.battery-commander/config" 2>/dev/null || echo "none")

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check(){ # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi
}

# --- sandbox copies of the code under test ---
cp "$DISPATCH_SRC" "$DASH/dispatch.sh"
cp "$HELPERS_DIR/state_guard.sh" "$DASH/state_guard.sh"
chmod +x "$DASH/dispatch.sh"

# --- control files ---
echo "720" > "$TEST_ROOT/cap"     # 720/1000 -> 72%
echo "10"  > "$TEST_ROOT/bclm"
echo "0"   > "$TEST_ROOT/osa_count"

# --- stubs (PATH) ---
cat > "$BIN/ioreg" <<'EOF'
#!/bin/bash
cat <<X
"CurrentCapacity" = $(cat "$TEST_ROOT/cap" 2>/dev/null || echo 720)
"MaxCapacity" = 1000
"IsCharging" = No
"ExternalConnected" = $(cat "$TEST_ROOT/ext" 2>/dev/null || echo Yes)
"Amperage" = 0
"NotChargingReason"=0
X
EOF
chmod +x "$BIN/ioreg"
echo "Yes" > "$TEST_ROOT/ext"

# Notifier recorder (WS1-A/B): dispatch notify() honours BC_NOTIFIER;
# every user-facing notification is appended to $TEST_ROOT/notifications.log.
cat > "$BIN/bc-notifier" <<'EOF'
#!/bin/bash
echo "NOTIFY: $*" >> "$TEST_ROOT/notifications.log"
exit 0
EOF
chmod +x "$BIN/bc-notifier"
: > "$TEST_ROOT/notifications.log"

cat > "$BIN/osascript" <<'EOF'
#!/bin/bash
# notify-style calls use -e and must not consume dialog answers.
case "$*" in
  *-e*) exit 0 ;;
esac
N=$(cat "$TEST_ROOT/osa_count" 2>/dev/null || echo 0)
N=$((N+1)); echo "$N" > "$TEST_ROOT/osa_count"
case "$N" in
  1) if [ -f "$TEST_ROOT/osa_answer" ]; then cat "$TEST_ROOT/osa_answer"; else echo "90/89"; fi ;;  # limit_custom: limit dialog (override via osa_answer)
  2) echo "Hold" ;;    # limit_custom: mode dialog
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$BIN/osascript"

for c in launchctl pmset pkill; do
    printf '#!/bin/bash\nexit 0\n' > "$BIN/$c"; chmod +x "$BIN/$c"
done

# --- stubs (BC_BUILD_DIR: bc-status / bc-candidates / bc-limit) ---
cat > "$BUILD/bc-candidates" <<'EOF'
#!/bin/bash
echo "BCLM: size=1 type=ui8 bytes=0a value=10"
EOF
chmod +x "$BUILD/bc-candidates"
cat > "$BUILD/bc-status" <<'EOF'
#!/bin/bash
echo "Capacity: 72.0%"
echo "TempBatteryPack: 30.0°C"
echo "Health: 75.5%"
echo "Cycle: 568"
echo "BCLM: 10"
echo "Backend: bclm"
echo "READ-ONLY DONE"
EOF
chmod +x "$BUILD/bc-status"
cat > "$BUILD/bc-limit" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--probe" ]; then echo "backend=bclm"; fi
exit 0
EOF
chmod +x "$BUILD/bc-limit"

reset_state() {
    printf 'LAST_UPPER=86\nLAST_LOWER=85\nSAILING=false\nSAIL_GAP=1\n' > "$DASH/config"
    printf 'idle\n' > "$DASH/.active_mode"
    rm -f "$DASH/.charge_target" "$DASH/.hold_since" "$DASH/.discharge_session" \
          "$DASH/.discharge_intent" "$DASH/.discharge_intent_block" \
          "$DASH/.apg_paused" "$DASH/.last_inputs" "$DASH/.op.lock" \
          "$DASH/.discharge_cooldown" "$TEST_ROOT/osa_answer" 2>/dev/null
    rm -rf "$DASH/.guard.lock" 2>/dev/null
    echo "0" > "$TEST_ROOT/osa_count"
    echo "Yes" > "$TEST_ROOT/ext"
    : > "$TEST_ROOT/notifications.log"
    : > "$DASH/discharge.log"
}

run_action() {
    BC_DASH="$DASH" BC_BUILD_DIR="$BUILD" BC_NOTIFIER="$BIN/bc-notifier" \
        PATH="$BIN:$PATH" \
        bash "$DASH/dispatch.sh" "$1" >/dev/null 2>&1
}

sess_target() { grep '^TARGET=' "$DASH/.discharge_session" 2>/dev/null | cut -d= -f2; }
wait_notif() { # poll up to ~2 s for a notification substring (notify is async)
    local i=0
    while [ $i -lt 20 ]; do
        grep -q "$1" "$TEST_ROOT/notifications.log" 2>/dev/null && return 0
        sleep 0.1; i=$((i+1))
    done
    return 1
}

cfg() { cat "$DASH/config" 2>/dev/null; }
mode() { tr -d '[:space:]' < "$DASH/.active_mode" 2>/dev/null; }
CANON='LAST_UPPER=86
LAST_LOWER=85
SAILING=false
SAIL_GAP=1'
FULL='LAST_UPPER=100
LAST_LOWER=99
SAILING=false
SAIL_GAP=1'

# === C0: source order invariant (mode before flag in charge_full) ===
M_LINE=$(grep -n 'echo "charge_full" > "$D/.active_mode"' "$DASH/dispatch.sh" | head -1 | cut -d: -f1)
F_LINE=$(grep -n 'echo "100" > "$D/.charge_target"' "$DASH/dispatch.sh" | head -1 | cut -d: -f1)
if [ -n "$M_LINE" ] && [ -n "$F_LINE" ] && [ "$M_LINE" -lt "$F_LINE" ]; then
    ok "C0 charge_full writes .active_mode (line $M_LINE) before .charge_target (line $F_LINE)"
else
    bad "C0 source order (mode line=$M_LINE flag line=$F_LINE)"
fi

# === C1: charge_full ===
reset_state
run_action charge_full
check "C1 config is exactly 100/99" "$FULL" "$(cfg)"
check "C1 mode is charge_full" "charge_full" "$(mode)"
check "C1 .charge_target content" "100" "$(tr -d '[:space:]' < "$DASH/.charge_target" 2>/dev/null)"
[ -f "$DASH/.discharge_session" ] && bad "C1 no discharge session created" || ok "C1 no discharge session created"
check "C1 config line count" "4" "$(grep -c . "$DASH/config")"

# === C2: disable_limit ===
reset_state
run_action disable_limit
check "C2 config is exactly 100/99" "$FULL" "$(cfg)"
check "C2 mode is idle" "idle" "$(mode)"
[ -f "$DASH/.charge_target" ] && bad "C2 .charge_target absent" || ok "C2 .charge_target absent"

# === C3: stop_now at 72% ===
reset_state
run_action stop_now
HOLD='LAST_UPPER=72
LAST_LOWER=71
SAILING=false
SAIL_GAP=1'
check "C3 config is exactly 72/71 (hold at current pct)" "$HOLD" "$(cfg)"
check "C3 mode is hold" "hold" "$(mode)"
[ -f "$DASH/.hold_since" ] && ok "C3 .hold_since written" || bad "C3 .hold_since written"
[ -f "$DASH/.charge_target" ] && bad "C3 .charge_target absent" || ok "C3 .charge_target absent"

# === C4: remove_limit_hold after charge_full ===
reset_state
run_action charge_full
run_action remove_limit_hold
check "C4 config stays 100/99 (returns to configured limit)" "$FULL" "$(cfg)"
check "C4 mode is idle" "idle" "$(mode)"

# === C5: limit_custom 90/89 + Hold (stubbed dialogs) ===
reset_state
run_action limit_custom
CUSTOM='LAST_UPPER=90
LAST_LOWER=89
SAILING=false
SAIL_GAP=1'
check "C5 config is exactly 90/89" "$CUSTOM" "$(cfg)"
check "C5 mode is idle" "idle" "$(mode)"

# === C6: enforcer never reads the flag (static evidence) ===
ENF_SRC="$TEST_DIR/bc-limit-v1.2.c"
if [ -f "$ENF_SRC" ]; then
    check "C6 bc-limit source: charge_target references" "0" "$(grep -c 'charge_target' "$ENF_SRC" || true)"
    check "C6 bc-limit source: active_mode references" "0" "$(grep -c 'active_mode' "$ENF_SRC" || true)"
else
    echo "SKIP: C6 enforcer source not found at $ENF_SRC"
fi

# === C7–C13: limit pull-down (WS1-A, hardening 2026-11-14) ===
# A limit intent landing with pct > new upper must ALSO start a real
# user discharge session with TARGET=upper — the user must see the
# battery actually move (Yousef's order after the 21:34 "nothing
# happened" report).

# C7: above target on AC -> session TARGET=upper + parked notification
reset_state
echo 900 > "$TEST_ROOT/cap"          # 90%
echo "80/79" > "$TEST_ROOT/osa_answer"
run_action limit_custom
L80='LAST_UPPER=80
LAST_LOWER=79
SAILING=false
SAIL_GAP=1'
check "C7 config is the applied limit" "$L80" "$(cfg)"
check "C7 session TARGET = new upper" "80" "$(sess_target)"
grep -q '^MODE=user' "$DASH/.discharge_session" && ok "C7 session MODE=user" || bad "C7 session MODE"
grep -q '^STARTER=dispatch' "$DASH/.discharge_session" && ok "C7 session STARTER=dispatch" || bad "C7 session STARTER"
wait_notif 'discharging to 80%' && ok "C7 notification states the discharge" || bad "C7 notification missing discharge text"
grep -q 'parked on AC' "$TEST_ROOT/notifications.log" && ok "C7 notification states parked-on-AC" || bad "C7 notification lacks parked wording"
grep -q 'origin=limit-intent' "$DASH/discharge.log" && ok "C7 discharge.log records the origin" || bad "C7 discharge.log origin"

# C8: below target -> no session
reset_state
echo 720 > "$TEST_ROOT/cap"          # 72%, default answer 90/89
run_action limit_custom
[ -f "$DASH/.discharge_session" ] && bad "C8 no session below target" || ok "C8 no session below target"

# C9: at target (pct == upper) -> no session
reset_state
echo 900 > "$TEST_ROOT/cap"
echo "90/89" > "$TEST_ROOT/osa_answer"
run_action limit_custom
[ -f "$DASH/.discharge_session" ] && bad "C9 no session at target" || ok "C9 no session at target"

# C10: active session with another target -> superseded by the intent
reset_state
echo 900 > "$TEST_ROOT/cap"
printf 'MODE=user\nTARGET=85\nSTARTED=%s\nSTARTER=dispatch\n' "$(date +%s)" > "$DASH/.discharge_session"
echo "80/79" > "$TEST_ROOT/osa_answer"
run_action limit_custom
check "C10 session replaced with TARGET=80" "80" "$(sess_target)"
grep -q 'SESSION_SUPERSEDED by=dispatch.limit-intent' "$DASH/discharge.log" && ok "C10 supersede logged" || bad "C10 supersede not logged"

# C11: flip cooldown live -> config written, session deferred, honest message
reset_state
echo 900 > "$TEST_ROOT/cap"
printf 'UNTIL=%s\nREASON=ac-flip\n' "$(( $(date +%s) + 3600 ))" > "$DASH/.discharge_cooldown"
echo "80/79" > "$TEST_ROOT/osa_answer"
run_action limit_custom
check "C11 config still applied" "$L80" "$(cfg)"
[ -f "$DASH/.discharge_session" ] && bad "C11 no session during cooldown" || ok "C11 no session during cooldown"
wait_notif 'cooldown' && ok "C11 notification explains the cooldown" || bad "C11 notification lacks cooldown explanation"

# C12: upper below the session range (16) -> no session + honest message
reset_state
echo 900 > "$TEST_ROOT/cap"
echo "16/15" > "$TEST_ROOT/osa_answer"
run_action limit_custom
[ -f "$DASH/.discharge_session" ] && bad "C12 no session for upper 16" || ok "C12 no session for upper 16"
wait_notif 'below 20' && ok "C12 notification explains the range floor" || bad "C12 notification lacks range explanation"

# C13: above target on battery -> session + non-parked message
reset_state
echo 900 > "$TEST_ROOT/cap"
echo "No" > "$TEST_ROOT/ext"
echo "80/79" > "$TEST_ROOT/osa_answer"
run_action limit_custom
check "C13 session TARGET = new upper (battery)" "80" "$(sess_target)"
wait_notif 'discharging to 80%' && ok "C13 notification states the discharge" || bad "C13 notification missing"
grep -q 'parked on AC' "$TEST_ROOT/notifications.log" && bad "C13 battery message must not say parked" || ok "C13 battery message has no parked wording"

# === C14–C17: discharge intent clearing (2026-11-14) ===
# pre_sleep_cleanup stores a sleep-resume intent (.discharge_intent)
# for MODE=user sessions; every dispatch path that ends or
# supersedes a session must clear it, or the watchdog monitor would
# resurrect a session the user already moved past.
write_intent() { printf 'TARGET=85\nORIGINAL_STARTED=%s\nEXPIRES=%s\n' "$(( $(date +%s) - 600 ))" "$(( $(date +%s) + 42600 ))" > "$DASH/.discharge_intent"; }

# C14: teardown (kill_discharge -> sd_session_invalidate) clears it
reset_state
write_intent
printf 'MODE=user\nTARGET=85\nSTARTED=%s\nSTARTER=dispatch\n' "$(date +%s)" > "$DASH/.discharge_session"
run_action kill_discharge
[ -f "$DASH/.discharge_session" ] && bad "C14 session ended by teardown" || ok "C14 session ended by teardown"
[ -f "$DASH/.discharge_intent" ] && bad "C14 intent cleared by teardown" || ok "C14 intent cleared by teardown"
grep -q 'INTENT_CLEARED by=dispatch.teardown' "$DASH/discharge.log" && ok "C14 INTENT_CLEARED logged (teardown)" || bad "C14 INTENT_CLEARED not logged"

# C15: user cancel via the toggle clears it
reset_state
write_intent
printf 'MODE=user\nTARGET=85\nSTARTED=%s\nSTARTER=dispatch\n' "$(date +%s)" > "$DASH/.discharge_session"
echo "Cancel Session" > "$TEST_ROOT/osa_answer"
run_action smart_discharge
[ -f "$DASH/.discharge_session" ] && bad "C15 session cancelled" || ok "C15 session cancelled"
[ -f "$DASH/.discharge_intent" ] && bad "C15 intent cleared by cancel" || ok "C15 intent cleared by cancel"
grep -q 'INTENT_CLEARED by=dispatch.cancel' "$DASH/discharge.log" && ok "C15 INTENT_CLEARED logged (cancel)" || bad "C15 INTENT_CLEARED not logged"

# C16: a manual start supersedes it
reset_state
write_intent
echo 900 > "$TEST_ROOT/cap"          # 90%
echo "80" > "$TEST_ROOT/osa_answer"
run_action smart_discharge
check "C16 manual session TARGET" "80" "$(sess_target)"
[ -f "$DASH/.discharge_intent" ] && bad "C16 intent cleared by manual start" || ok "C16 intent cleared by manual start"
grep -q 'INTENT_CLEARED by=dispatch.manual-start' "$DASH/discharge.log" && ok "C16 INTENT_CLEARED logged (manual-start)" || bad "C16 INTENT_CLEARED not logged"

# C17: a limit-intent pull-down supersedes it
reset_state
write_intent
echo 900 > "$TEST_ROOT/cap"
echo "80/79" > "$TEST_ROOT/osa_answer"
run_action limit_custom
check "C17 pull-down session TARGET" "80" "$(sess_target)"
[ -f "$DASH/.discharge_intent" ] && bad "C17 intent cleared by limit intent" || ok "C17 intent cleared by limit intent"
grep -q 'INTENT_CLEARED by=dispatch.limit-intent' "$DASH/discharge.log" && ok "C17 INTENT_CLEARED logged (limit-intent)" || bad "C17 INTENT_CLEARED not logged"

# === Live config untouched ===
LIVE_CFG_MD5_AFTER=$(md5 -q "$HOME/.battery-commander/config" 2>/dev/null || echo "none")
check "LIVE config md5 unchanged by the suite" "$LIVE_CFG_MD5_BEFORE" "$LIVE_CFG_MD5_AFTER"

echo "---"
echo "test_charge_persistence: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

