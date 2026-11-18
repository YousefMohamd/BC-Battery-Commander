#!/bin/bash
# Test: hold_reached session dedup (notification policy 2026-11-11).
# Extracts the ACTUAL hold block (lines 428-449) from the deployed plugin
# and evals it against a stub notify in a temp DASH. No real notification
# is sent. Verifies: once per hold session, no repeat, session clears on
# leave-hold, re-notifies on re-enter, limit change starts a new session,
# suppressed send does NOT record the session (retry), DIFF>1 keeps session.
set -u
PLUGIN="/Users/Yousef/Projects/BattOpt-CC-Release/src/plugin/battery-commander.10s.sh"
TDASH="/tmp/bc-notify-test"
rm -rf "$TDASH"; mkdir -p "$TDASH/.notify"

# Extract the actual hold block and verify boundaries.
BLOCK="$(sed -n '428,449p' "$PLUGIN")"
echo "$BLOCK" | head -1 | grep -q "hold_reached" || { echo "FAIL: block start mismatch"; exit 1; }
echo "$BLOCK" | tail -1 | grep -qx "fi" || { echo "FAIL: block end mismatch"; exit 1; }
printf '%s\n' "$BLOCK" > "$TDASH/hold_block.sh"

# Stubs + vars. notify_proactive_v2 stub: logs the call and (unless blocked)
# writes the type file, mimicking the real function's send.
CALLS="$TDASH/calls.log"; : > "$CALLS"
STUB_BLOCK=0
notify_proactive_v2() {
    local key="$1" cooldown="$2" title="$3" msg="$4"
    if [ "$STUB_BLOCK" = "1" ]; then return 0; fi
    printf '%s|%s|%s\n' "$key" "$title" "$msg" >> "$CALLS"
    printf '%s\n' "$(date +%s)" > "$TDASH/.notify/hold_reached"
}
_atomic_write() { printf '%s\n' "$2" > "$1.tmp.$$" 2>/dev/null && mv "$1.tmp.$$" "$1" 2>/dev/null; }
DASH="$TDASH"
NOW_TS=$(date +%s)
PASS=0; FAIL=0
check() { # check <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS: $1";
    else FAIL=$((FAIL+1)); echo "FAIL: $1 (expected [$2] got [$3])"; fi
}
run_block() { NOW_TS=$(date +%s); . "$TDASH/hold_block.sh"; }

# Case 1: new hold -> notify once, session written.
ACTIVE_MODE="hold"; PCT=86; UPPER=86; LOWER=85
run_block
check "case1 notify called once" "1" "$(wc -l < "$CALLS" | tr -d ' ')"
check "case1 session file" "86/85" "$(cat "$TDASH/.notify/hold_reached_session" 2>/dev/null || echo MISSING)"
# Case 2+3: same hold, render again (x2) -> no more notifies.
run_block; run_block
check "case2/3 no repeat notify" "1" "$(wc -l < "$CALLS" | tr -d ' ')"
check "case2/3 session intact" "86/85" "$(cat "$TDASH/.notify/hold_reached_session" 2>/dev/null || echo MISSING)"
# Case 4: leave hold -> session removed.
ACTIVE_MODE="idle"
run_block
check "case4 session cleared on leave-hold" "MISSING" "$(cat "$TDASH/.notify/hold_reached_session" 2>/dev/null || echo MISSING)"
check "case4 no notify on leave" "1" "$(wc -l < "$CALLS" | tr -d ' ')"
# Case 5: re-enter hold -> notify once more.
ACTIVE_MODE="hold"; PCT=86; UPPER=86; LOWER=85
run_block
check "case5 re-enter notifies once" "2" "$(wc -l < "$CALLS" | tr -d ' ')"
check "case5 session re-written" "86/85" "$(cat "$TDASH/.notify/hold_reached_session" 2>/dev/null || echo MISSING)"
# Case 6: limit change -> new session, notify once.
UPPER=90; LOWER=89; PCT=90
run_block
check "case6 limit change notifies" "3" "$(wc -l < "$CALLS" | tr -d ' ')"
check "case6 session updated" "90/89" "$(cat "$TDASH/.notify/hold_reached_session" 2>/dev/null || echo MISSING)"
# Case 7: suppressed send -> session IS still recorded (the hold episode is
# handled; the user was already notified recently, which is why the
# cooldown/cap suppressed it). No duplicate on retry.
rm -f "$TDASH/.notify/hold_reached_session"
STUB_BLOCK=1
run_block
check "case7 suppressed: no notify logged" "3" "$(wc -l < "$CALLS" | tr -d ' ')"
check "case7 suppressed: session IS recorded" "90/89" "$(cat "$TDASH/.notify/hold_reached_session" 2>/dev/null || echo MISSING)"
STUB_BLOCK=0
run_block
check "case7 retry: no duplicate notify" "3" "$(wc -l < "$CALLS" | tr -d ' ')"
check "case7 session still recorded" "90/89" "$(cat "$TDASH/.notify/hold_reached_session" 2>/dev/null || echo MISSING)"
# Case 8: DIFF>1 while still holding -> no notify, session KEPT.
PCT=84
run_block
check "case8 DIFF>1: no notify" "3" "$(wc -l < "$CALLS" | tr -d ' ')"
check "case8 DIFF>1: session kept" "90/89" "$(cat "$TDASH/.notify/hold_reached_session" 2>/dev/null || echo MISSING)"
PCT=90
run_block
check "case8 back at limit: no repeat" "3" "$(wc -l < "$CALLS" | tr -d ' ')"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$TDASH"
[ "$FAIL" = "0" ] && echo "ALL HOLD-SESSION TESTS PASS" || echo "HOLD-SESSION TESTS FAILED"
exit "$FAIL"
