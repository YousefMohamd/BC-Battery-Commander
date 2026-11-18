#!/bin/sh
# test-bench-driver-20261118.sh — comprehensive test, Part A bench stage
# (2026-11-18). Runs each catalog suite in its own directory and
# captures full output per suite. All suites are sandbox-based;
# A15/A16 are read-only live-deployment checkers. Nothing here
# writes live state.
set -u
BB="/Users/Yousef/Projects/BattOpt-CC-Release/battopt-project/bc-build"
REPO="/Users/Yousef/Projects/BattOpt-CC-Release"
OUT="$BB/test-bench-20261118"
mkdir -p "$OUT"
SUM="$OUT/summary.txt"
: > "$SUM"
echo "bench driver start: $(date)" >> "$SUM"

run_suite() {
  id="$1"; dir="$2"; script="$3"
  log="$OUT/$id.log"
  echo "=== $id START $(date) :: $dir/$script" >> "$SUM"
  ( cd "$dir" && bash "./$script" ) > "$log" 2>&1
  rc=$?
  echo "=== $id END rc=$rc $(date)" >> "$SUM"
}

run_suite A01 "$BB" test_bc_limit_calibrate.sh
run_suite A02 "$BB" test_bc_limit_discharge.sh
run_suite A03 "$BB" test_bc_limit_apg.sh
run_suite A04 "$BB/gauge-test" test_bc_limit_gauge.sh
run_suite A05 "$BB" test_bc_limit_ac.sh
run_suite A06 "$BB/stagec-test/sub17" test_bc_limit_fr007.sh
run_suite A07 "$BB" test_discharge.sh
run_suite A08 "$BB" test_charge_persistence.sh
run_suite A09 "$BB" test_calibration.sh
run_suite A10 "$BB" test_bc_watchdog.sh
run_suite A11 "$BB/verify-deploy-test" test_sentinel.sh
run_suite A12 "$BB/verify-deploy-test" test_sidecar_dispatch.sh

echo "=== A15 START $(date) :: src/verify-install.sh" >> "$SUM"
( cd "$REPO" && bash src/verify-install.sh ) > "$OUT/A15.log" 2>&1
echo "=== A15 END rc=$? $(date)" >> "$SUM"

echo "=== A16 START $(date) :: src/daemon-helpers/project_health.sh" >> "$SUM"
( cd "$REPO" && bash src/daemon-helpers/project_health.sh ) > "$OUT/A16.log" 2>&1
echo "=== A16 END rc=$? $(date)" >> "$SUM"

echo "ALL DONE $(date)" >> "$SUM"
