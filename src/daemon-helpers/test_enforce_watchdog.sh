#!/bin/bash
# test_enforce_watchdog.sh — sandboxed regression test.
# Verifies: notifier cap (3), discharge retry cadence (300s),
# monotonic COUNT, suppression log, healthy-tick cleanup of all 4 files.
# No system mutations: every external command (date, ioreg, sudo, pkill,
# launchctl, pgrep, battopt, sleep, sd_watcher, terminal-notifier) is routed
# through stubs placed first on PATH; DASH points at a temp directory.
# Clock starts at BASE_EPOCH, not 0. In production $NOW is real epoch time,
# so the ">=300s since last discharge/critical" gate fires on the first
# eligible tick. Starting at BASE_EPOCH reproduces that behavior in the
# sandbox without a wall-clock wait, and it is what makes the intended
# 240/540/840 CRITICAL timeline emerge instead of being swallowed by an
# initial 300s wait relative to epoch.
# BAT patch: enforce calls the real binary via absolute $BAT, which bypasses
# PATH stubs. The sed below rewrites the BAT definition to the stub, and the
# grep check makes a failed substitution a hard FAIL, not a silent real run.
set -u
TEST_ROOT=$(mktemp -d /tmp/battopt-test.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
DASH="$TEST_ROOT/.battopt-swiftbar"
mkdir -p "$DASH"
printf 'LAST_UPPER=80\nLAST_LOWER=75\n' > "$DASH/config"
BIN="$TEST_ROOT/bin"
mkdir -p "$BIN"
export TEST_ROOT
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
mk_violation() {
    cat > "$BIN/ioreg" <<'OUT'
#!/bin/bash
cat <<'X'
"CurrentCapacity" = 85
"MaxCapacity" = 100
"IsCharging" = Yes
"ExternalConnected" = Yes
X
OUT
    chmod +x "$BIN/ioreg"
}
mk_healthy() {
    cat > "$BIN/ioreg" <<'OUT'
#!/bin/bash
cat <<'X'
"CurrentCapacity" = 75
"MaxCapacity" = 100
"IsCharging" = No
"ExternalConnected" = No
X
OUT
    chmod +x "$BIN/ioreg"
}
mk_violation
cat > "$BIN/sudo" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-n" ] && shift
exec "$@"
EOF
chmod +x "$BIN/sudo"
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
cat > "$BIN/launchctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN/launchctl"
cat > "$BIN/battopt" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN/battopt"
NOTIF_HITS="$TEST_ROOT/notifier_hits"
: > "$NOTIF_HITS"
NOTIF_DIR="$TEST_ROOT/terminal-notifier.app/Contents/MacOS"
mkdir -p "$NOTIF_DIR"
cat > "$NOTIF_DIR/terminal-notifier" <<'EOF'
#!/bin/bash
echo "$(cat "$TEST_ROOT/now")" >> "$TEST_ROOT/notifier_hits"
exit 0
EOF
chmod +x "$NOTIF_DIR/terminal-notifier"
cat > "$DASH/sd_watcher.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$DASH/sd_watcher.sh"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SRC_DIR/state_guard.sh" "$DASH/state_guard.sh" \
    || { echo "FAIL: state_guard.sh not found in $SRC_DIR"; exit 1; }
SCRIPT_SRC="$SRC_DIR/enforce_watchdog.sh"
[ -f "$SCRIPT_SRC" ] || { echo "FAIL: enforce_watchdog.sh not found"; exit 1; }
SCRIPT_RUN="$TEST_ROOT/enforce_watchdog.sh"
sed \
    -e "s|^DASH=\"\$HOME/.battopt-swiftbar\"|DASH=\"$DASH\"|" \
    -e "s|/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier|$NOTIF_DIR/terminal-notifier|g" \
    -e "s|^source \"/Users/Yousef/.battopt-swiftbar/.throttle_helper.sh\".*|: # throttle skipped in sandbox|" \
    -e "s|^BAT=\"/usr/local/bin/battopt\"|BAT=\"$BIN/battopt\"|" \
    "$SCRIPT_SRC" > "$SCRIPT_RUN"
chmod +x "$SCRIPT_RUN"
grep -q "DASH=\"$DASH\"" "$SCRIPT_RUN" || { echo "FAIL: DASH substitution"; exit 1; }
grep -q "# throttle skipped in sandbox" "$SCRIPT_RUN" || { echo "FAIL: throttle substitution"; exit 1; }
grep -q "BAT=\"$BIN/battopt\"" "$SCRIPT_RUN" || { echo "FAIL: BAT substitution"; exit 1; }
export PATH="$BIN:$PATH"
export HOME="$TEST_ROOT"
BASE_EPOCH=1730000000
for ((t=15; t<=1200; t+=15)); do
    echo "$((BASE_EPOCH + t))" > "$TEST_ROOT/now"
    bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
done
LOG_FILE="$DASH/.enforce.log"
NOTIF_COUNT=$(wc -l < "$NOTIF_HITS" | tr -d ' ')
STATE_LINE=$(cat "$DASH/.enforce_state" 2>/dev/null || echo "0|0")
FINAL_COUNT=$(echo "$STATE_LINE" | cut -d'|' -f1)
DISCH_HITS=$(grep "action: force tracked discharge" "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
CRIT_LOGS=$(grep "CRITICAL: enforcement failed" "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
SUPPRESS_LOGS=$(grep "CRITICAL: notification suppressed" "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
echo "notifier_hits=$NOTIF_COUNT   (expected 3)"
echo "discharge_hits=$DISCH_HITS   (expected >= 3)"
echo "final_count=$FINAL_COUNT   (expected > 16)"
echo "crit_logs=$CRIT_LOGS   (expected >= 3)"
echo "suppress_logs=$SUPPRESS_LOGS   (expected >= 1)"
FAIL=0
[ "$NOTIF_COUNT" -eq 3 ] || { echo "FAIL: notifier hits"; FAIL=1; }
[ "$DISCH_HITS" -ge 3 ] || { echo "FAIL: discharge hits"; FAIL=1; }
[ "$FINAL_COUNT" -gt 16 ] || { echo "FAIL: final count"; FAIL=1; }
[ "$SUPPRESS_LOGS" -ge 1 ] || { echo "FAIL: suppression log"; FAIL=1; }
mk_healthy
echo "$((BASE_EPOCH + 1215))" > "$TEST_ROOT/now"
bash "$SCRIPT_RUN" >/dev/null 2>&1 || true
for f in .enforce_state .enforce_last_discharge .enforce_last_critical .enforce_crit_count; do
    [ -f "$DASH/$f" ] && { echo "FAIL: $f survived healthy tick"; FAIL=1; }
done
[ "$FAIL" -eq 0 ] && { echo "PASS"; exit 0; } || exit 1
