#!/bin/bash
HOME="${HOME:-/Users/Yousef}"
DASH="$HOME/.battopt-swiftbar"
BAT="/usr/local/bin/battopt"
PLUGIN="$HOME/SwiftBar/battopt.10s.sh"
DISPATCH="$DASH/dispatch.sh"
REPORT="/tmp/battopt-deep-$(date +%Y%m%d-%H%M%S).txt"
PASS=0; FAIL=0; WARN=0
pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN+1)); }
section() { echo ""; echo "════ $1 ════"; }

{
echo "═══ BattOpt Deep Test — $(date '+%F %T') ═══"

# 1. INTEGRITY — 25 files
section "1. FILE INTEGRITY (25 files)"
for f in dispatch.sh state_guard.sh power_saver.sh sleep_manager.sh \
         arm_sleep.sh sd_watcher.sh guardian.sh enforce_watchdog.sh \
         ac_watcher.sh ensure_limit.sh force_reset.sh consolidated_checks.sh \
         pre_sleep_cleanup.sh post_wake_restore.sh wake_analyzer.sh \
         sleep_monitor.sh project_health.sh; do
    [ -f "$DASH/$f" ] && bash -n "$DASH/$f" 2>/dev/null && pass "$f" || fail "$f"
done
for f in plugin/battopt.10s.sh; do
    bash -n "$HOME/Desktop/BattOpt-CC-Release/src/$f" 2>/dev/null && pass "$f" || fail "$f"
done

# 2. BINARY
section "2. BINARY"
[ -x "$BAT" ] && pass "battopt executable" || fail "battopt missing"
file "$BAT" | grep -q "Mach-O" && pass "valid Mach-O binary" || warn "unexpected binary type"
[ -x /usr/local/bin/battopt-trial-renew ] && pass "trial-renew present" || fail "trial-renew missing"
[ -x /usr/local/bin/battopt-release-cfg ] && pass "release-cfg present" || warn "release-cfg missing"
[ -x /usr/local/bin/battopt-restore-cfg ] && pass "restore-cfg present" || warn "restore-cfg missing"
[ -x /usr/local/bin/battopt-daemon-start ] && pass "daemon-start present" || warn "daemon-start missing"

# 3. DAEMON
section "3. DAEMON"
pgrep -f "battopt daemon" >/dev/null && pass "daemon running" || fail "daemon down"
DAEMON_PID=$(pgrep -f "battopt daemon" | head -1)
[ -n "$DAEMON_PID" ] && {
    D_START=$(ps -p "$DAEMON_PID" -o lstart= 2>/dev/null)
    D_ELAPSED=$(ps -p "$DAEMON_PID" -o etime= 2>/dev/null | tr -d ' ')
    echo "       PID=$DAEMON_PID up=$D_ELAPSED"
    pass "daemon uptime captured"
}
[ -S "/Library/Application Support/battopt/battopt.sock" ] && pass "socket exists" || fail "socket missing"

# 4. SMC
section "4. SMC"
STATUS=$(sudo -n "$BAT" status 2>&1)
echo "$STATUS" | grep -q "Charge upper limit" && pass "SMC responds with limits" || fail "SMC no limits"
echo "$STATUS" | grep -q "Capacity" && pass "SMC reports capacity" || fail "SMC no capacity"
echo "$STATUS" | grep -q "Health" && pass "SMC reports health" || warn "SMC no health"
TRIAL_DAYS=$(echo "$STATUS" | grep -oE '[0-9]+ days' | grep -oE '[0-9]+' | head -1)
[ -n "$TRIAL_DAYS" ] && {
    echo "       Trial: $TRIAL_DAYS days remaining"
    if [ "$TRIAL_DAYS" -ge 20 ]; then pass "trial fresh ($TRIAL_DAYS days)"
    elif [ "$TRIAL_DAYS" -ge 5 ]; then warn "trial $TRIAL_DAYS days"
    else fail "trial $TRIAL_DAYS days (needs renewal)"
    fi
}

# 5. TRIAL FILE
section "5. TRIAL FILE"
SYS_INFO="/Library/Application Support/battopt/.sys_info"
if sudo -n test -f "$SYS_INFO"; then
    pass ".sys_info exists"
    MTIME=$(sudo -n stat -f %Sm -t "%Y-%m-%d %H:%M:%S" "$SYS_INFO")
    echo "       mtime: $MTIME"
    AGE_SEC=$(( $(date +%s) - $(sudo -n stat -f %m "$SYS_INFO") ))
    AGE_HR=$((AGE_SEC / 3600))
    if [ "$AGE_HR" -lt 1 ]; then pass "recently renewed (<1h)"
    elif [ "$AGE_HR" -lt 24 ]; then pass "renewed <24h ago"
    else warn "last renewed $AGE_HR hours ago"
    fi
else
    fail ".sys_info missing (daemon may be down)"
fi

# 6. PROCESSES
section "6. PROCESSES"
[ "$(pgrep -x SwiftBar | wc -l | tr -d ' ')" = "1" ] && pass "SwiftBar: 1 instance" || warn "SwiftBar not exactly 1"
[ "$(pgrep -f 'battopt-swiftbar/powerwatch' | wc -l | tr -d ' ')" -ge 1 ] && pass "powerwatch running" || fail "powerwatch down"
[ "$(pgrep -f 'sd_watcher' | wc -l | tr -d ' ')" = "0" ] && pass "no stray sd_watcher" || warn "sd_watcher running"

# 7. STATE
section "7. STATE FILES"
for f in .active_mode config; do
    [ -f "$DASH/$f" ] && pass "$f present" || fail "$f missing"
done
MODE=$(cat "$DASH/.active_mode" 2>/dev/null | tr -d '[:space:]')
case "$MODE" in
    idle|discharge|charge_full|hold|calibration) pass "mode=$MODE valid" ;;
    *) fail "mode=$MODE invalid" ;;
esac
[ -f "$DASH/.active_token" ] && {
    if [ "$MODE" = "idle" ]; then warn "stale token (mode=idle)"
    else pass "token matches session"
    fi
} || pass "no stale token"
[ -f "$DASH/.sd_session" ] && {
    if [ "$MODE" = "discharge" ]; then pass "sd_session matches discharge"
    else warn "sd_session but mode=$MODE"
    fi
} || pass "no sd_session"

# 8. CONFIG
section "8. CONFIG VALUES"
source "$DASH/config" 2>/dev/null
[ -n "$LAST_UPPER" ] && [ "$LAST_UPPER" -ge 50 ] && [ "$LAST_UPPER" -le 100 ] && pass "LAST_UPPER=$LAST_UPPER" || fail "LAST_UPPER invalid"
[ -n "$LAST_LOWER" ] && [ "$LAST_LOWER" -ge 20 ] && [ "$LAST_LOWER" -lt "$LAST_UPPER" ] && pass "LAST_LOWER=$LAST_LOWER" || fail "LAST_LOWER invalid"
[ "$SAILING" = "true" ] || [ "$SAILING" = "false" ] && pass "SAILING=$SAILING" || warn "SAILING=$SAILING"
[ -n "$SAIL_GAP" ] && pass "SAIL_GAP=$SAIL_GAP" || warn "SAIL_GAP missing"

# 9. SMC <-> CONFIG
section "9. SMC ↔ CONFIG"
SMC_UP=$(echo "$STATUS" | grep -oE 'upper limit [0-9]+' | grep -oE '[0-9]+' | head -1)
[ "$SMC_UP" = "$LAST_UPPER" ] && pass "SMC=$SMC_UP == config=$LAST_UPPER" || fail "SMC=$SMC_UP != config=$LAST_UPPER"

# 10. PMSET
section "10. PMSET POLICY"
HIB=$(pmset -g | grep hibernatemode | awk '{print $2}')
[ "$HIB" = "25" ] && pass "hibernatemode=25" || warn "hibernatemode=$HIB"
PN=$(pmset -g | grep powernap | awk '{print $2}')
[ "$PN" = "0" ] && pass "powernap=0" || warn "powernap=$PN"
WOMP=$(pmset -g | grep womp | awk '{print $2}')
[ "$WOMP" = "0" ] && pass "womp=0" || warn "womp=$WOMP"
PS=$(cat "$DASH/.power_saver" 2>/dev/null)
[ "$PS" = "ENABLED" ] && pass "Power Saver enabled" || warn "Power Saver disabled"
B_BAT=$(pmset -g custom 2>/dev/null | awk '/Battery Power:/{f=1;next} /AC Power:/{f=0} f && /standbydelaylow/{print $2;exit}')
B_AC=$(pmset -g custom 2>/dev/null | awk '/AC Power:/{f=1} f && /standbydelaylow/{print $2;exit}')
[ -n "$B_BAT" ] && [ "$B_BAT" -ge 1800 ] && pass "Battery standby=$B_BAT" || warn "Battery standby=$B_BAT"
[ -n "$B_AC" ] && [ "$B_AC" -ge 1800 ] && pass "AC standby=$B_AC" || warn "AC standby=$B_AC"
[ "$B_BAT" != "$B_AC" ] && pass "source-aware (Battery ≠ AC)" || warn "same values both sources"

# 11. LAUNCHAGENTS
section "11. LAUNCHAGENTS"
LOADED=$(launchctl list | grep -c com.battopt)
[ "$LOADED" -ge 15 ] && pass "$LOADED loaded" || warn "$LOADED loaded (<15)"
for ag in acwatcher guardian enforce sleepmonitor sleepmanager swiftbar-watchdog pmsetcheck; do
    launchctl list | grep -q "com.battopt.$ag" && pass "$ag" || warn "$ag not loaded"
done

# 12. NOTIFICATIONS
section "12. NOTIFICATIONS"
TODAY=$(date +%Y%m%d)
NF="$DASH/.notify/.daily_$TODAY"
if [ -f "$NF" ]; then
    NC=$(wc -l < "$NF" | tr -d ' ')
    [ "$NC" -le 3 ] && pass "$NC notifications (≤3)" || warn "$NC notifications (>3)"
else
    pass "0 notifications today"
fi
[ -d "$DASH/.notify" ] && pass ".notify dir exists" || warn ".notify missing"

# 13. DISPATCH CASES
section "13. DISPATCH CASES"
for c in limit_custom sail_on sail_off sail_gap_set stop_now remove_limit_hold \
         disable_limit charge_full smart_discharge calibrate cal_stop; do
    grep -qE "^    ${c}\)" "$DISPATCH" && pass "$c" || fail "$c missing"
done

# 14. INTENT KINDS
section "14. INTENT APPLY"
grep -q "^intent_apply()" "$DISPATCH" && pass "intent_apply exists" || fail "intent_apply missing"
for k in "limit)" "hold_current)" "sail_on|sail_off|sail_gap)" "disable_limit)" "charge_full)" "smart_discharge)" "calibration_start)" "calibration_stop)"; do
    grep -q "        ${k}" "$DISPATCH" && pass "kind: $k" || fail "kind missing: $k"
done
grep -q "guard_token_write_locked" "$DASH/state_guard.sh" && pass "guard_token_write_locked" || fail "token write helper missing"
grep -q "guard_token_clear_locked" "$DASH/state_guard.sh" && pass "guard_token_clear_locked" || fail "token clear helper missing"

# 15. INTENT — dead code
section "15. DEAD CODE"
for fn in apply_intent hold_at_current sd_session_new sd_session_current; do
    if grep -qE "^${fn}\(\)" "$DISPATCH"; then
        warn "$fn still defined (dead?)"
    else
        pass "$fn removed"
    fi
done

# 16. PLUGIN CONTENT
section "16. PLUGIN OUTPUT"
POUT=$(bash "$PLUGIN" 2>/dev/null)
echo "$POUT" | grep -q "Charge:" && pass "Charge line" || fail "Charge missing"
echo "$POUT" | grep -q "Mode:" && pass "Mode line" || fail "Mode missing"
echo "$POUT" | grep -q "Health:" && pass "Health line" || warn "Health missing"
echo "$POUT" | grep -qE "🔋|⚡|🔌|🔴" && pass "battery icon" || fail "icon missing"
SEP=$(echo "$POUT" | grep -c "──────────────────────────")
[ "$SEP" -ge 5 ] && pass "$SEP styled separators" || warn "only $SEP separators"
echo "$POUT" | grep -q "Renew Trial Now" && pass "Renew Trial" || fail "Renew Trial missing"
echo "$POUT" | grep -q "Prepare for Sleep" && pass "Prepare for Sleep" || warn "Prepare missing"
echo "$POUT" | grep -q "Quick Actions" && pass "Quick Actions" || fail "Quick Actions missing"
echo "$POUT" | grep -q "Hold Mode" && pass "Hold Mode" || fail "Hold Mode missing"

# 17. PLUGIN STYLE — no inline emoji in leaf items
section "17. PLUGIN STYLE"
BAD=$(echo "$POUT" | grep -E "^--.*(🔄|⚡|🧹|📄|💾|📂|🔀|🔮|🔍|🩺|▶️|⏸️)" | grep -v "✅\|⚠️\|ℹ️" | wc -l | tr -d ' ')
[ "$BAD" = "0" ] && pass "no non-essential emoji in leaf items" || warn "$BAD leaf items with emoji"

# 18. RENEW TRIAL SCRIPT
section "18. RENEW TRIAL SCRIPT"
TR=/usr/local/bin/battopt-trial-renew
[ -x "$TR" ] && pass "trial-renew executable" || fail "not executable"
grep -q "sudo -n" "$TR" && pass "uses sudo -n" || warn "no sudo -n"
grep -q "launchctl load -w" "$TR" && pass "uses load -w" || warn "no load -w"
grep -q "pgrep -f \"battopt daemon\"" "$TR" && pass "verifies daemon" || warn "no daemon check"

# 19. HEALTH CHECK
section "19. HEALTH"
HH=$(bash "$DASH/project_health.sh" 2>&1)
HF=$(echo "$HH" | grep -c "FAIL:")
[ "$HF" = "0" ] && pass "health: 0 FAIL" || warn "health: $HF FAIL"

# 20. LOG SANITY
section "20. LOG SANITY"
LOGSIZE=$(wc -l < "$DASH/actions.log" 2>/dev/null | tr -d ' ')
[ "$LOGSIZE" -lt 100000 ] && pass "actions.log $LOGSIZE lines" || warn "actions.log $LOGSIZE lines (large)"
ERR_COUNT=$(tail -100 "$DASH/actions.log" 2>/dev/null | grep -icE "error|fail|timeout" || echo 0)
[ "$ERR_COUNT" -lt 5 ] && pass "recent errors: $ERR_COUNT" || warn "recent errors: $ERR_COUNT"

section "SUMMARY"
TOTAL=$((PASS + FAIL + WARN))
echo ""
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  WARN: $WARN"
echo "  TOTAL: $TOTAL"
echo ""
[ "$FAIL" -eq 0 ] && echo "  ✅ ALL PASS" || echo "  ⚠️  $FAIL failures"
echo ""
echo "  Report: $REPORT"
} 2>&1 | tee "$REPORT"
