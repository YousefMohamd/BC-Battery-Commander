#!/bin/bash
# gate_live_test_20261117.sh — LIVE tests of the dispatch full-stop safety gate.
# Runs against the DEPLOYED dispatch (~/.battery-commander/dispatch.sh).
# Cases:
#   1. No token, ghost shape (detached nohup, action + --force) -> REFUSED, zero delta
#   2. Stale token (now-3600) -> REFUSED, zero delta; token cleaned up by this script
#   3. Fresh token + BC_FULLSTOP_PROBE=1 -> GATE PASS (probe), token consumed, zero delta
# A fresh token is NEVER used without the probe env: the real teardown must not run.
DASH="$HOME/.battery-commander"
DISPATCH="$DASH/dispatch.sh"
TOKEN="$DASH/.fullstop_armed"
ALOG="$DASH/actions.log"
FAILURES=0

cfg_md5() { md5 -q "$DASH/config" 2>/dev/null; }
agents()  { launchctl list 2>/dev/null | grep -c batterycommander; }
app_pid() { pgrep -f 'BatteryCommander.app/Contents/MacOS/BatteryCommander' | head -1; }
ghost()   { kill -0 21524 2>/dev/null && echo alive || echo absent; }
marker()  { [ -e "$DASH/.user_shutdown" ] && echo PRESENT || echo absent; }
n_refused() { grep -c 'REFUSED' "$ALOG" 2>/dev/null; }
n_pass()    { grep -c 'GATE PASS' "$ALOG" 2>/dev/null; }

BASE_CFG=$(cfg_md5); BASE_AGENTS=$(agents); BASE_APP=$(app_pid); BASE_GHOST=$(ghost)
echo "BASELINE: cfg=$BASE_CFG agents=$BASE_AGENTS app=$BASE_APP ghost=$BASE_GHOST marker=$(marker)"
echo "BASELINE_TICK: $(tail -1 "$DASH/bc-limit-daemon.log" 2>/dev/null)"

check_delta() {
  # $1 = case label. Returns 0 if zero delta vs baseline.
  local bad=""
  [ "$(cfg_md5)" = "$BASE_CFG" ] || bad="$bad config_md5($(cfg_md5))"
  [ "$(agents)" = "$BASE_AGENTS" ] || bad="$bad agents($(agents))"
  [ "$(app_pid)" = "$BASE_APP" ] || bad="$bad app_pid($(app_pid))"
  [ "$(ghost)" = "$BASE_GHOST" ] || bad="$bad ghost($(ghost))"
  [ "$(marker)" = "absent" ] || bad="$bad marker(PRESENT)"
  if [ -n "$bad" ]; then echo "$1 DELTA_DETECTED:$bad"; return 1; fi
  echo "$1 DELTA: none (cfg ok, agents=$BASE_AGENTS, app=$BASE_APP, ghost=$BASE_GHOST, marker absent)"
  return 0
}

invoke_plain() { nohup bash "$DISPATCH" shutdown --force >> "$ALOG" 2>&1 & }
invoke_probe() { nohup env BC_FULLSTOP_PROBE=1 bash "$DISPATCH" shutdown --force >> "$ALOG" 2>&1 & }

# ---------------- Case 1: no token, ghost shape ----------------
rm -f "$TOKEN"
R0=$(n_refused)
invoke_plain
sleep 10
R1=$(n_refused)
if [ "$R1" -gt "$R0" ]; then echo "CASE1 LOG: REFUSED appeared ($R0 -> $R1)"; else echo "CASE1 LOG: FAIL no new REFUSED ($R0 -> $R1)"; FAILURES=$((FAILURES+1)); fi
grep 'REFUSED' "$ALOG" | tail -1
check_delta CASE1 || FAILURES=$((FAILURES+1))

# ---------------- Case 2: stale token ----------------
echo $(( $(date +%s) - 3600 )) > "$TOKEN"
R0=$(n_refused)
invoke_plain
sleep 10
R1=$(n_refused)
if [ "$R1" -gt "$R0" ]; then echo "CASE2 LOG: REFUSED appeared ($R0 -> $R1)"; else echo "CASE2 LOG: FAIL no new REFUSED ($R0 -> $R1)"; FAILURES=$((FAILURES+1)); fi
grep 'REFUSED' "$ALOG" | tail -1
check_delta CASE2 || FAILURES=$((FAILURES+1))
rm -f "$TOKEN"
echo "CASE2 CLEANUP: stale token removed by script; token now: $([ -e "$TOKEN" ] && echo present || echo absent)"

# ---------------- Case 3: fresh token + probe ----------------
date +%s > "$TOKEN"
P0=$(n_pass)
invoke_probe
sleep 10
P1=$(n_pass)
if [ "$P1" -gt "$P0" ]; then echo "CASE3 LOG: GATE PASS appeared ($P0 -> $P1)"; else echo "CASE3 LOG: FAIL no new GATE PASS ($P0 -> $P1)"; FAILURES=$((FAILURES+1)); fi
grep 'GATE PASS' "$ALOG" | tail -1
if [ -e "$TOKEN" ]; then echo "CASE3 TOKEN: FAIL token still present (not consumed)"; FAILURES=$((FAILURES+1)); else echo "CASE3 TOKEN: consumed (file gone)"; fi
check_delta CASE3 || FAILURES=$((FAILURES+1))

echo "FINAL_TICK: $(tail -1 "$DASH/bc-limit-daemon.log" 2>/dev/null)"
if [ "$FAILURES" -eq 0 ]; then echo "SUMMARY: ALL 3 CASES PASS"; else echo "SUMMARY: FAILURES=$FAILURES"; fi
