#!/bin/sh
# liveproof-driver-20261118.sh — comprehensive test, live-proof stage
# (2026-11-18 evening). Re-runs the five bench-deferred bc-limit suites
# at the restored hold baseline (config 86/85, BCLM=10, pct ~86, on AC).
set -u
BB="/Users/Yousef/Projects/BattOpt-CC-Release/battopt-project/bc-build"
OUT="$BB/test-liveproof-20261118"
mkdir -p "$OUT"
SUM="$OUT/summary.txt"
: > "$SUM"
echo "liveproof driver start: $(date)" >> "$SUM"

run_suite() {
  id="$1"; dir="$2"; script="$3"
  log="$OUT/$id.log"
  echo "=== $id START $(date) :: $dir/$script" >> "$SUM"
  ( cd "$dir" && bash "./$script" ) > "$log" 2>&1
  rc=$?
  tail -1 "$log" >> "$SUM" 2>/dev/null
  echo "=== $id END rc=$rc $(date)" >> "$SUM"
}

run_suite A01 "$BB" test_bc_limit_calibrate.sh
run_suite A02 "$BB" test_bc_limit_discharge.sh
run_suite A03 "$BB" test_bc_limit_apg.sh
run_suite A05 "$BB" test_bc_limit_ac.sh
run_suite A06 "$BB/stagec-test/sub17" test_bc_limit_fr007.sh

echo "liveproof driver done: $(date)" >> "$SUM"
