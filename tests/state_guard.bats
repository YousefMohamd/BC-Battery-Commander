#!/usr/bin/env bats

setup() {
  export SG_DIR
  SG_DIR=$(mktemp -d)
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../src/daemon-helpers/state_guard.sh"
}

teardown() {
  rm -rf "$SG_DIR"
}

@test "guard_session_begin creates token and mode files" {
  run guard_session_begin discharge
  [ "$status" -eq 0 ]
  [ -f "$SG_DIR/.active_token" ]
  [ -f "$SG_DIR/.active_mode" ]
  grep -q "discharge" "$SG_DIR/.active_mode"
  [ -n "$1" ] || [ -s "$SG_DIR/.active_token" ]
}

@test "guard_session_active detects active modes" {
  guard_session_begin charge_full >/dev/null
  run guard_session_active
  [ "$status" -eq 0 ]
  token=$(cat "$SG_DIR/.active_token")
  guard_session_end "$token"
  run guard_session_active
  [ "$status" -ne 0 ]
}

@test "guard_session_active is inactive for idle" {
  echo "idle" > "$SG_DIR/.active_mode"
  run guard_session_active
  [ "$status" -ne 0 ]
}

@test "guard_token_matches validates token" {
  token=$(guard_session_begin hold)
  run guard_token_matches "$token"
  [ "$status" -eq 0 ]
  run guard_token_matches "invalid_token"
  [ "$status" -ne 0 ]
}

@test "guard_session_end clears token and sets idle" {
  token=$(guard_session_begin calibration)
  run guard_session_end "$token"
  [ "$status" -eq 0 ]
  [ ! -f "$SG_DIR/.active_token" ]
  [ "$(cat "$SG_DIR/.active_mode")" = "idle" ]
}

@test "guard_session_end rejects mismatched token" {
  token=$(guard_session_begin discharge)
  run guard_session_end "wrong_token"
  [ "$status" -ne 0 ]
  [ -f "$SG_DIR/.active_token" ]
  # cleanup with correct token
  guard_session_end "$token"
}

@test "guard_lock uses mkdir and stores pid" {
  guard_lock
  [ -d "$SG_DIR/.state_guard.lock" ]
  [ "$(cat "$SG_DIR/.state_guard.lock/pid")" = "$$" ]
  guard_unlock
  [ ! -d "$SG_DIR/.state_guard.lock" ]
}

@test "guard_new_token format contains mode" {
  token=$(guard_new_token "discharge")
  [[ "$token" == *"discharge" ]]
}
