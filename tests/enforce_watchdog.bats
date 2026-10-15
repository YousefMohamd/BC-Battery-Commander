#!/usr/bin/env bats

@test "pct calc with rounding" { CUR=5500; MAX=10000; PCT=$(( (CUR*100+MAX/2)/MAX )); [ "$PCT" -eq 55 ]; }

@test "violation when charging above upper" {
  EXT="Yes"; ISCHG="Yes"; PCT=86; UPPER=85
  run bash -c '[ "$1" = "Yes" ] && [ "$2" = "Yes" ] && [ "$3" -ge "$4" ] && echo violation' _ "$EXT" "$ISCHG" "$PCT" "$UPPER"
  [ "$output" = "violation" ]
}

@test "no violation on battery" {
  EXT="No"; ISCHG="No"; PCT=86; UPPER=85
  run bash -c '[ "$1" = "Yes" ] && [ "$2" = "Yes" ] && [ "$3" -ge "$4" ] && echo violation || echo ok' _ "$EXT" "$ISCHG" "$PCT" "$UPPER"
  [ "$output" = "ok" ]
}
