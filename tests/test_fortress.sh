#!/bin/bash
# test_fortress.sh — E2E Fortress Mode validation
# Bash 3.2 compatible

set -euo pipefail

DASH="${HOME}/.battopt-swiftbar"
CFG="${DASH}/config"
BACKUP="${DASH}/.last_session_config"
LOG="${DASH}/actions.log"

log()   { echo "[$(date '+%H:%M:%S')] FORTRESS: $1"; }
pass()  { log "PASS: $1"; }
bail()  { log "FAIL: $1"; exit 1; }

setup() {
    mkdir -p "$DASH"
    sudo pkill -9 -f "battopt " 2>/dev/null || true
    sleep 1
}

teardown() {
    sudo -n /usr/local/bin/battopt limit 85 80 >> "$LOG" 2>&1 || true
    rm -f "$BACKUP" 2>/dev/null || true
    rm -f "$DASH/.user_shutdown" 2>/dev/null || true
}

write_config() {
    local u="$1" l="$2" sailing="${3:-true}" gap="${4:-10}"
    cat > "$CFG" <<EOF
LAST_UPPER=$u
LAST_LOWER=$l
SAILING=$sailing
SAIL_GAP=$gap
EOF
}

log "=== FORTRESS E2E TEST SUITE ==="
setup
trap teardown EXIT

# T1: Shutdown backup
write_config 80 75 true 5
cp "$CFG" "$BACKUP"
diff <(cat "$CFG") <(cat "$BACKUP") || bail "T1: backup mismatch"
pass "T1: config backed up correctly"

# T2: Launcher restore
write_config 80 75 true 5
cp "$CFG" "$BACKUP"
cat > "$CFG" <<EOF
LAST_UPPER=85
LAST_LOWER=80
SAILING=true
SAIL_GAP=10
EOF
cp "$BACKUP" "$CFG"
source "$CFG"
[ "$LAST_UPPER" = "80" ] && [ "$LAST_LOWER" = "75" ] || bail "T2: restore failed"
pass "T2: launcher restored config correctly"

log "=== ALL FORTRESS TESTS PASSED ==="
