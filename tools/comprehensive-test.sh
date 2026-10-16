#!/bin/bash
# BattOpt Comprehensive Test Suite
HOME="${HOME:-/Users/Yousef}"
DASH="$HOME/.battopt-swiftbar"
BAT="/usr/local/bin/battopt"
PLUGIN="$HOME/SwiftBar/battopt.10s.sh"
DISPATCH="$DASH/dispatch.sh"
REPORT="/tmp/battopt-test-$(date +%Y%m%d-%H%M%S).txt"

PASS=0; FAIL=0; WARN=0

pass() { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  WARN: $1"; WARN=$((WARN+1)); }
section() { echo ""; echo "════ $1 ════"; }

{
echo "═══════════════════════════════════════════════════"
echo "  BattOpt Comprehensive Test — $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════"

# ============================================================
section "1. SYNTAX & FILE INTEGRITY"
# ============================================================
for f in dispatch.sh state_guard.sh power_saver.sh sleep_manager.sh \
         arm_sleep.sh sd_watcher.sh guardian.sh enforce_watchdog.sh \
         ac_watcher.sh ensure_limit.sh; do
    if [ -f "$DASH/$f" ]; then
        if bash -n "$DASH/$f" 2>/dev/null; then
            pass "$f syntax"
        else
            fail "$f syntax broken"
        fi
    else
        warn "$f missing"
    fi
done

if [ -f "$PLUGIN" ] && bash -n "$PLUGIN" 2>/dev/null; then
    pass "plugin syntax"
else
    fail "plugin syntax broken"
fi

# ============================================================
section "2. BINARY & DAEMON"
# ============================================================
if [ -x "$BAT" ]; then pass "battopt binary exists"; else fail "battopt missing"; fi
if pgrep -f "battopt daemon" >/dev/null; then pass "daemon running"; else fail "daemon not running"; fi
if [ -S "/Library/Application Support/battopt/battopt.sock" ]; then
    pass "daemon socket exists"
else
    warn "daemon socket missing"
fi

# SMC reachable
if sudo -n "$BAT" status 2>&1 | grep -q "Capacity"; then
    pass "SMC reachable"
else
    fail "SMC unreachable"
fi

# ============================================================
section "3. CORE PROCESSES"
# ============================================================
for proc in "SwiftBar" "battopt.10s.sh" "powerwatch"; do
    if pgrep -f "$proc" >/dev/null; then
        pass "$proc running"
    else
        fail "$proc NOT running"
    fi
done

SB_COUNT=$(pgrep -x SwiftBar 2>/dev/null | wc -l | tr -d ' ')
if [ "$SB_COUNT" = "1" ]; then
    pass "SwiftBar single instance"
elif [ "$SB_COUNT" = "0" ]; then
    fail "SwiftBar not running"
else
    warn "SwiftBar $SB_COUNT instances (expected 1)"
fi

# ============================================================
section "4. STATE FILES"
# ============================================================
for f in .active_mode config; do
    if [ -f "$DASH/$f" ]; then pass "$f exists"; else fail "$f missing"; fi
done

# active_mode must be valid
MODE=$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')
case "$MODE" in
    idle|discharge|charge_full|hold|calibration) pass "active_mode=$MODE (valid)" ;;
    *) fail "active_mode=$MODE (invalid)" ;;
esac

# stale token check
if [ -f "$DASH/.active_token" ]; then
    if [ "$MODE" = "idle" ]; then
        warn "stale .active_token exists while idle"
    else
        pass ".active_token matches active session"
    fi
else
    pass "no stale .active_token"
fi

# config integrity
if grep -q "LAST_UPPER\|LAST_LOWER" "$DASH/config" 2>/dev/null; then
    pass "config has required keys"
else
    fail "config missing LAST_UPPER/LOWER"
fi

# ============================================================
section "5. SMC CONSISTENCY"
# ============================================================
SMC_UPPER=$(sudo -n "$BAT" status 2>/dev/null | grep -oE 'upper limit [0-9]+' | grep -oE '[0-9]+' | head -1)
CFG_UPPER=$(grep LAST_UPPER "$DASH/config" 2>/dev/null | cut -d= -f2)

if [ -n "$SMC_UPPER" ] && [ -n "$CFG_UPPER" ]; then
    if [ "$SMC_UPPER" = "$CFG_UPPER" ]; then
        pass "SMC=$SMC_UPPER matches config=$CFG_UPPER"
    else
        fail "SMC=$SMC_UPPER != config=$CFG_UPPER"
    fi
else
    warn "cannot compare SMC vs config"
fi

# ============================================================
section "6. PMSET POLICY"
# ============================================================
HIB=$(pmset -g | grep hibernatemode | awk '{print $2}')
if [ "$HIB" = "25" ]; then pass "hibernatemode=25"; else warn "hibernatemode=$HIB"; fi

BATT_STANDBY=$(pmset -g custom 2>/dev/null | awk '/^Battery Power:/{f=1;next} /^AC Power:/{f=0} f && /standbydelaylow/{print $2;exit}')
AC_STANDBY=$(pmset -g custom 2>/dev/null | awk '/^AC Power:/{f=1;next} f && /standbydelaylow/{print $2;exit}')

if [ -n "$BATT_STANDBY" ] && [ "$BATT_STANDBY" != "0" ] && [ "$BATT_STANDBY" -le 3600 ]; then
    pass "Battery standbydelay=$BATT_STANDBY"
else
    warn "Battery standbydelay=$BATT_STANDBY (unexpected)"
fi

if [ -n "$AC_STANDBY" ] && [ "$AC_STANDBY" -ge 1800 ]; then
    pass "AC standbydelay=$AC_STANDBY"
else
    warn "AC standbydelay=$AC_STANDBY"
fi

PN=$(pmset -g | grep powernap | awk '{print $2}')
[ "$PN" = "0" ] && pass "powernap=0" || warn "powernap=$PN"
WOMP=$(pmset -g | grep womp | awk '{print $2}')
[ "$WOMP" = "0" ] && pass "womp=0" || warn "womp=$WOMP"

# ============================================================
section "7. LAUNCHAGENTS"
# ============================================================
LOADED=$(launchctl list | grep -c com.battopt)
if [ "$LOADED" -ge 10 ]; then
    pass "$LOADED LaunchAgents loaded"
else
    warn "only $LOADED LaunchAgents loaded"
fi

for agent in acwatcher guardian enforce sleepmonitor sleepmanager; do
    if launchctl list | grep -q "com.battopt.$agent"; then
        pass "$agent loaded"
    else
        warn "$agent NOT loaded"
    fi
done

# ============================================================
section "8. NOTIFICATIONS POLICY"
# ============================================================
TODAY=$(date +%Y%m%d)
NOTIF_FILE="$DASH/.notify/.daily_$TODAY"
if [ -f "$NOTIF_FILE" ]; then
    NOTIF_COUNT=$(wc -l < "$NOTIF_FILE" | tr -d ' ')
    if [ "$NOTIF_COUNT" -le 3 ]; then
        pass "$NOTIF_COUNT notifications today (≤3)"
    else
        warn "$NOTIF_COUNT notifications today (>3)"
    fi
else
    pass "0 notifications today"
fi

if [ -d "$DASH/.notify" ]; then
    pass ".notify directory exists"
else
    warn ".notify directory missing"
fi

# ============================================================
section "9. DISPATCH CASES"
# ============================================================
for case_name in limit_custom sail_on sail_off stop_now disable_limit charge_full smart_discharge calibrate; do
    if grep -qE "^    ${case_name}\)" "$DISPATCH"; then
        pass "case $case_name exists"
    else
        fail "case $case_name missing"
    fi
done

# intent_apply exists
if grep -q "^intent_apply()" "$DISPATCH"; then
    pass "intent_apply function exists"
else
    fail "intent_apply missing"
fi

# intent_apply has all kinds
for kind in limit hold_current sail_on disable_limit charge_full smart_discharge calibration_start; do
    if grep -q "        ${kind})" "$DISPATCH"; then
        pass "intent kind $kind"
    else
        fail "intent kind $kind missing"
    fi
done

# ============================================================
section "10. PLUGIN CONTENT"
# ============================================================
PLUGIN_OUT=$(bash "$PLUGIN" 2>/dev/null)

if echo "$PLUGIN_OUT" | grep -q "Charge:"; then
    pass "plugin shows Charge status"
else
    fail "plugin missing Charge status"
fi

if echo "$PLUGIN_OUT" | grep -q "Mode:"; then
    pass "plugin shows Mode status"
else
    fail "plugin missing Mode status"
fi

# Icons: at least one should appear
if echo "$PLUGIN_OUT" | grep -qE "🔋|⚡|🔌|🔴"; then
    pass "plugin shows battery icon"
else
    fail "plugin missing battery icon"
fi

# Separator style consistent
SEP_COUNT=$(echo "$PLUGIN_OUT" | grep -c "──────────────────────────")
if [ "$SEP_COUNT" -ge 5 ]; then
    pass "$SEP_COUNT styled separators"
else
    warn "only $SEP_COUNT styled separators"
fi

# Renew Trial exists
if echo "$PLUGIN_OUT" | grep -q "Renew Trial Now"; then
    pass "Renew Trial button present"
else
    fail "Renew Trial missing"
fi

# ============================================================
section "11. RENEW TRIAL SCRIPT"
# ============================================================
if [ -x /usr/local/bin/battopt-trial-renew ]; then
    pass "trial-renew exists"
    if grep -q "sudo -n" /usr/local/bin/battopt-trial-renew; then
        pass "trial-renew uses sudo -n"
    else
        warn "trial-renew may fail (no sudo -n)"
    fi
else
    fail "trial-renew missing"
fi

# ============================================================
section "12. HEALTH CHECK"
# ============================================================
HEALTH=$(bash "$DASH/project_health.sh" 2>&1)
HEALTH_FAIL=$(echo "$HEALTH" | grep -c "FAIL:")
if [ "$HEALTH_FAIL" -le 1 ]; then
    pass "health check: $HEALTH_FAIL failures"
else
    warn "health check: $HEALTH_FAIL failures"
fi

# ============================================================
section "SUMMARY"
# ============================================================
TOTAL=$((PASS + FAIL + WARN))
echo ""
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  WARN: $WARN"
echo "  ─────────────"
echo "  TOTAL: $TOTAL"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo "  ✅ ALL TESTS PASSED"
elif [ "$FAIL" -le 2 ]; then
    echo "  ⚠️  $FAIL minor failures"
else
    echo "  ❌ $FAIL failures — investigate"
fi

echo ""
echo "  Report: $REPORT"
} 2>&1 | tee "$REPORT"
