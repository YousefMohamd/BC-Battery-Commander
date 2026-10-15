#!/usr/bin/env bats

@test "No->Yes is AC connected" {
  PREV="No"; EXT="Yes"
  run bash -c '[ "$1" = "No" ] && [ "$2" = "Yes" ] && echo connected' _ "$PREV" "$EXT"
  [ "$output" = "connected" ]
}

@test "Yes->Yes no transition" {
  PREV="Yes"; EXT="Yes"
  run bash -c '[ "$1" = "No" ] && [ "$2" = "Yes" ] && echo connected || echo none' _ "$PREV" "$EXT"
  [ "$output" = "none" ]
}

@test "state file write/read" {
  SF="$(mktemp -d)/.ac_state"
  echo "Yes" > "$SF"
  [ "$(cat "$SF")" = "Yes" ]
  rm -rf "$(dirname "$SF")"
}
