#!/usr/bin/env bats
setup() { export TMPDIR=$(mktemp -d); export HOME="$TMPDIR"; mkdir -p "$HOME/.battery-commander"; export LAST_INPUTS="$HOME/.battery-commander/.last_inputs"; }
teardown() { rm -rf "$TMPDIR"; }
@test "test_rejects_alpha" { run bash -c 'source "$1"; validate_int "$2" "$3" "$4"' _ "$BATS_TEST_DIRNAME/../src/daemon-helpers/dispatch.sh" abc 20 90; [ "$status" -ne 0 ]; }
@test "test_rejects_below_min" { run bash -c 'source "$1"; validate_int "$2" "$3" "$4"' _ "$BATS_TEST_DIRNAME/../src/daemon-helpers/dispatch.sh" 10 20 90; [ "$status" -ne 0 ]; }
@test "test_accepts_lower_bound" { run bash -c 'source "$1"; validate_int "$2" "$3" "$4"' _ "$BATS_TEST_DIRNAME/../src/daemon-helpers/dispatch.sh" 20 20 90; [ "$status" -eq 0 ]; }
@test "test_accepts_upper_bound" { run bash -c 'source "$1"; validate_int "$2" "$3" "$4"' _ "$BATS_TEST_DIRNAME/../src/daemon-helpers/dispatch.sh" 90 20 90; [ "$status" -eq 0 ]; }
@test "test_atomic_creates_file" { run bash -c 'source "$1"; atomic_write "$2" "$3"; cat "$2"' _ "$BATS_TEST_DIRNAME/../src/daemon-helpers/dispatch.sh" "$TMPDIR/f" "hello"; [ "$output" = "hello" ]; }
@test "test_atomic_replace" { run bash -c 'source "$1"; atomic_write "$2" a; atomic_write "$2" b; cat "$2"' _ "$BATS_TEST_DIRNAME/../src/daemon-helpers/dispatch.sh" "$TMPDIR/f"; [ "$output" = "b" ]; }
@test "test_get_last_input_fallback" { run bash -c 'source "$1"; get_last_input "$2" "$3"' _ "$BATS_TEST_DIRNAME/../src/daemon-helpers/dispatch.sh" MISSING fallback; [ "$output" = "fallback" ]; }
@test "test_save_and_get" { run bash -c 'source "$1"; save_last_input K1 v1; get_last_input K1 fallback' _ "$BATS_TEST_DIRNAME/../src/daemon-helpers/dispatch.sh"; [ "$output" = "v1" ]; }
@test "test_overwrites_key" { run bash -c 'source "$1"; save_last_input K1 v1; save_last_input K1 v2; get_last_input K1 x' _ "$BATS_TEST_DIRNAME/../src/daemon-helpers/dispatch.sh"; [ "$output" = "v2" ]; }

