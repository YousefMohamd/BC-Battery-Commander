#!/bin/bash
# test_bc_watchdog.sh — sandboxed regression test for bc-watchdog.sh (W3).
# Ported from test_enforce_watchdog.sh (W0-extension: config 80/75 -> 86/85,
# stub bc-limit/bc-status/bc-candidates instead of battopt, throttle sed
# dropped — the dead .throttle_helper.sh source line is deleted, not ported).
#
# Verifies: CRITICAL notifier cap (3), guardian corrective-discharge
# gate (v1.6-ac: starts a corrective session at COUNT 8), monotonic
# COUNT, suppression log, healthy-tick
# cleanup of the 4 ladder files, drift detection, APG suppression,
# charge_target cleanup, daemon-not-loaded log, consolidated fan-out.
# No system mutations: every external command (date, ioreg, bc-candidates,
# bc-status, bc-limit, launchctl, sysctl, pmset, stat, sleep, pkill,
# terminal-notifier, osascript) is routed through stubs placed first on
# PATH; DASH points at a temp directory.
# Clock starts at BASE_EPOCH, not 0. In production $NOW is real epoch time,
# so the ">=300s since last discharge/critical" gate fires on the first
# eligible tick. Starting at BASE_EPOCH reproduces that behavior in the
# sandbox without a wall-clock wait.
set -u
TEST_ROOT=$(mktemp -d /tmp/bc-watchdog-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
DASH="$TEST_ROOT/.battery-commander"
mkdir -p "$DASH"
printf 'LAST_UPPER=86\nLAST_LOWER=85\nSAILING=false\nSAIL_GAP=1\n' > "$DASH/config"
BIN="$TEST_ROOT/bin"
mkdir -p "$BIN"
export TEST_ROOT
echo "30.0" > "$TEST_ROOT/pack_temp"
echo "100" > "$TEST_ROOT/bclm"
echo "violation" > "$TEST_ROOT/ioreg_mode"

cat > "$BIN/date" <<'EOF'
#!/bin/bash
N="${TEST_ROOT}/now"
case "$1" in
  +%s)       cat "$N" 2>/dev/null || echo 0 ;;
  +%H:%M:%S) cat "$N" 2>/dev/null || echo 0 ;;
  *)         cat "$N" 2>/dev/null || echo "" ;;
esac
EOF
chmod +x "$BIN/date"

cat > "$BIN/ioreg" <<'EOF'
#!/bin/bash
case "$(cat "$TEST_ROOT/ioreg_mode" 2>/dev/null)" in
  healthy)
    cat <<'X'
"CurrentCapacity" = 75
"MaxCapacity" = 100
"IsCharging" = No
"ExternalConnected" = No
"NotChargingReason" = 0
X
    ;;
  full)
    cat <<'X'
"CurrentCapacity" = 100
"MaxCapacity" = 100
"IsCharging" = Yes
"ExternalConnected" = Yes
"NotChargingReason" = 14
X
    ;;
  *) # violation: 90% charging on AC
    cat <<'X'
"CurrentCapacity" = 90
"MaxCapacity" = 100
"IsCharging" = Yes
"ExternalConnected" = Yes
"NotChargingReason" = 0
X
    ;;
esac
EOF
chmod +x "$BIN/ioreg"

cat > "$BIN/bc-candidates" <<'EOF'
#!/bin/bash
echo "BCLM: size=1 type=ui8 bytes=64 value=$(cat "$TEST_ROOT/bclm" 2>/dev/null || echo 100)"
EOF
chmod +x "$BIN/bc-candidates"

cat > "$BIN/bc-status" <<'EOF'
#!/bin/bash
echo "Capacity: 90.0%"
echo "TempBatteryPack: $(cat "$TEST_ROOT/pack_temp" 2>/dev/null || echo 30.0)°C"
echo "TempCPU: 45.0°C"
echo "Health: 75.6%"
echo "Cycle: 568"
echo "BCLM: $(cat "$TEST_ROOT/bclm" 2>/dev/null || echo 100)"
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
[ -f "$TEST_ROOT/launchctl_down" ] && exit 1
exit 0
EOF
chmod +x "$BIN/launchctl"

cat > "$BIN/sysctl" <<'EOF'
#!/bin/bash
echo "1.0 1.0 1.0"
EOF
chmod +x "$BIN/sysctl"

cat > "$BIN/pmset" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN/pmset"

cat > "$BIN/stat" <<'EOF'
#!/bin/bash
# All files read as "just modified" (age 0): L1/L4/L4b staleness gates
# never fire in this test (their paths are covered by review, not here).
cat "$TEST_ROOT/now" 2>/dev/null || echo 0
EOF
chmod +x "$BIN/stat"

cat > "$BIN/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN/sleep"

cat > "$BIN/pgrep" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$BIN/pgrep"

cat > "$BIN/pkill" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN/pkill"

cat > "$BIN/osascript" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN/osascript"

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

# Consolidated children (stubbed no-ops in the temp DASH).
for _c in sailing_tracker.sh adaptive.sh ensure_limit.sh system_guard.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$DASH/$_c"
    chmod +x "$DASH/$_c"
done

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
# bc-watchdog.sh and state_guard.sh live in src/daemon-helpers/,
# not in bc-build/ (W6.4 fix — the test as written failed
# immediately with "FAIL: bc-watchdog.sh not found").
HELPERS_DIR="$SRC_DIR/../../src/daemon-helpers"
[ -d "$HELPERS_DIR" ] || HELPERS_DIR="$SRC_DIR"
cp "$HELPERS_DIR/state_guard.sh" "$DASH/state_guard.sh" \
    || { echo "FAIL: state_guard.sh not found in $HELPERS_DIR"; exit 1; }
SCRIPT_SRC="$HELPERS_DIR/bc-watchdog.sh"
[ -f "$SCRIPT_SRC" ] || { echo "FAIL: bc-watchdog.sh not found"; exit 1; }
SCRIPT_RUN="$TEST_ROOT/bc-watchdog.sh"
# The watchdog DASH is now a fallback block (W6.3), not a single
# line — point it at the temp DASH with BC_DASH instead of a sed.
export BC_DASH="$DASH"
sed \
    -e "s|^BC_BUILD_DIR=.*|BC_BUILD_DIR=\"$BIN\"|" \
    -e "s|/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier|$NOTIF_DIR/terminal-notifier|g" \
    "$SCRIPT_SRC" > "$SCRIPT_RUN"
chmod +x "$SCRIPT_RUN"
grep -q "BC_DASH" "$SCRIPT_RUN" || { echo "FAIL: BC_DASH fallback block missing"; exit 1; }
grep -q "BC_BUILD_DIR=\"$BIN\"" "$SCRIPT_RUN" || { echo "FAIL: BC_BUILD_DIR substitution"; exit 1; }
grep -q "$NOTIF_DIR/terminal-notifier" "$SCRIPT_RUN" || { echo "FAIL: notifier substitution"; exit 1; }

export PATH="$BIN:$PATH"
export HOME="$TEST_ROOT"
BASE_EPOCH=1730000000

# --- Static checks (no battopt/sudo/throttle/discharge-spawn in code) ---
FAIL=0
# Static checks count CODE lines only: comments documenting the
# migration legitimately mention `battopt <subcommand>` (W6.3
# decision — descriptive mentions are kept), so strip comment
# lines before counting (the old check failed on 4 such comments).
CODE_ONLY() { grep -v '^[[:space:]]*#' "$SCRIPT_SRC"; }
[ "$(CODE_ONLY | grep -c 'source.*throttle_helper')" -eq 0 ] || { echo "FAIL: throttle_helper source line present"; FAIL=1; }
[ "$(CODE_ONLY | grep -c 'ac_throttle')" -eq 0 ] || { echo "FAIL: ac_throttle call present"; FAIL=1; }
[ "$(CODE_ONLY | grep -cE 'battopt (status|limit|discharge|charge|daemon)')" -eq 0 ] || { echo "FAIL: battopt subcommand present"; FAIL=1; }
[ "$(CODE_ONLY | grep -c 'sudo -n')" -eq 0 ] || { echo "FAIL: sudo -n present"; FAIL=1; }
[ "$(CODE_ONLY | grep -c 'nohup.*sd_watcher')" -eq 0 ] || { echo "FAIL: sd_watcher spawn present"; FAIL=1; }
[ "$(CODE_ONLY | grep -c '"$BC_LIMIT" --write')" -eq 0 ] || { echo "FAIL: bc-limit --write call present"; FAIL=1; }

# --- Phase A: violation timeline (35 ticks x 60 s, PCT=90, BCLM=100) ---
# 35 ticks (not 30): the CRITICAL rung fires first at COUNT>=16 (tick 16)
# and then every 300 s cooldown (ticks 21, 26, 31). The cap-suppression
# log only appears on the 4th firing (tick 31); 30 ticks stop at the 3rd
# firing, so the suppression check could never pass (W6.4 fix).
for ((t=60; t<=2100; t+=60)); do
    echo "$((BASE_EPOCH + t))" > "$TEST_ROOT/now"
    bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
done
WLOG="$DASH/.watchdog.log"
LOG_FILE="$DASH/actions.log"
NOTIF_CRIT=$(grep -c "CRITICAL" "$NOTIF_HITS" 2>/dev/null | tr -d ' ')
GUARDIAN_HITS=$(grep -c "GUARDIAN: corrective discharge session started" "$WLOG" 2>/dev/null | tr -d ' ')
SESS_MODE=$(grep '^MODE=' "$DASH/.discharge_session" 2>/dev/null | cut -d= -f2)
SESS_TARGET=$(grep '^TARGET=' "$DASH/.discharge_session" 2>/dev/null | cut -d= -f2)
STATE_LINE=$(cat "$DASH/.enforce_state" 2>/dev/null || echo "0|0")
FINAL_COUNT=$(echo "$STATE_LINE" | cut -d'|' -f1)
CRIT_LOGS=$(grep -c "CRITICAL: enforcement failed" "$WLOG" 2>/dev/null | tr -d ' ')
SUPPRESS_LOGS=$(grep -c "CRITICAL: notification suppressed" "$WLOG" 2>/dev/null | tr -d ' ')
DRIFT_LOGS=$(grep -c "drift detected" "$WLOG" 2>/dev/null | tr -d ' ')
CONSOLIDATED_LOGS=$(grep -c "consolidated: ran:" "$WLOG" 2>/dev/null | tr -d ' ')
echo "phase A: guardian_hits=$GUARDIAN_HITS (expected 1 — the COUNT 8 gate starts a corrective session)"
echo "phase A: session mode/target = $SESS_MODE/$SESS_TARGET (expected corrective/86)"
echo "phase A: final_count=$FINAL_COUNT (expected 8 — the ladder pauses while the session owns the state)"
echo "phase A: drift_logs=$DRIFT_LOGS (expected >= 1)"
echo "phase A: consolidated_logs=$CONSOLIDATED_LOGS (expected >= 1)"
[ "$GUARDIAN_HITS" -eq 1 ] || { echo "FAIL: guardian session hits"; FAIL=1; }
[ "$SESS_MODE" = "corrective" ] || { echo "FAIL: session mode is not corrective"; FAIL=1; }
[ "$SESS_TARGET" = "86" ] || { echo "FAIL: session target is not 86"; FAIL=1; }
[ "$FINAL_COUNT" -eq 8 ] || { echo "FAIL: final count (ladder must pause at 8 behind the session)"; FAIL=1; }
[ "$DRIFT_LOGS" -ge 1 ] || { echo "FAIL: drift log"; FAIL=1; }
[ "$CONSOLIDATED_LOGS" -ge 1 ] || { echo "FAIL: consolidated log"; FAIL=1; }

# --- Phase A2: session over, violation persists, an AC-flip
# cooldown blocks a new guardian session -> the ladder resumes
# and the CRITICAL cap machinery runs as it did pre-actuator.
printf 'UNTIL=%s\n' "$((BASE_EPOCH + 999999))" > "$DASH/.discharge_cooldown"
rm -f "$DASH/.discharge_session" "$DASH/.discharge_state"
printf 'idle\n' > "$DASH/.active_mode"
for ((t=2160; t<=4260; t+=60)); do
    echo "$((BASE_EPOCH + t))" > "$TEST_ROOT/now"
    bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
done
NOTIF_CRIT=$(grep -c "CRITICAL" "$NOTIF_HITS" 2>/dev/null | tr -d ' ')
STATE_LINE=$(cat "$DASH/.enforce_state" 2>/dev/null || echo "0|0")
FINAL_COUNT=$(echo "$STATE_LINE" | cut -d'|' -f1)
CRIT_LOGS=$(grep -c "CRITICAL: enforcement failed" "$WLOG" 2>/dev/null | tr -d ' ')
SUPPRESS_LOGS=$(grep -c "CRITICAL: notification suppressed" "$WLOG" 2>/dev/null | tr -d ' ')
GUARDIAN_HITS2=$(grep -c "GUARDIAN: corrective discharge session started" "$WLOG" 2>/dev/null | tr -d ' ')
echo "phase A2: notifier_crit=$NOTIF_CRIT (expected 3)"
echo "phase A2: final_count=$FINAL_COUNT (expected > 16)"
echo "phase A2: crit_logs=$CRIT_LOGS (expected >= 3)"
echo "phase A2: suppress_logs=$SUPPRESS_LOGS (expected >= 1)"
echo "phase A2: guardian_hits=$GUARDIAN_HITS2 (expected still 1 — cooldown blocks a new session)"
[ "$NOTIF_CRIT" -eq 3 ] || { echo "FAIL: CRITICAL notifier hits"; FAIL=1; }
[ "$FINAL_COUNT" -gt 16 ] || { echo "FAIL: final count"; FAIL=1; }
[ "$CRIT_LOGS" -ge 3 ] || { echo "FAIL: crit logs"; FAIL=1; }
[ "$SUPPRESS_LOGS" -ge 1 ] || { echo "FAIL: suppression log"; FAIL=1; }
[ "$GUARDIAN_HITS2" -eq 1 ] || { echo "FAIL: guardian created a session during the flip cooldown"; FAIL=1; }

# --- Phase B: healthy tick (75%, not charging, battery) ---
echo "healthy" > "$TEST_ROOT/ioreg_mode"
rm -f "$DASH/.discharge_cooldown"
echo "$((BASE_EPOCH + 4320))" > "$TEST_ROOT/now"
bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
for f in .enforce_state .enforce_last_discharge .enforce_last_critical .enforce_crit_count; do
    [ -f "$DASH/$f" ] && { echo "FAIL: $f survived healthy tick"; FAIL=1; }
done
[ -f "$DASH/.drift_state" ] && { echo "FAIL: .drift_state survived healthy tick"; FAIL=1; }
echo "phase B: healthy-tick cleanup OK"

# --- Phase C: APG suppression (temp 45C -> red, violation again) ---
echo "45.0" > "$TEST_ROOT/pack_temp"
echo "violation" > "$TEST_ROOT/ioreg_mode"
rm -f "$DASH/.enforce_last_discharge"
GUARDIAN_BEFORE=$(grep -c "GUARDIAN: corrective discharge session started" "$WLOG" 2>/dev/null | tr -d ' ')
for ((t=4380; t<=4860; t+=60)); do
    echo "$((BASE_EPOCH + t))" > "$TEST_ROOT/now"
    bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
done
GUARDIAN_AFTER=$(grep -c "GUARDIAN: corrective discharge session started" "$WLOG" 2>/dev/null | tr -d ' ')
APG_SUPPRESS=$(grep -c "suppressed (APG thermal pause)" "$WLOG" 2>/dev/null | tr -d ' ')
echo "phase C: apg_suppress=$APG_SUPPRESS (expected >= 1)"
echo "phase C: guardian before=$GUARDIAN_BEFORE after=$GUARDIAN_AFTER (expected equal)"
[ "$APG_SUPPRESS" -ge 1 ] || { echo "FAIL: APG suppression log"; FAIL=1; }
[ "$GUARDIAN_AFTER" -eq "$GUARDIAN_BEFORE" ] || { echo "FAIL: guardian session started while APG paused"; FAIL=1; }
[ -f "$DASH/.apg_paused" ] || { echo "FAIL: .apg_paused missing while APG red"; FAIL=1; }
[ "$(cat "$DASH/.apg_state" 2>/dev/null)" = "red" ] || { echo "FAIL: .apg_state is not red"; FAIL=1; }
echo "phase C: APG suppression OK"

# --- Phase D: charge_target cleanup (100%, mode charge_full) ---
echo "full" > "$TEST_ROOT/ioreg_mode"
echo "100" > "$DASH/.charge_target"
printf 'charge_full\n' > "$DASH/.active_mode"
echo "$((BASE_EPOCH + 4920))" > "$TEST_ROOT/now"
bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
[ -f "$DASH/.charge_target" ] && { echo "FAIL: .charge_target survived 100% tick"; FAIL=1; }
[ "$(cat "$DASH/.active_mode" 2>/dev/null)" = "hold" ] || { echo "FAIL: mode is not hold after 100%"; FAIL=1; }
echo "phase D: charge_target cleanup OK"

# --- Phase E: daemon not loaded ---
rm -f "$DASH/.daemon_check_state"
touch "$TEST_ROOT/launchctl_down"
echo "$((BASE_EPOCH + 4980))" > "$TEST_ROOT/now"
bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
grep -q "not loaded" "$WLOG" || { echo "FAIL: daemon not-loaded log missing"; FAIL=1; }
echo "phase E: daemon not-loaded log OK"

# --- Phase F: APG pause reason file (.apg_pause_reason, apggate) ---
# apg_classify maintains the reason next to .apg_paused on every
# tick: "thermal" (temp >= 38 C, or temp unreadable — fail safe),
# "load" (paused with a present temp below 38 C), and the file is
# removed whenever the pause clears. bc-limit v1.4+ gates its
# resume suppression on this file; .apg_paused stays existence-only.
REASON="$DASH/.apg_pause_reason"
echo "healthy" > "$TEST_ROOT/ioreg_mode"
rm -f "$TEST_ROOT/launchctl_down"

# F1: temp 45 C (thermal pause, APG red from Phase C setup) ->
# reason "thermal".
echo "45.0" > "$TEST_ROOT/pack_temp"
echo "$((BASE_EPOCH + 5040))" > "$TEST_ROOT/now"
bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
[ -f "$DASH/.apg_paused" ] || { echo "FAIL: F1 .apg_paused missing at temp 45"; FAIL=1; }
[ "$(cat "$REASON" 2>/dev/null)" = "thermal" ] || { echo "FAIL: F1 reason is not thermal"; FAIL=1; }
echo "phase F1: thermal reason OK"

# F2: temp drops to 30 C while load jumps to 9 (red by load alone;
# the reason must flip WITHOUT an APG state change) -> "load".
echo "30.0" > "$TEST_ROOT/pack_temp"
cat > "$BIN/sysctl" <<'EOF'
#!/bin/bash
echo "9.0 9.0 9.0"
EOF
chmod +x "$BIN/sysctl"
echo "$((BASE_EPOCH + 5100))" > "$TEST_ROOT/now"
bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
[ -f "$DASH/.apg_paused" ] || { echo "FAIL: F2 .apg_paused missing under load pause"; FAIL=1; }
[ "$(cat "$REASON" 2>/dev/null)" = "load" ] || { echo "FAIL: F2 reason is not load"; FAIL=1; }
echo "phase F2: load reason OK"

# F3: load subsides -> green, pause clears -> reason file removed.
cat > "$BIN/sysctl" <<'EOF'
#!/bin/bash
echo "1.0 1.0 1.0"
EOF
chmod +x "$BIN/sysctl"
echo "$((BASE_EPOCH + 5160))" > "$TEST_ROOT/now"
bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
[ -f "$DASH/.apg_paused" ] && { echo "FAIL: F3 .apg_paused survived green tick"; FAIL=1; }
[ -f "$REASON" ] && { echo "FAIL: F3 .apg_pause_reason survived pause clear"; FAIL=1; }
echo "phase F3: reason cleanup OK"

# F4: pause re-established hot, then the temp reading disappears
# (bc-status stub without a TempBatteryPack line) -> the pause is
# left untouched and the reason reads "thermal" (fail safe).
echo "45.0" > "$TEST_ROOT/pack_temp"
echo "$((BASE_EPOCH + 5220))" > "$TEST_ROOT/now"
bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
cat > "$BIN/bc-status" <<'EOF'
#!/bin/bash
echo "Capacity: 90.0%"
echo "TempCPU: 45.0°C"
echo "Health: 75.6%"
echo "Cycle: 568"
echo "BCLM: $(cat "$TEST_ROOT/bclm" 2>/dev/null || echo 100)"
echo "Backend: bclm"
echo "READ-ONLY DONE"
EOF
chmod +x "$BIN/bc-status"
echo "$((BASE_EPOCH + 5280))" > "$TEST_ROOT/now"
bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
[ -f "$DASH/.apg_paused" ] || { echo "FAIL: F4 .apg_paused lost on unknown temp"; FAIL=1; }
[ "$(cat "$REASON" 2>/dev/null)" = "thermal" ] || { echo "FAIL: F4 reason is not thermal on unknown temp"; FAIL=1; }
echo "phase F4: unknown-temp reason OK"

# F5: .apg_off clears the pause AND the reason file.
touch "$DASH/.apg_off"
echo "$((BASE_EPOCH + 3180))" > "$TEST_ROOT/now"
bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
[ -f "$DASH/.apg_paused" ] && { echo "FAIL: F5 .apg_paused survived .apg_off"; FAIL=1; }
[ -f "$REASON" ] && { echo "FAIL: F5 .apg_pause_reason survived .apg_off"; FAIL=1; }
rm -f "$DASH/.apg_off"
echo "phase F5: apg_off cleanup OK"

[ "$FAIL" -eq 0 ] && { echo "PASS"; exit 0; } || exit 1
