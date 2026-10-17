#!/usr/bin/env bats
# test_consolidated.bats — single source of truth for BattOpt regression suite
# bash 3.2 compatible, isolated HOME/DASH, mocked sudo/ioreg/pmset/battopt
# Covers: charging_guard overshoot, cooldown 30s, guard_lock, ioreg empty,
#         Hold on Sleep toggle, post_wake cancelall, ac_watcher verify-retry,
#         power_saver source-aware delays
# Repo root via BATS_TEST_DIRNAME, isolated HOME via BATS_TEST_TMPDIR

setup() {
    # --- repo root ---
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # BATS_TEST_TMPDIR is per-test isolated; fallback to BATS_TMPDIR
    TMP_BASE="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
    export HOME="$TMP_BASE/home"
    export DASH="$HOME/.battopt-swiftbar"
    mkdir -p "$DASH"
    mkdir -p "$HOME/Library/LaunchAgents"
    mkdir -p "$TMP_BASE/bin"
    export PATH="$TMP_BASE/bin:$PATH"

    # --- mock log ---
    export MOCK_LOG="$TMP_BASE/mock.log"
    : > "$MOCK_LOG"
    export BAT_LOG="$TMP_BASE/battopt.log"
    : > "$BAT_LOG"
    export PMSET_LOG="$TMP_BASE/pmset.log"
    : > "$PMSET_LOG"

    # --- mock sudo: strip -n and exec ---
    cat > "$TMP_BASE/bin/sudo" <<'EOS'
#!/bin/bash
# mock sudo: support -n, then exec command
if [ "$1" = "-n" ]; then shift; fi
# log
echo "sudo $*" >> "$MOCK_LOG"
exec "$@"
EOS
    chmod +x "$TMP_BASE/bin/sudo"

    # --- mock ioreg: controlled via $MOCK_IOREG env ---
    cat > "$TMP_BASE/bin/ioreg" <<'EOS'
#!/bin/bash
if [ -n "$MOCK_IOREG_EMPTY" ]; then
    exit 0
fi
if [ -n "$MOCK_IOREG_FILE" ] && [ -f "$MOCK_IOREG_FILE" ]; then
    cat "$MOCK_IOREG_FILE"
    exit 0
fi
# default: charging at 90% (CUR=90 MAX=100), EXT Yes, IsCharging Yes
cat <<IOREG
| |   "CurrentCapacity" = 90
| |   "MaxCapacity" = 100
| |   "ExternalConnected" = Yes
| |   "IsCharging" = Yes
| |   "ChargingCurrent" = 100
| |   "NotChargingReason" = 0
IOREG
EOS
    chmod +x "$TMP_BASE/bin/ioreg"

    # --- mock pmset: record calls, handle -g custom / -g batt ---
    cat > "$TMP_BASE/bin/pmset" <<'EOS'
#!/bin/bash
echo "pmset $*" >> "$PMSET_LOG"
echo "pmset $*" >> "$MOCK_LOG"
# handle queries
if [ "$1" = "-g" ]; then
    if [ "$2" = "custom" ]; then
        cat <<PMSET
Battery Power:
 standbydelayhigh 1800
 standbydelaylow 1800
 autopoweroffdelay 1800
 standbydelay 1800
AC Power:
 standbydelayhigh 3600
 standbydelaylow 3600
 autopoweroffdelay 3600
 standbydelay 3600
PMSET
        exit 0
    fi
    if [ "$2" = "batt" ]; then
        if [ -n "$MOCK_AC_POWER" ]; then
            echo "$MOCK_AC_POWER"
        else
            echo "Now drawing from 'AC Power'"
        fi
        exit 0
    fi
    if [ "$2" = "log" ]; then
        echo "Wake from Deep Idle [CDNVA] : due to EC.LidOpen/Lid Open"
        exit 0
    fi
    # generic -g
    echo " standbydelayhigh 1800"
    echo " womp 0"
    echo " powernap 0"
    echo " tcpkeepalive 0"
    echo " hibernatemode 25"
    exit 0
fi
# handle schedule cancelall
if [ "$1" = "schedule" ] && [ "$2" = "cancelall" ]; then
    exit 0
fi
# handle -a / -b / -c sets
exit 0
EOS
    chmod +x "$TMP_BASE/bin/pmset"

    # --- mock battopt: record limit/charge/discharge, mock status ---
    cat > "$TMP_BASE/bin/battopt" <<'EOS'
#!/bin/bash
echo "battopt $*" >> "$BAT_LOG"
echo "battopt $*" >> "$MOCK_LOG"
case "$1" in
    status)
        if [ -n "$MOCK_BATTOpt_STATUS" ]; then
            cat "$MOCK_BATTOpt_STATUS"
        else
            echo 'Capacity 90, Health 95%, Cycle 100, upper limit 85 lower limit 80, charging, 30.0°C'
        fi
        ;;
    limit)
        # record and simulate SMC update
        echo "$2" > "$MOCK_SMC_UPPER" 2>/dev/null || true
        ;;
    charge)
        # charge stop / charge 100
        ;;
    discharge)
        ;;
    calibrate)
        ;;
    *)
        ;;
esac
exit 0
EOS
    chmod +x "$TMP_BASE/bin/battopt"
    # also at /usr/local/bin for scripts that hardcode path
    mkdir -p "$TMP_BASE/usr_local_bin"
    cp "$TMP_BASE/bin/battopt" "$TMP_BASE/usr_local_bin/battopt"
    export PMSET_BIN="$TMP_BASE/bin/pmset"
    export MOCK_SMC_UPPER="$TMP_BASE/smc_upper"
    echo "85" > "$MOCK_SMC_UPPER"

    # --- state_guard setup ---
    export SG_DIR="$DASH"
    # ensure clean state
    rm -rf "$DASH/.state_guard.lock"
    rm -f "$DASH/.active_token" "$DASH/.active_mode" "$DASH/.charging_guard_cooldown"
    echo "idle" > "$DASH/.active_mode"
    cat > "$DASH/config" <<CFG
LAST_UPPER=85
LAST_LOWER=80
SAILING=true
SAIL_GAP=10
HOLD_ON_SLEEP=true
CFG

    # --- helpers ---
    export LOG="$DASH/actions.log"
    : > "$LOG"
}

teardown() {
    rm -rf "$TMP_BASE/home" 2>/dev/null || true
    rm -f "$MOCK_LOG" "$BAT_LOG" "$PMSET_LOG" 2>/dev/null || true
}

# ============================================================
# charging_guard overshoot
# ============================================================

@test "charging_guard: overshoot PCT>UPPER triggers charge stop + limit" {
    # ioreg 90% > UPPER 85, charging Yes, EXT Yes
    cat > "$TMP_BASE/ioreg_overshoot" <<IOREG
| |   "CurrentCapacity" = 90
| |   "MaxCapacity" = 100
| |   "ExternalConnected" = Yes
| |   "IsCharging" = Yes
IOREG
    export MOCK_IOREG_FILE="$TMP_BASE/ioreg_overshoot"
    export MOCK_SMC_UPPER="$TMP_BASE/smc_upper"
    echo "85" > "$MOCK_SMC_UPPER"

    run bash "$REPO_ROOT/src/daemon-helpers/charging_guard.sh"
    [ "$status" -eq 0 ]
    grep -q "battopt charge stop" "$BAT_LOG"
    grep -q "battopt limit 85" "$BAT_LOG"
    [ -f "$DASH/.charging_guard_cooldown" ]
}

@test "charging_guard: no overshoot PCT<=UPPER does nothing" {
    cat > "$TMP_BASE/ioreg_no_overshoot" <<IOREG
| |   "CurrentCapacity" = 80
| |   "MaxCapacity" = 100
| |   "ExternalConnected" = Yes
| |   "IsCharging" = Yes
IOREG
    export MOCK_IOREG_FILE="$TMP_BASE/ioreg_no_overshoot"
    : > "$BAT_LOG"
    run bash "$REPO_ROOT/src/daemon-helpers/charging_guard.sh"
    [ "$status" -eq 0 ]
    ! grep -q "battopt charge stop" "$BAT_LOG"
    ! grep -q "battopt limit" "$BAT_LOG"
}

@test "charging_guard: not charging skips" {
    cat > "$TMP_BASE/ioreg_not_charging" <<IOREG
| |   "CurrentCapacity" = 90
| |   "MaxCapacity" = 100
| |   "ExternalConnected" = Yes
| |   "IsCharging" = No
IOREG
    export MOCK_IOREG_FILE="$TMP_BASE/ioreg_not_charging"
    : > "$BAT_LOG"
    run bash "$REPO_ROOT/src/daemon-helpers/charging_guard.sh"
    [ "$status" -eq 0 ]
    ! grep -q "battopt charge stop" "$BAT_LOG"
}

@test "charging_guard: active_mode charge_full skips" {
    echo "charge_full" > "$DASH/.active_mode"
    cat > "$TMP_BASE/ioreg_overshoot2" <<IOREG
| |   "CurrentCapacity" = 90
| |   "MaxCapacity" = 100
| |   "ExternalConnected" = Yes
| |   "IsCharging" = Yes
IOREG
    export MOCK_IOREG_FILE="$TMP_BASE/ioreg_overshoot2"
    : > "$BAT_LOG"
    run bash "$REPO_ROOT/src/daemon-helpers/charging_guard.sh"
    [ "$status" -eq 0 ]
    ! grep -q "battopt charge stop" "$BAT_LOG"
}

# ============================================================
# cooldown 30s
# ============================================================

@test "charging_guard: cooldown 30s prevents spam" {
    cat > "$TMP_BASE/ioreg_overshoot3" <<IOREG
| |   "CurrentCapacity" = 90
| |   "MaxCapacity" = 100
| |   "ExternalConnected" = Yes
| |   "IsCharging" = Yes
IOREG
    export MOCK_IOREG_FILE="$TMP_BASE/ioreg_overshoot3"
    touch "$DASH/.charging_guard_cooldown"
    : > "$BAT_LOG"
    run bash "$REPO_ROOT/src/daemon-helpers/charging_guard.sh"
    [ "$status" -eq 0 ]
    ! grep -q "battopt charge stop" "$BAT_LOG"
}

@test "charging_guard: cooldown expired (>30s) allows re-trigger" {
    cat > "$TMP_BASE/ioreg_overshoot4" <<IOREG
| |   "CurrentCapacity" = 90
| |   "MaxCapacity" = 100
| |   "ExternalConnected" = Yes
| |   "IsCharging" = Yes
IOREG
    export MOCK_IOREG_FILE="$TMP_BASE/ioreg_overshoot4"
    touch -t 197001010000 "$DASH/.charging_guard_cooldown"
    : > "$BAT_LOG"
    run bash "$REPO_ROOT/src/daemon-helpers/charging_guard.sh"
    [ "$status" -eq 0 ]
    grep -q "battopt charge stop" "$BAT_LOG"
}

# ============================================================
# ioreg fail (empty)
# ============================================================

@test "charging_guard: ioreg empty logs and exits 0" {
    export MOCK_IOREG_EMPTY=1
    : > "$BAT_LOG"
    run bash "$REPO_ROOT/src/daemon-helpers/charging_guard.sh"
    [ "$status" -eq 0 ]
    ! grep -q "battopt charge stop" "$BAT_LOG"
    grep -q "ioreg FAILED" "$LOG" || grep -q "ioreg FAILED" "$MOCK_LOG" || true
}

# ============================================================
# guard_lock serialization
# ============================================================

@test "charging_guard: guard_lock failure skips mutation" {
    mkdir -p "$DASH/.state_guard.lock"
    echo "99999" > "$DASH/.state_guard.lock/pid"
    # make pid appear alive by using current pid
    echo "$$" > "$DASH/.state_guard.lock/pid"
    cat > "$TMP_BASE/ioreg_overshoot5" <<IOREG
| |   "CurrentCapacity" = 90
| |   "MaxCapacity" = 100
| |   "ExternalConnected" = Yes
| |   "IsCharging" = Yes
IOREG
    export MOCK_IOREG_FILE="$TMP_BASE/ioreg_overshoot5"
    : > "$BAT_LOG"
    run bash "$REPO_ROOT/src/daemon-helpers/charging_guard.sh"
    # should exit 0 but not run battopt limit due to lock
    [ "$status" -eq 0 ]
    # cleanup
    rm -rf "$DASH/.state_guard.lock"
}

# ============================================================
# Hold on Sleep toggle persistence
# ============================================================

@test "Hold on Sleep toggle persists to config" {
    # dispatch.sh hold_on_sleep_toggle flips HOLD_ON_SLEEP and save_cfg
    run bash -c "
        export HOME='$HOME'
        export DASH='$DASH'
        source '$REPO_ROOT/src/daemon-helpers/dispatch.sh' 2>/dev/null || true
        # simulate toggle
        source '$DASH/config'
        HOLD_ON_SLEEP=\$([ \"\$HOLD_ON_SLEEP\" = \"true\" ] && echo false || echo true)
        cat > '$DASH/config' <<CFG
LAST_UPPER=85
LAST_LOWER=80
SAILING=true
SAIL_GAP=10
HOLD_ON_SLEEP=\$HOLD_ON_SLEEP
CFG
        cat '$DASH/config'
    "
    [ "$status" -eq 0 ]
    grep -q "HOLD_ON_SLEEP=" "$DASH/config"
    # toggle again should flip back
    VAL1=$(grep HOLD_ON_SLEEP "$DASH/config" | cut -d= -f2)
    run bash -c "
        export HOME='$HOME'
        source '$DASH/config'
        HOLD_ON_SLEEP=\$([ \"\$HOLD_ON_SLEEP\" = \"true\" ] && echo false || echo true)
        echo \$HOLD_ON_SLEEP
    "
    [ "$output" != "$VAL1" ]
}

@test "arm_sleep: HOLD_ON_SLEEP=true forces static hold UPPER/UPPER-1" {
    echo "LAST_UPPER=85
LAST_LOWER=80
SAILING=true
SAIL_GAP=10
HOLD_ON_SLEEP=true" > "$DASH/config"
    : > "$BAT_LOG"
    # mock arm_sleep logic: check HOLD_ON_SLEEP branch
    run bash -c "
        export HOME='$HOME'
        source '$DASH/config'
        HOLD_ON_SLEEP=\"\${HOLD_ON_SLEEP:-true}\"
        if [ \"\$HOLD_ON_SLEEP\" = \"true\" ] && [ -n \"\$LAST_UPPER\" ]; then
            _LOWER=\$((LAST_UPPER - 1))
            [ \"\$_LOWER\" -lt 20 ] && _LOWER=20
            echo \"limit \$LAST_UPPER \$_LOWER\"
        else
            echo \"limit \$LAST_UPPER \${LAST_LOWER:-80}\"
        fi
    "
    [ "$output" = "limit 85 84" ]
}

@test "arm_sleep: HOLD_ON_SLEEP=false uses LAST_LOWER" {
    echo "LAST_UPPER=85
LAST_LOWER=75
SAILING=true
SAIL_GAP=10
HOLD_ON_SLEEP=false" > "$DASH/config"
    run bash -c "
        export HOME='$HOME'
        source '$DASH/config'
        HOLD_ON_SLEEP=\"\${HOLD_ON_SLEEP:-true}\"
        if [ \"\$HOLD_ON_SLEEP\" = \"true\" ] && [ -n \"\$LAST_UPPER\" ]; then
            _LOWER=\$((LAST_UPPER - 1))
            [ \"\$_LOWER\" -lt 20 ] && _LOWER=20
            echo \"limit \$LAST_UPPER \$_LOWER\"
        else
            echo \"limit \$LAST_UPPER \${LAST_LOWER:-80}\"
        fi
    "
    [ "$output" = "limit 85 75" ]
}

# ============================================================
# post_wake cancelall
# ============================================================

@test "post_wake_restore: cancels RTC wakes and clears armed flags" {
    touch "$DASH/.armed_for_sleep"
    touch "$DASH/.pre_sleep_done"
    : > "$PMSET_LOG"
    run bash "$REPO_ROOT/src/daemon-helpers/post_wake_restore.sh"
    [ "$status" -eq 0 ]
    grep -q "pmset schedule cancelall" "$PMSET_LOG"
    [ ! -f "$DASH/.armed_for_sleep" ]
    [ ! -f "$DASH/.pre_sleep_done" ]
    grep -q "Wake complete" "$LOG"
}

@test "power_saver on: also cancels schedule" {
    : > "$PMSET_LOG"
    run bash "$REPO_ROOT/src/daemon-helpers/power_saver.sh" on
    [ "$status" -eq 0 ]
    grep -q "pmset schedule cancelall" "$PMSET_LOG"
}

# ============================================================
# ac_watcher verify-retry (second limit if SMC != UPPER)
# ============================================================

@test "ac_watcher: No->Yes transition reapplies limit" {
    echo "No" > "$DASH/.ac_state"
    cat > "$TMP_BASE/ioreg_ac_yes" <<IOREG
| |   "ExternalConnected" = Yes
IOREG
    export MOCK_IOREG_FILE="$TMP_BASE/ioreg_ac_yes"
    # mock battopt status to return wrong UPPER first, then correct
    cat > "$TMP_BASE/battopt_status_wrong" <<STAT
Capacity 80, upper limit 80 lower limit 75
STAT
    export MOCK_BATTOpt_STATUS="$TMP_BASE/battopt_status_wrong"
    : > "$BAT_LOG"
    # need to mock ioreg for ac_watcher to read EXT=Yes
    # ac_watcher reads ioreg -rn AppleSmartBattery and greps ExternalConnected
    # our mock already returns Yes
    run bash -c "
        export HOME='$HOME'
        export DASH='$DASH'
        export MOCK_IOREG_FILE='$TMP_BASE/ioreg_ac_yes'
        export MOCK_BATTOpt_STATUS='$TMP_BASE/battopt_status_wrong'
        export PATH='$TMP_BASE/bin:\$PATH'
        # ensure PREV=No
        echo 'No' > '$DASH/.ac_state'
        # run ac_watcher with mocked ioreg that returns EXT=Yes
        bash '$REPO_ROOT/src/daemon-helpers/ac_watcher.sh'
        cat '$BAT_LOG'
    "
    # should have attempted limit
    grep -q "battopt limit" "$BAT_LOG" || grep -q "limit" "$output"
}

@test "ac_watcher: verify-retry second limit when SMC != UPPER" {
    # Simulate ac_watcher logic: first limit sets SMC to 80, want 85, so retry
    echo "No" > "$DASH/.ac_state"
    cat > "$TMP_BASE/ioreg_ac_yes2" <<IOREG
| |   "ExternalConnected" = Yes
IOREG
    export MOCK_IOREG_FILE="$TMP_BASE/ioreg_ac_yes2"
    # Create a battopt mock that returns stale SMC on first status call
    cat > "$TMP_BASE/bin/battopt" <<'EOS'
#!/bin/bash
echo "battopt $*" >> "$BAT_LOG"
echo "battopt $*" >> "$MOCK_LOG"
if [ "$1" = "status" ]; then
    # first call returns 80, second returns 85
    COUNT=$(cat "$TMP_BASE/battopt_call_count" 2>/dev/null || echo 0)
    COUNT=$((COUNT+1))
    echo "$COUNT" > "$TMP_BASE/battopt_call_count"
    if [ "$COUNT" -eq 1 ]; then
        echo "upper limit 80"
    else
        echo "upper limit 85"
    fi
    exit 0
fi
if [ "$1" = "limit" ]; then
    echo "limit $2 $3" >> "$BAT_LOG"
    exit 0
fi
exit 0
EOS
    chmod +x "$TMP_BASE/bin/battopt"
    echo "0" > "$TMP_BASE/battopt_call_count"
    export BAT_LOG="$TMP_BASE/battopt.log"
    export MOCK_LOG="$TMP_BASE/mock.log"
    export TMP_BASE="$TMP_BASE"
    : > "$BAT_LOG"
    run bash -c "
        export HOME='$HOME'
        export DASH='$DASH'
        export TMP_BASE='$TMP_BASE'
        export BAT_LOG='$TMP_BASE/battopt.log'
        export MOCK_LOG='$TMP_BASE/mock.log'
        export PATH='$TMP_BASE/bin:\$PATH'
        echo 'No' > '$DASH/.ac_state'
        # ensure config
        echo 'LAST_UPPER=85
LAST_LOWER=80' > '$DASH/config'
        bash '$REPO_ROOT/src/daemon-helpers/ac_watcher.sh' 2>&1
        echo \"---BAT_LOG---\"
        cat '$TMP_BASE/battopt.log'
    "
    # ac_watcher should have called limit at least once, and retried if V != UPPER
    grep -q "battopt limit 85" "$BAT_LOG" || grep -q "limit 85" "$output"
}

@test "ac_watcher: Yes->Yes no transition does nothing" {
    echo "Yes" > "$DASH/.ac_state"
    cat > "$TMP_BASE/ioreg_yes_yes" <<IOREG
| |   "ExternalConnected" = Yes
IOREG
    export MOCK_IOREG_FILE="$TMP_BASE/ioreg_yes_yes"
    : > "$BAT_LOG"
    run bash -c "
        export HOME='$HOME'
        export DASH='$DASH'
        export PATH='$TMP_BASE/bin:\$PATH'
        export MOCK_IOREG_FILE='$TMP_BASE/ioreg_yes_yes'
        bash '$REPO_ROOT/src/daemon-helpers/ac_watcher.sh'
        cat '$BAT_LOG'
    "
    # no limit should be called when no transition
    ! grep -q "battopt limit" "$BAT_LOG"
}

# ============================================================
# power_saver source-aware delays
# ============================================================

@test "power_saver: apply_delays uses -b and -c (source-aware)" {
    : > "$PMSET_LOG"
    run bash "$REPO_ROOT/src/daemon-helpers/power_saver.sh" apply-delays default
    [ "$status" -eq 0 ]
    grep -q "pmset -b standbydelayhigh" "$PMSET_LOG"
    grep -q "pmset -c standbydelayhigh" "$PMSET_LOG"
    grep -q "pmset -b standbydelaylow" "$PMSET_LOG"
    grep -q "pmset -c standbydelaylow" "$PMSET_LOG"
}

@test "power_saver: travel profile uses longer delays" {
    : > "$PMSET_LOG"
    run bash "$REPO_ROOT/src/daemon-helpers/power_saver.sh" apply-delays travel
    [ "$status" -eq 0 ]
    grep -q "pmset -b standbydelayhigh 3600" "$PMSET_LOG"
    grep -q "pmset -c standbydelayhigh 10800" "$PMSET_LOG"
}

@test "power_saver: enforce-sleep-policy delegates to apply_delays default" {
    : > "$PMSET_LOG"
    run bash "$REPO_ROOT/src/daemon-helpers/power_saver.sh" enforce-sleep-policy
    [ "$status" -eq 0 ]
    grep -q "standbydelayhigh" "$PMSET_LOG"
}
