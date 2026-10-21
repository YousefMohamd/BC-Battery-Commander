#!/bin/bash
# BattOpt Project Health Check
# Verifies all components are functioning

REPORT="/tmp/battopt_health_latest.txt"
PASS=0
FAIL=0
WARN=0

check() {
    local name="$1" result="$2" expected="$3"
    if [ "$result" = "$expected" ]; then
        echo "✅ PASS: $name" | tee -a "$REPORT"
        PASS=$((PASS+1))
    else
        echo "❌ FAIL: $name (got: $result, expected: $expected)" | tee -a "$REPORT"
        FAIL=$((FAIL+1))
    fi
}

warn() {
    echo "⚠️ WARN: $1" >> "$REPORT"
    echo "⚠️ WARN: $1"
    WARN=$((WARN+1))
}

{
echo "═══════════════════════════════════════════════════"
echo "  BattOpt Health Check — $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════"
echo ""
} | tee "$REPORT"

# ─── CORE FILES ───
echo "─── CORE FILES ───" | tee -a "$REPORT"

check "SwiftBar.app exists" \
    "$([ -d /Applications/SwiftBar.app ] && echo yes || echo no)" "yes"

check "terminal-notifier.app exists" \
    "$([ -d /Applications/terminal-notifier.app ] && echo yes || echo no)" "yes"

check "BattOpt.app exists" \
    "$([ -d /Applications/BattOpt.app ] && echo yes || echo no)" "yes"

check "Plugin exists" \
    "$([ -f ~/SwiftBar/battopt.10s.sh ] && echo yes || echo no)" "yes"

check "Dispatcher exists" \
    "$([ -f ~/.battopt-swiftbar/dispatch.sh ] && echo yes || echo no)" "yes"

check "PowerWatch exists" \
    "$([ -f ~/.battopt-swiftbar/powerwatch ] && echo yes || echo no)" "yes"

echo "" | tee -a "$REPORT"

# ─── PROCESSES ───
echo "─── RUNNING PROCESSES ───" | tee -a "$REPORT"

# SwiftBar detection — multiple methods with retry
SB_COUNT=0
for attempt in 1 2 3 4 5; do
    if /usr/bin/pgrep -x SwiftBar >/dev/null 2>&1; then
        SB_COUNT=$(/usr/bin/pgrep -x SwiftBar 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
        break
    fi
    if /usr/bin/pgrep -f "SwiftBar.app/Contents/MacOS/SwiftBar" >/dev/null 2>&1; then
        SB_COUNT=$(/usr/bin/pgrep -f "SwiftBar.app/Contents/MacOS/SwiftBar" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
        break
    fi
    # Last resort: ps
    PS_COUNT=$(ps aux 2>/dev/null | grep -c "[S]wiftBar.app/Contents/MacOS/SwiftBar")
    if [ "$PS_COUNT" -gt 0 ]; then
        SB_COUNT="$PS_COUNT"
        break
    fi
    sleep 1
done
[ -z "$SB_COUNT" ] && SB_COUNT=0

check "SwiftBar running" \
    "$([ "$SB_COUNT" -gt 0 ] && echo yes || echo no)" "yes"

check "SwiftBar single instance" \
    "$SB_COUNT" "1"

check "battopt daemon running" \
    "$(pgrep -f 'battopt daemon' >/dev/null && echo yes || echo no)" "yes"

check "PowerWatch running" \
    "$(pgrep -f 'battopt-swiftbar/powerwatch' >/dev/null && echo yes || echo no)" "yes"

echo "" | tee -a "$REPORT"

# ─── LAUNCHAGENTS ───
echo "─── LAUNCHAGENTS ───" | tee -a "$REPORT"

LA=$(launchctl list | grep -c battopt)
check "LaunchAgents loaded (>0)" \
    "$([ "$LA" -gt 0 ] && echo yes || echo no)" "yes"

# Check powerwatch daemon — multi-method
PW_LOADED=no
if launchctl print system/com.battopt.powerwatch 2>/dev/null | grep -q "state = running"; then
    PW_LOADED=yes
elif sudo -n launchctl list 2>/dev/null | grep -q "com.battopt.powerwatch"; then
    PW_LOADED=yes
elif pgrep -f "battopt-swiftbar/powerwatch" >/dev/null 2>&1; then
    PW_LOADED=yes
fi

if [ "$PW_LOADED" = "yes" ]; then
    echo "   powerwatch (daemon): loaded" >> "$REPORT"
    echo "   powerwatch (daemon): loaded"
else
    warn "powerwatch NOT loaded"
fi

# Check LaunchAgents
for svc in consolidated pmsetcheck swiftbar-watchdog process-monitor predictive self-healing adaptive-governor guardian; do
    if launchctl list | grep -q "battopt.$svc"; then
        echo "   $svc (agent): loaded" | tee -a "$REPORT"
    else
        warn "$svc NOT loaded"
    fi
done

echo "" | tee -a "$REPORT"

# ─── PMSET SETTINGS ───
echo "─── PMSET SETTINGS ───" | tee -a "$REPORT"

# Hibernatemode — Battery MUST be 25, AC can be 0 or 25
HIB_BAT=$(pmset -g custom 2>/dev/null | awk '/^Battery Power:/{f=1} f && /hibernatemode/{print $2; exit}')
HIB_AC=$(pmset -g custom 2>/dev/null | awk '/^AC Power:/{f=1} f && /hibernatemode/{print $2; exit}')
[ -z "$HIB_BAT" ] && HIB_BAT=$(pmset -g | grep hibernatemode | awk '{print $2}')
[ -z "$HIB_AC" ] && HIB_AC="$HIB_BAT"

if [ "$HIB_BAT" = "25" ] && { [ "$HIB_AC" = "0" ] || [ "$HIB_AC" = "25" ]; }; then
    check "hibernatemode (Bat=$HIB_BAT, AC=$HIB_AC)" "yes" "yes"
else
    check "hibernatemode (Bat=$HIB_BAT, AC=$HIB_AC)" "no" "yes"
fi

STANDBY=$(pmset -g | grep '^ standbydelayhigh' | awk '{print $2}')
# standbydelay — read from Battery Power section explicitly
STANDBY_BAT=$(pmset -g custom 2>/dev/null | awk '
    /^Battery Power:/ {f=1; next}
    /^AC Power:/ {f=0}
    f && /^ *standbydelaylow / {print $2; exit}
')
[ -z "$STANDBY_BAT" ] && STANDBY_BAT=0

# Expected: 900 in Normal/Presentation/Download, 14400 in Travel
SM_STATE=$(cat "$HOME/.battopt-swiftbar/.sleep_mode" 2>/dev/null || echo "default")
# Layer 13 aware: standbydelay changes with .sleep_profile
LAYER13_PROFILE=""
[ -f "$HOME/.battopt-swiftbar/.sleep_profile" ] && LAYER13_PROFILE=$(cat "$HOME/.battopt-swiftbar/.sleep_profile")

if [ "$SM_STATE" = "travel" ]; then
    # Travel mode: user override
    check "standbydelay (Bat=$STANDBY_BAT, Travel)" "$STANDBY_BAT" "14400"
elif [ "$LAYER13_PROFILE" = "long_battery" ]; then
    # Layer 13 long battery profile
    check "standbydelay (Bat=$STANDBY_BAT, long_battery)" "$STANDBY_BAT" "3600"
elif [ "$LAYER13_PROFILE" = "active_battery" ]; then
    # Layer 13 active battery profile
    check "standbydelay (Bat=$STANDBY_BAT, active_battery)" "$STANDBY_BAT" "300"
else
    # Default mode (AC or unknown)
    if [ "$STANDBY_BAT" = "900" ] || [ "$STANDBY_BAT" = "300" ] || [ "$STANDBY_BAT" = "3600" ]; then
        check "standbydelay (Bat=$STANDBY_BAT, profile=$LAYER13_PROFILE)"
    else
        fail "standbydelay (Bat=$STANDBY_BAT, profile=$LAYER13_PROFILE) — expected 900/300/3600"
    fi
fi

POWERNAP=$(pmset -g | grep powernap | awk '{print $2}')
[ -z "$POWERNAP" ] && POWERNAP="0"
check "powernap = 0 (or absent)" "$POWERNAP" "0"

# womp — from custom (better) or default to 0 if absent
WOMP=$(pmset -g custom 2>/dev/null | grep '^ *womp' | awk '{print $2}' | head -1)
[ -z "$WOMP" ] && WOMP=$(pmset -g 2>/dev/null | grep '^ *womp' | awk '{print $2}' | head -1)
[ -z "$WOMP" ] && WOMP="0"
check "womp = 0" "$WOMP" "0"

echo "" | tee -a "$REPORT"

# ─── SUDOERS ───
echo "─── SUDOERS ───" | tee -a "$REPORT"

check "battopt NOPASSWD" \
    "$(sudo -n /usr/local/bin/battopt status >/dev/null 2>&1 && echo yes || echo no)" "yes"

check "pmset NOPASSWD" \
    "$(sudo -n /usr/bin/pmset -g >/dev/null 2>&1 && echo yes || echo no)" "yes"

echo "" | tee -a "$REPORT"

# ─── SYSTEM STATE ───
echo "─── SYSTEM STATE ───" | tee -a "$REPORT"

LOAD=$(sysctl -n vm.loadavg | awk '{print $2}')
if (( $(echo "$LOAD < 3.0" | bc -l) )); then
    check "Load < 3.0" "yes" "yes"
else
    warn "Load = $LOAD (high)"
fi

SWAP=$(sysctl vm.swapusage | awk '{print $7}' | tr -d 'M')
if [ "${SWAP%.*}" -lt 2000 ]; then
    check "Swap < 2000 MB" "yes" "yes"
else
    warn "Swap = ${SWAP} MB (high)"
fi

TEMP_RAW=$(sudo -n battopt status 2>/dev/null | grep -oE "[0-9.]+" | head -1)
# Better: extract the temperature from "36.8°C" pattern
TEMP=$(sudo -n battopt status 2>/dev/null | grep -oE "[0-9]+\.[0-9]+°C" | head -1 | sed 's/°C//')
[ -z "$TEMP" ] && TEMP=$(sudo -n battopt status 2>/dev/null | grep -oE "[0-9.]+" | tail -3 | head -1)

if [ -z "$TEMP" ]; then
    warn "Temp: could not read (battopt may be restarting)"
elif [ "${TEMP%.*}" -lt 40 ] 2>/dev/null; then
    check "Temp < 40°C" "yes" "yes"
elif [ "${TEMP%.*}" -lt 45 ] 2>/dev/null; then
    warn "Temp = ${TEMP}°C (warm)"
else
    warn "Temp = ${TEMP}°C (hot)"
fi

echo "" | tee -a "$REPORT"

# ─── SUMMARY ───
{
echo "═══════════════════════════════════════════════════"
echo "  SUMMARY"
echo "  PASS: $PASS | FAIL: $FAIL | WARN: $WARN"
echo "═══════════════════════════════════════════════════"
} | tee -a "$REPORT"

if [ "$FAIL" -eq 0 ]; then
    echo "✅ Project is HEALTHY" | tee -a "$REPORT"
else
    echo "❌ Project has $FAIL failures — see report" | tee -a "$REPORT"
fi

echo ""
echo "Report: $REPORT"
