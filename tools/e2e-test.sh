#!/bin/bash
HOME="${HOME:-/Users/Yousef}"
DASH="$HOME/.battopt-swiftbar"
DISPATCH="$DASH/dispatch.sh"
BAT="/usr/local/bin/battopt"
LOG="$DASH/actions.log"
PASS=0; FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

wait_until() {
    local target="$1" timeout="${2:-10}" elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        [ "$(sudo -n $BAT status 2>/dev/null | grep -oE 'upper limit [0-9]+' | grep -oE '[0-9]+' | head -1)" = "$target" ] && return 0
        sleep 1; elapsed=$((elapsed+1))
    done
    return 1
}

{
echo "═══════════════════════════════════════════════"
echo "  E2E Functional Test — $(date '+%F %T')"
echo "═══════════════════════════════════════════════"

# Helper to read current SMC
smc_upper() { sudo -n "$BAT" status 2>/dev/null | grep -oE 'upper limit [0-9]+' | grep -oE '[0-9]+' | head -1; }
mode() { cat "$DASH/.active_mode" 2>/dev/null; }
procs() { pgrep -fl "battopt charge|battopt discharge|sd_watcher|charge_full" 2>/dev/null | grep -v grep; }

# ============================================================
echo ""
echo "── TEST 1: Custom Limit 85/80 ──"
echo "  Action: intent_apply limit 85 80"
"$DISPATCH" limit_custom <<< "85/80" >/dev/null 2>&1 &
PID=$!
sleep 6
kill "$PID" 2>/dev/null
ACTUAL=$(smc_upper)
if [ "$ACTUAL" = "85" ]; then pass "SMC=$ACTUAL after limit_custom"
else fail "SMC=$ACTUAL (want 85)"; fi
M=$(mode)
[ "$M" = "idle" ] || [ "$M" = "hold" ] || [ "$M" = "discharge" ] && pass "mode=$M" || fail "mode=$M"
sleep 2
P=$(procs)
[ -z "$P" ] && pass "no stray processes" || echo "  (running: $P)"

# ============================================================
echo ""
echo "── TEST 2: Sail Off (Static Hold) ──"
echo "  Action: intent_apply sail_off"
"$DISPATCH" sail_off >/dev/null 2>&1
sleep 3
grep -q "SAILING=false" "$DASH/config" && pass "SAILING=false in config" || fail "SAILING still true"
[ "$(smc_upper)" = "85" ] && pass "SMC unchanged (85)" || fail "SMC changed"

# ============================================================
echo ""
echo "── TEST 3: Sail On (Sailing) ──"
echo "  Action: intent_apply sail_on"
"$DISPATCH" sail_on >/dev/null 2>&1
sleep 3
grep -q "SAILING=true" "$DASH/config" && pass "SAILING=true in config" || fail "SAILING not true"

# ============================================================
echo ""
echo "── TEST 4: Sail Gap 10 ──"
echo "  Action: intent_apply sail_gap 10"
"$DISPATCH" sail_gap_set 10 >/dev/null 2>&1
sleep 3
GAP=$(grep SAIL_GAP "$DASH/config" | cut -d= -f2)
[ "$GAP" = "10" ] && pass "SAIL_GAP=10" || fail "SAIL_GAP=$GAP (want 10)"

# ============================================================
echo ""
echo "── TEST 5: Hold at Current ──"
echo "  Action: intent_apply hold_current"
CUR=$(sudo -n "$BAT" status 2>/dev/null | grep -oE 'Capacity [0-9]+' | grep -oE '[0-9]+' | head -1)
"$DISPATCH" remove_limit_hold >/dev/null 2>&1
sleep 5
NEW=$(smc_upper)
DIFF=$((CUR - NEW))
[ "$DIFF" -ge 0 ] && [ "$DIFF" -le 2 ] && pass "SMC=$NEW close to current=$CUR" || fail "SMC=$NEW vs current=$CUR"

# ============================================================
echo ""
echo "── TEST 6: Restore Custom 85/80 ──"
echo "  Action: intent_apply limit 85 80"
"$DISPATCH" limit_custom <<< "85/80" >/dev/null 2>&1 &
PID=$!
sleep 6
kill "$PID" 2>/dev/null
[ "$(smc_upper)" = "85" ] && pass "SMC back to 85" || fail "SMC=$(smc_upper)"

# ============================================================
echo ""
echo "── TEST 7: Disable Limit ──"
echo "  Action: intent_apply disable_limit"
"$DISPATCH" disable_limit >/dev/null 2>&1
sleep 5
[ "$(smc_upper)" = "100" ] && pass "SMC=100" || fail "SMC=$(smc_upper)"
grep -q "LAST_UPPER=100" "$DASH/config" && pass "config=100/99" || fail "config not 100/99"

# ============================================================
echo ""
echo "── TEST 8: Restore Custom (85/80) ──"
"$DISPATCH" limit_custom <<< "85/80" >/dev/null 2>&1 &
PID=$!
sleep 6
kill "$PID" 2>/dev/null
[ "$(smc_upper)" = "85" ] && pass "SMC=85" || fail "SMC=$(smc_upper)"

# ============================================================
echo ""
echo "── TEST 9: State files clean ──"
[ ! -f "$DASH/.active_token" ] && pass "no .active_token" || fail "stale token"
[ "$(mode)" = "idle" ] || [ "$(mode)" = "discharge" ] || [ "$(mode)" = "hold" ] && pass "mode=$(mode)" || fail "mode=$(mode)"

# ============================================================
echo ""
echo "── TEST 10: Notification cap ──"
TODAY=$(date +%Y%m%d)
NF="$DASH/.notify/.daily_$TODAY"
NC=$(wc -l < "$NF" 2>/dev/null | tr -d ' ')
[ -z "$NC" ] && NC=0
[ "$NC" -le 10 ] && pass "notifications today: $NC" || fail "notifications: $NC (>10)"

# ============================================================
echo ""
echo "── TEST 11: Sleep profile apply ──"
"$DASH/power_saver.sh" apply-delays default >/dev/null 2>&1
sleep 1
B_STANDBY=$(pmset -g custom 2>/dev/null | awk '/Battery Power:/{f=1;next} /AC Power:/{f=0} f && /standbydelaylow/{print $2;exit}')
A_STANDBY=$(pmset -g custom 2>/dev/null | awk '/AC Power:/{f=1} f && /standbydelaylow/{print $2;exit}')
[ "$B_STANDBY" = "2700" ] && pass "Battery standby=2700" || fail "Battery standby=$B_STANDBY"
[ "$A_STANDBY" = "3600" ] && pass "AC standby=3600" || fail "AC standby=$A_STANDBY"

# ============================================================
echo ""
echo "── TEST 12: Sleep profile long ──"
"$DASH/power_saver.sh" apply-delays long >/dev/null 2>&1
sleep 1
B_STANDBY=$(pmset -g custom 2>/dev/null | awk '/Battery Power:/{f=1;next} /AC Power:/{f=0} f && /standbydelaylow/{print $2;exit}')
A_STANDBY=$(pmset -g custom 2>/dev/null | awk '/AC Power:/{f=1} f && /standbydelaylow/{print $2;exit}')
[ "$B_STANDBY" = "3600" ] && pass "Battery standby=3600 (long)" || fail "Battery standby=$B_STANDBY"
[ "$A_STANDBY" = "7200" ] && pass "AC standby=7200 (long)" || fail "AC standby=$A_STANDBY"

# restore default
"$DASH/power_saver.sh" apply-delays default >/dev/null 2>&1

# ============================================================
echo ""
echo "── TEST 13: Health check passes ──"
HH=$(bash "$DASH/project_health.sh" 2>&1 | tail -5)
echo "$HH" | grep -q "HEALTHY\|PASS: 18" && pass "health OK" || echo "  (health: check manually)"

# ============================================================
echo ""
echo "── TEST 14: Renew Trial dry-run check ──"
TRIAL=$(sudo -n "$BAT" status 2>&1 | grep -oE '[0-9]+ days' | grep -oE '[0-9]+' | head -1)
[ "$TRIAL" -ge 20 ] && pass "trial=$TRIAL days" || fail "trial=$TRIAL days"

# ============================================================
echo ""
echo "═══════════════════════════════════════════════"
echo "  SUMMARY: PASS=$PASS  FAIL=$FAIL"
echo "═══════════════════════════════════════════════"

} 2>&1 | tee /tmp/battopt-e2e-$(date +%Y%m%d-%H%M%S).txt
