#!/bin/bash
# Battery Commander Project Health Check
# Verifies all components are functioning

# BC state dir: ~/.battery-commander/ is the ONLY live state dir
# (consolidation 2026-11-13, M2: the old-dir fallback is retired — the
# pre-migration dir is a kept, inert backup and must never be read or
# written as a live target). BC_DASH overrides (tests / dry-runs).
if [ -n "${BC_DASH:-}" ]; then
    DASH="$BC_DASH"
elif [ -d "$HOME/.battery-commander" ]; then
    DASH="$HOME/.battery-commander"
else
    echo "ERROR: Battery Commander state dir missing - ~/.battery-commander not found; refusing to run (old-dir fallback retired)" >&2
    exit 1
fi
BC_BUILD_DIR="${BC_BUILD_DIR:-$HOME/Projects/BattOpt-CC-Release/battopt-project/bc-build}"
REPORT="/tmp/battery-commander_health_latest.txt"
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

# fail() was called but never defined (pre-existing W6.4 bug) —
# without it the script died on the first FAIL.
fail() {
    echo "❌ FAIL: $1" >> "$REPORT"
    echo "❌ FAIL: $1"
    FAIL=$((FAIL+1))
}

{
echo "═══════════════════════════════════════════════════"
echo "  Battery Commander Health Check — $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════"
echo ""
} | tee "$REPORT"

# ─── CORE FILES ───
echo "─── CORE FILES ───" | tee -a "$REPORT"

check "SwiftBar.app exists" \
    "$([ -d /Applications/SwiftBar.app ] && echo yes || echo no)" "yes"

# Notifications are app-native (final cleanup 2026-11-18, owner
# order): scripts queue to $DASH/.notify_queue and the app posts
# via UNUserNotificationCenter. Healthy = both main producers use
# the queue and neither references the retired external notifier.
NOTIFY_OK=yes
grep -q '.notify_queue' "$DASH/dispatch.sh" 2>/dev/null || NOTIFY_OK=no
grep -q '.notify_queue' "$DASH/bc-watchdog.sh" 2>/dev/null || NOTIFY_OK=no
grep -q 'terminal-notifier' "$DASH/dispatch.sh" 2>/dev/null && NOTIFY_OK=no
grep -q 'terminal-notifier' "$DASH/bc-watchdog.sh" 2>/dev/null && NOTIFY_OK=no
check "App-native notifications (queue transport, no external notifier)" "$NOTIFY_OK" "yes"

# BC app bundle is "BatteryCommander.app" (no space) — the old
# "Battery Commander.app" (with space) never existed; the old
# BattOpt.app fallback is gone (deleted 2026-11-10).
check "Battery Commander.app exists" \
    "$([ -d "/Applications/BatteryCommander.app" ] && echo yes || echo no)" "yes"

check "App executable exists" \
    "$([ -f "/Applications/BatteryCommander.app/Contents/MacOS/BatteryCommander" ] && echo yes || echo no)" "yes"

check "Dispatcher exists" \
    "$([ -f $DASH/dispatch.sh ] && echo yes || echo no)" "yes"

check "PowerWatch exists" \
    "$([ -f $DASH/powerwatch ] && echo yes || echo no)" "yes"

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

# SwiftBar retired (Stage C; owner order 2026-11-17): the native app
# is the only UI and SwiftBar stays closed. Health guards the
# retirement instead of the old running/single-instance checks.
check "SwiftBar retired (not running)" \
    "$([ "$SB_COUNT" -eq 0 ] && echo yes || echo no)" "yes"

# Enforcer daemon: direct query — `launchctl print system/<label>` works
# from a user shell (verified 2026-11-11); `launchctl list` cannot see a
# system daemon. Not a hard FAIL before Phase C — the daemon is
# deliberately not loaded yet.
if launchctl print system/com.batterycommander.bclimit >/dev/null 2>&1; then
    echo "   enforcer daemon: loaded" | tee -a "$REPORT"
else
    warn "enforcer daemon not loaded yet (Phase C gate — expected before deploy)"
fi

check "PowerWatch running" \
    "$(pgrep -f "$DASH/powerwatch" >/dev/null && echo yes || echo no)" "yes"

echo "" | tee -a "$REPORT"

# ─── LAUNCHAGENTS ───
echo "─── LAUNCHAGENTS ───" | tee -a "$REPORT"

LA=$(launchctl list | grep -c batterycommander)
check "LaunchAgents loaded (>0)" \
    "$([ "$LA" -gt 0 ] && echo yes || echo no)" "yes"

# Check powerwatch daemon — multi-method
PW_LOADED=no
if launchctl list com.batterycommander.powerwatch 2>/dev/null | grep -q "PID"; then
    PW_LOADED=yes
elif pgrep -f "$DASH/powerwatch" >/dev/null 2>&1; then
    PW_LOADED=yes
fi

if [ "$PW_LOADED" = "yes" ]; then
    echo "   powerwatch (daemon): loaded" >> "$REPORT"
    echo "   powerwatch (daemon): loaded"
else
    warn "powerwatch NOT loaded"
fi

# Check all BC agents (13 renamed 2026-11-11 + watchdog + powerwatch
# + watchdogsentinel, added 2026-11-14 — the sentinel watches the
# watchdog, and this list is how the health check watches the
# sentinel; it was missing here, so a dead sentinel showed as green).
for svc in watchdog powerwatch acwatcher hygiene log-cleanup morning-report pmsetcheck predictive process-monitor self-healing selfmaintenance sleepmanager sleepmonitor wakeanalyzer watchdogsentinel; do
    if launchctl list | grep -q "batterycommander.$svc"; then
        echo "   $svc (agent): loaded" | tee -a "$REPORT"
    else
        warn "$svc NOT loaded"
    fi
done

echo "" | tee -a "$REPORT"

# ─── PMSET SETTINGS ───
echo "─── PMSET SETTINGS ───" | tee -a "$REPORT"

# ─── PROFILE-AWARE pmset expectations (final cleanup 2026-11-18) ───
# Three independent tool layers write hibernatemode/standbydelay:
#   * power_mode.sh profiles   (marker .current_power_mode)
#   * power_saver.sh on/off + delay profiles (markers .power_saver,
#     .sleep_mode = travel|long for the delay profiles)
#   * sleep_mode actions (pmset posture per mode)
# Each layer's designed values are legitimate, and the layers do
# not re-assert each other — whichever wrote last is live. A live
# value is therefore healthy iff it belongs to the UNION of the
# designed values of every ACTIVE layer. The old static table
# false-FAILed whenever the owner applied Balanced (live proof
# 2026-11-18 20:27: hib 3/3 + standby 900 FAILed minutes after his
# Balanced click, though both are Balanced's own designed values).
_in_set() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

PM_MODE=$(cat "$DASH/.current_power_mode" 2>/dev/null | tr -d '[:space:]')
# power_mode.sh designed values (standbydelay / hibernatemode):
#   fast 300/25 · balanced 900/3 · awake 3600/3 · deep 0/25 ·
#   custom (user standby)/3 · unmarked = balanced (the script's
#   own status default).
PM_STANDBY=""; PM_HIB=""
case "$PM_MODE" in
    fast)     PM_STANDBY=300;  PM_HIB=25 ;;
    balanced) PM_STANDBY=900;  PM_HIB=3 ;;
    awake)    PM_STANDBY=3600; PM_HIB=3 ;;
    deep)     PM_STANDBY=0;    PM_HIB=25 ;;
    custom)   PM_STANDBY="";   PM_HIB=3 ;;
    *)        PM_MODE="balanced"; PM_STANDBY=900; PM_HIB=3 ;;
esac

# Hibernatemode — read both sources explicitly.
HIB_BAT=$(pmset -g custom 2>/dev/null | awk '/^Battery Power:/{f=1} f && /hibernatemode/{print $2; exit}')
HIB_AC=$(pmset -g custom 2>/dev/null | awk '/^AC Power:/{f=1} f && /hibernatemode/{print $2; exit}')
[ -z "$HIB_BAT" ] && HIB_BAT=$(pmset -g | grep hibernatemode | awk '{print $2}')
[ -z "$HIB_AC" ] && HIB_AC="$HIB_BAT"

# Expected set: the active power-mode profile's value, plus 25
# while Power Saver is on (its `on` asserts 25) or 3 while it is
# off (its `off` restores 3).
HIB_EXPECT="$PM_HIB"
if [ -f "$DASH/.power_saver" ]; then
    _in_set "$HIB_EXPECT" 25 || HIB_EXPECT="$HIB_EXPECT 25"
else
    _in_set "$HIB_EXPECT" 3 || HIB_EXPECT="$HIB_EXPECT 3"
fi
if _in_set "$HIB_EXPECT" "$HIB_BAT" && _in_set "$HIB_EXPECT" "$HIB_AC"; then
    check "hibernatemode (Bat=$HIB_BAT, AC=$HIB_AC, power_mode=$PM_MODE, expected one of: $HIB_EXPECT)" "yes" "yes"
else
    check "hibernatemode (Bat=$HIB_BAT, AC=$HIB_AC, power_mode=$PM_MODE, expected one of: $HIB_EXPECT)" "no" "yes"
fi

# standbydelay — read from Battery Power section explicitly
STANDBY_BAT=$(pmset -g custom 2>/dev/null | awk '
    /^Battery Power:/ {f=1; next}
    /^AC Power:/ {f=0}
    f && /^ *standbydelaylow / {print $2; exit}
')
[ -z "$STANDBY_BAT" ] && STANDBY_BAT=0

# Expected set: the sleep-profile value (default 600; travel/long
# set battery standbydelaylow to 3600 — power_saver profiles,
# Yousef approved 2026-11-11) UNION the active power-mode
# profile's standby value (when the profile sets one).
SM_STATE=$(cat "$DASH/.sleep_mode" 2>/dev/null | tr -d '[:space:]')
case "$SM_STATE" in
    travel|long) EXPECT_STANDBY=3600 ;;
    *) EXPECT_STANDBY=600 ;;
esac
STANDBY_EXPECT="$EXPECT_STANDBY"
if [ -n "$PM_STANDBY" ]; then
    _in_set "$STANDBY_EXPECT" "$PM_STANDBY" || STANDBY_EXPECT="$STANDBY_EXPECT $PM_STANDBY"
fi
if _in_set "$STANDBY_EXPECT" "$STANDBY_BAT"; then
    check "standbydelay (Bat=$STANDBY_BAT, sleep_mode=${SM_STATE:-default}, power_mode=$PM_MODE, expected one of: $STANDBY_EXPECT)" "yes" "yes"
else
    check "standbydelay (Bat=$STANDBY_BAT, sleep_mode=${SM_STATE:-default}, power_mode=$PM_MODE, expected one of: $STANDBY_EXPECT)" "no" "yes"
fi

POWERNAP=$(pmset -g | grep powernap | awk '{print $2}')
[ -z "$POWERNAP" ] && POWERNAP="0"
check "powernap = 0 (or absent)" "$POWERNAP" "0"

# womp — from custom (better) or default to 0 if absent.
# womp (Wake for network access) is Yousef's own preference toggle —
# he enabled it on 2026-11-13. Either value is a legitimate user
# choice, not a health invariant: the old "womp = 0" check false-
# FAILed his deliberate setting and trained him to ignore FAIL
# (hardening 2026-11-14, seed 3). PASS on 0 or 1; FAIL only when the
# value is unreadable or out of range — FAIL must mean failure.
WOMP=$(pmset -g custom 2>/dev/null | grep '^ *womp' | awk '{print $2}' | head -1)
[ -z "$WOMP" ] && WOMP=$(pmset -g 2>/dev/null | grep '^ *womp' | awk '{print $2}' | head -1)
[ -z "$WOMP" ] && WOMP="0"
case "$WOMP" in
    0|1) check "womp = $WOMP (user preference — either value is healthy)" "ok" "ok" ;;
    *)   check "womp readable (got: $WOMP)" "bad" "ok" ;;
esac

echo "" | tee -a "$REPORT"

# ─── SUDOERS ───
echo "─── SUDOERS ───" | tee -a "$REPORT"

# (deleted in BC) The battopt NOPASSWD check is gone with the
# closed-source binary; the pmset check below is the BC sudoers
# check (pmset-only replacement, W5.3).

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

# BC: temperature from bc-status (read-only), never battopt.
BC_OUT=""
[ -x "$BC_BUILD_DIR/bc-status" ] && BC_OUT=$("$BC_BUILD_DIR/bc-status" 2>/dev/null)
TEMP=$(echo "$BC_OUT" | grep '^TempBatteryPack:' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)

if [ -z "$TEMP" ]; then
    warn "Temp: could not read (bc-status may have failed)"
elif [ "${TEMP%.*}" -lt 40 ] 2>/dev/null; then
    check "Temp < 40°C" "yes" "yes"
elif [ "${TEMP%.*}" -lt 45 ] 2>/dev/null; then
    warn "Temp = ${TEMP}°C (warm)"
else
    warn "Temp = ${TEMP}°C (hot)"
fi

echo "" | tee -a "$REPORT"

# ─── CALIBRATION ───
echo "─── CALIBRATION ───" | tee -a "$REPORT"

# Calibrate build (2026-11-14): a run is supervised by the watchdog;
# its heartbeat must be <= 10 min old (the same staleness bound
# bc-limit v1.3 applies to calibrate sessions). The anti-sleep
# posture marker is expected only during the discharge leg.
if [ -f "$DASH/.calibration_run" ]; then
    CAL_HB=$(grep '^HEARTBEAT=' "$DASH/.calibration_run" 2>/dev/null | tail -1 | cut -d= -f2)
    case "$CAL_HB" in ''|*[!0-9]*) CAL_HB=0 ;; esac
    CAL_AGE=$(( $(date +%s) - CAL_HB ))
    CAL_LEG=$(grep '^LEG=' "$DASH/.calibration_run" 2>/dev/null | tail -1 | cut -d= -f2)
    if [ "$CAL_AGE" -le 600 ]; then
        check "Calibration run active (leg ${CAL_LEG:-?}, heartbeat ${CAL_AGE}s old)" "yes" "yes"
    else
        warn "Calibration run heartbeat STALE (${CAL_AGE}s, leg ${CAL_LEG:-?}) — supervisor not ticking"
    fi
else
    check "No calibration run active" "yes" "yes"
fi
if [ -f "$DASH/.calibration_posture_state" ]; then
    check "Calibration posture active (anti-sleep asserted for the discharge leg)" "yes" "yes"
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


