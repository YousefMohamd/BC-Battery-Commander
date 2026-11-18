#!/bin/bash
# Regression battery 2026-11-15 (post-labelfix) — runs each suite in its
# own sandbox per its own design; appends everything to one log.
cd /Users/Yousef/Projects/BattOpt-CC-Release/battopt-project/bc-build || exit 1
OUT=/tmp/regression-20261115.log
: > "$OUT"
run() {
  name="$1"; shift
  echo "===== $name =====" >> "$OUT"
  "$@" >> "$OUT" 2>&1
  echo "----- $name exit=$? -----" >> "$OUT"
}
run test_bc_watchdog bash ./test_bc_watchdog.sh
run test_discharge bash ./test_discharge.sh
run test_charge_persistence bash ./test_charge_persistence.sh
run test_calibration bash ./test_calibration.sh
run test_bc_limit_calibrate bash ./test_bc_limit_calibrate.sh
run test_bc_limit_discharge bash ./test_bc_limit_discharge.sh
run test_sentinel bash ./verify-deploy-test/test_sentinel.sh
run test_sidecar_dispatch bash ./verify-deploy-test/test_sidecar_dispatch.sh
run tracker_equiv python3 ./verify-deploy-test/test_tracker_live_equiv.py
echo "ALL DONE" >> "$OUT"
