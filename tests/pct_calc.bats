#!/usr/bin/env bats
@test "test_pct_rounding_55" { CUR=5500; MAX=10000; PCT=$(( (CUR*100+MAX/2)/MAX )); [ "$PCT" -eq 55 ]; }
@test "test_pct_rounding_100" { CUR=10000; MAX=10000; PCT=$(( (CUR*100+MAX/2)/MAX )); [ "$PCT" -eq 100 ]; }
@test "test_pct_rounding_0" { CUR=0; MAX=10000; PCT=$(( (CUR*100+MAX/2)/MAX )); [ "$PCT" -eq 0 ]; }
