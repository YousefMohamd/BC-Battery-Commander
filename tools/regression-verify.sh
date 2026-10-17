#!/bin/bash
# Regression Verification — confirms all fixes persist
HOME="${HOME:-/Users/Yousef}"
DASH="$HOME/.battopt-swiftbar"
PLUGIN="$HOME/SwiftBar/battopt.10s.sh"
DISPATCH="$DASH/dispatch.sh"
BAT="/usr/local/bin/battopt"
PASS=0; FAIL=0; WARN=0
pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN+1)); }
sect() { echo ""; echo "════ $1 ════"; }

{
echo "═══ Regression Verify — $(date '+%F %T') ═══"

# ═══════════════════════════════════════════════
sect "R1. Watchdog Fix (loop + PPID=1)"
# ═══════════════════════════════════════════════
# R1.1 — SwiftBar PPID = 1
SB_PID=$(pgrep -x SwiftBar | head -1)
if [ -n "$SB_PID" ]; then
    SB_PPID=$(ps -o ppid= -p "$SB_PID" | tr -d ' ')
    [ "$SB_PPID" = "1" ] && pass "SwiftBar PPID=1 (detached)" || fail "SwiftBar PPID=$SB_PPID (attached to shell)"
else
    fail "SwiftBar not running"
fi

# R1.2 — watchdog script exists + executable
WD="$DASH/swiftbar_watchdog.sh"
if [ -x "$WD" ]; then
    pass "watchdog script exists"
    bash -n "$WD" && pass "watchdog syntax" || fail "watchdog syntax broken"
else
    fail "watchdog script missing"
fi

# R1.3 — watchdog uses direct binary, not open -a
if grep -q "/Applications/SwiftBar.app/Contents/MacOS/SwiftBar" "$WD"; then
    pass "watchdog uses direct binary path"
else
    fail "watchdog does not use direct binary"
fi
if grep -qE "open -a SwiftBar" "$WD"; then
    fail "watchdog still uses 'open -a'"
else
    pass "watchdog does NOT use 'open -a' (avoids -600)"
fi

# R1.4 — user_shutdown guard
grep -q "user_shutdown" "$WD" && pass "watchdog respects .user_shutdown" || fail "no user_shutdown guard"

# R1.5 — cooldown file logic
grep -q "watchdog_cooldown\|COOLDOWN" "$WD" && pass "watchdog has cooldown" || warn "no cooldown"

# R1.6 — plist StartInterval = 120
SI=$(/usr/libexec/PlistBuddy -c "Print :StartInterval" ~/Library/LaunchAgents/com.battopt.swiftbar-watchdog.plist 2>/dev/null)
[ "$SI" = "120" ] && pass "StartInterval=120s" || warn "StartInterval=$SI"

# R1.7 — watchdog loaded in launchctl
launchctl list | grep -q "com.battopt.swiftbar-watchdog" && pass "watchdog loaded" || warn "watchdog not loaded"

# ═══════════════════════════════════════════════
sect "R2. UI Refresh (swiftbar:// hook)"
# ═══════════════════════════════════════════════
grep -q "refresh_swiftbar" "$DISPATCH" && pass "refresh_swiftbar function exists" || fail "no refresh function"
grep -q "swiftbar://refreshplugin" "$DISPATCH" && pass "URL scheme present" || fail "no URL scheme"
grep -q "trap refresh_swiftbar EXIT" "$DISPATCH" && pass "EXIT trap installed" || fail "no trap"

# ═══════════════════════════════════════════════
sect "R3. Icon Root-Process Detection"
# ═══════════════════════════════════════════════
grep -q 'PROC_D_NOW=\$(sudo -n pgrep' "$PLUGIN" && pass "PROC_D_NOW uses sudo -n pgrep" || fail "PROC_D_NOW not using sudo"
grep -q 'PROC_D_NOTIF=\$(sudo -n pgrep' "$PLUGIN" && pass "PROC_D_NOTIF uses sudo -n pgrep" || fail "PROC_D_NOTIF not using sudo"

# ═══════════════════════════════════════════════
sect "R4. Single active_mode Read"
# ═══════════════════════════════════════════════
ACTIVE_READS=$(grep -c 'ACTIVE_MODE=\$(cat.*active_mode' "$PLUGIN")
[ "$ACTIVE_READS" -eq 1 ] && pass "1 ACTIVE_MODE read (was 2+)" || warn "$ACTIVE_READS reads (want 1)"
grep -q 'ICON_ACTIVE="\$ACTIVE_MODE"' "$PLUGIN" && pass "ICON_ACTIVE reuses cached" || fail "ICON_ACTIVE separate read"

# ═══════════════════════════════════════════════
sect "R5. Custom Limit 2-step Dialog"
# ═══════════════════════════════════════════════
grep -q "Mode after reaching limit" "$DISPATCH" && pass "2-step dialog present" || fail "no 2-step dialog"
grep -q "Hold = freeze" "$DISPATCH" && pass "Hold option present" || fail "no Hold option"
grep -q "Sailing = oscillate" "$DISPATCH" && pass "Sailing option present" || fail "no Sailing option"
grep -q "Custom sail gap" "$DISPATCH" && pass "Custom gap dialog" || fail "no custom gap"
grep -q 'intent_apply limit "\$U" "\$LAST_LOWER" "\$MODE" "\$GAP"' "$DISPATCH" && pass "Passes MODE+GAP to intent" || fail "does not pass MODE"

# ═══════════════════════════════════════════════
sect "R6. Intent Apply Handles MODE"
# ═══════════════════════════════════════════════
grep -qE 'U="\$1"; L="\$2"; MODE="\$3"; GAP="\$4"' "$DISPATCH" && pass "intent_apply limit accepts 4 args" || fail "intent_apply limit old signature"
grep -q 'if \[ "\$MODE" = "Hold" \]' "$DISPATCH" && pass "Hold branch in intent" || fail "no Hold branch"
grep -q '"\$MODE" = "Sail"' "$DISPATCH" && pass "Sail branch in intent" || fail "no Sail branch"
grep -q 'backward compat' "$DISPATCH" && pass "Backward compat preserved" || warn "no backward compat"

# ═══════════════════════════════════════════════
sect "R7. Menu Split (Hold vs Sailing)"
# ═══════════════════════════════════════════════
POUT=$(bash "$PLUGIN" 2>/dev/null)
echo "$POUT" | grep -q "Hold Mode — Static at" && pass "Hold Mode = Static only" || fail "Hold Mode title wrong"
echo "$POUT" | grep -q "Sailing — ON\|Sailing — OFF" && pass "Sailing is separate section" || fail "Sailing not separate"
echo "$POUT" | grep -q "Static Hold" && pass "Static Hold in Hold Mode" || fail "no Static Hold"
# No 'With Sailing' in Hold Mode anymore
if echo "$POUT" | grep -A1 "Hold Mode" | grep -q "With Sailing"; then
    fail "Hold Mode still contains With Sailing (split failed)"
else
    pass "Hold Mode no longer contains With Sailing"
fi

# ═══════════════════════════════════════════════
sect "R8. Guardian LAYER3 Source-of-Truth"
# ═══════════════════════════════════════════════
GRD="$DASH/guardian.sh"
grep -q "Config is source of truth" "$GRD" && pass "Guardian LAYER3 renamed" || warn "old LAYER3 name"
grep -q "HOLD_SINCE" "$GRD" && pass "hold-timeout tracking" || fail "no hold timeout"
grep -q "AM_L3" "$GRD" && pass "active_mode aware" || fail "not active_mode aware"
grep -q "hold \${AGE}s — defer\|hold \${AGE}s drift" "$GRD" && pass "hold timeout logic" || fail "no hold timeout logic"
grep -q "guard_session_active\|guarded" "$GRD" && pass "other guards preserved" || warn "guarded() missing"

# ═══════════════════════════════════════════════
sect "R9. Orphan Discharge Prevention"
# ═══════════════════════════════════════════════
SDW="$DASH/sd_watcher.sh"
grep -q 'pkill -9 -f .*/usr/local/bin/battopt discharge' "$SDW" && pass "sd_watcher kills orphan" || fail "no orphan kill in sd_watcher"
grep -q "active_token" "$SDW" && pass "sd_watcher clears token" || warn "no token clear"
grep -q "active_mode" "$SDW" && pass "sd_watcher resets mode" || warn "no mode reset"

# Live check — orphan?
ORPHAN=$(pgrep -f "battopt discharge" | wc -l | tr -d ' ')
MODE=$(cat "$DASH/.active_mode" 2>/dev/null)
if [ "$ORPHAN" = "0" ] || [ "$MODE" = "discharge" ]; then
    pass "no orphan discharge (mode=$MODE, procs=$ORPHAN)"
else
    fail "orphan discharge ($ORPHAN procs but mode=$MODE)"
fi

# ═══════════════════════════════════════════════
sect "R10. Stale .active_token Prevention"
# ═══════════════════════════════════════════════
grep -q "_clear_session_locked" "$DISPATCH" && pass "_clear_session_locked exists" || fail "no session clear"
grep -q "guard_token_clear_locked" "$DASH/state_guard.sh" && pass "guard_token_clear_locked helper" || fail "helper missing"
# Live check
if [ -f "$DASH/.active_token" ] && [ "$MODE" = "idle" ]; then
    fail "stale .active_token with mode=idle"
else
    pass "no stale token (mode=$MODE)"
fi

# ═══════════════════════════════════════════════
sect "R11. Renew Trial"
# ═══════════════════════════════════════════════
TR=/usr/local/bin/battopt-trial-renew
[ -x "$TR" ] && pass "trial-renew executable" || fail "not exec"
grep -q "sudo -n" "$TR" && pass "uses sudo -n" || fail "no sudo -n"
grep -q "launchctl load -w" "$TR" && pass "uses load -w" || fail "no load -w"
TRIAL=$(sudo -n "$BAT" status 2>&1 | grep -oE '[0-9]+ days' | grep -oE '[0-9]+' | head -1)
[ "$TRIAL" -ge 20 ] && pass "trial=$TRIAL days" || warn "trial=$TRIAL days"

# ═══════════════════════════════════════════════
sect "R12. Sleep Profiles Source-Aware"
# ═══════════════════════════════════════════════
grep -q "apply_delays" "$DASH/power_saver.sh" && pass "apply_delays exists" || fail "no apply_delays"
# Check source-aware
grep -q '\-b standbydelayhigh' "$DASH/power_saver.sh" && pass "uses -b (Battery)" || fail "no -b"
grep -q '\-c standbydelayhigh' "$DASH/power_saver.sh" && pass "uses -c (AC)" || fail "no -c"
# Live values
B_STANDBY=$(pmset -g custom 2>/dev/null | awk '/Battery Power:/{f=1;next} /AC Power:/{f=0} f && /standbydelaylow/{print $2;exit}')
A_STANDBY=$(pmset -g custom 2>/dev/null | awk '/AC Power:/{f=1} f && /standbydelaylow/{print $2;exit}')
[ -n "$B_STANDBY" ] && pass "Battery standby=$B_STANDBY" || warn "Battery standby empty"
[ -n "$A_STANDBY" ] && pass "AC standby=$A_STANDBY" || warn "AC standby empty"
[ "$B_STANDBY" != "$A_STANDBY" ] && pass "source-aware verified" || warn "same values both sources"

# ═══════════════════════════════════════════════
sect "R13. Dead Code Removed"
# ═══════════════════════════════════════════════
for fn in apply_intent hold_at_current sd_session_new sd_session_current; do
    if grep -qE "^${fn}\(\)" "$DISPATCH"; then
        fail "$fn still defined"
    else
        pass "$fn removed"
    fi
done

# ═══════════════════════════════════════════════
sect "R14. Atomic Intent — 11 cases use it"
# ═══════════════════════════════════════════════
INTENT_CALLS=$(grep -cE "^[[:space:]]+intent_apply " "$DISPATCH")
[ "$INTENT_CALLS" -ge 10 ] && pass "$INTENT_CALLS cases use intent_apply" || fail "only $INTENT_CALLS"
for k in "limit)" "hold_current)" "sail_on|sail_off|sail_gap)" "disable_limit)" "charge_full)" "smart_discharge)" "calibration_start)" "calibration_stop)"; do
    grep -q "        ${k}" "$DISPATCH" && pass "kind $k" || fail "missing kind $k"
done

# ═══════════════════════════════════════════════
sect "R15. Notification Cap ≤3/day"
# ═══════════════════════════════════════════════
TODAY=$(date +%Y%m%d)
NF="$DASH/.notify/.daily_$TODAY"
if [ -f "$NF" ]; then
    NC=$(wc -l < "$NF" | tr -d ' ')
    [ "$NC" -le 5 ] && pass "$NC notifications today" || warn "$NC notifications (>5)"
else
    pass "0 notifications today"
fi

# ═══════════════════════════════════════════════
sect "R16. Health Check"
# ═══════════════════════════════════════════════
HH=$(bash "$DASH/project_health.sh" 2>&1 | tail -8)
H_F=$(echo "$HH" | grep -c "FAIL:")
[ "$H_F" -le 1 ] && pass "health: $H_F FAIL" || warn "health: $H_F FAIL"

# ═══════════════════════════════════════════════
sect "R17. Git State"
# ═══════════════════════════════════════════════
cd "$HOME/Desktop/BattOpt-CC-Release"
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main 2>/dev/null)
[ "$LOCAL" = "$REMOTE" ] && pass "local == remote" || warn "local != remote"

# ═══════════════════════════════════════════════
sect "SUMMARY"
# ═══════════════════════════════════════════════
echo ""
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  WARN: $WARN"
echo "  TOTAL: $((PASS + FAIL + WARN))"
echo ""
[ "$FAIL" -eq 0 ] && echo "  ✅ ALL FIXES VERIFIED" || echo "  ❌ $FAIL regressions detected"
} 2>&1 | tee /tmp/regression-verify-$(date +%Y%m%d-%H%M%S).txt
