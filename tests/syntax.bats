#!/usr/bin/env bats

@test "all src shell scripts pass bash -n" {
  run bash -c 'find "$BATS_TEST_DIRNAME/../src/daemon-helpers" "$BATS_TEST_DIRNAME/../src/app" "$BATS_TEST_DIRNAME/../src/plugin" -name "*.sh" -type f -exec bash -n {} \;'
  [ "$status" -eq 0 ]
}

@test "each script individually passes bash -n" {
  while IFS= read -r f; do
    run bash -n "$f"
    if [ "$status" -ne 0 ]; then
      echo "failed: $f" >&2
      echo "$output" >&2
      return 1
    fi
  done < <(find "$BATS_TEST_DIRNAME/../src/daemon-helpers" "$BATS_TEST_DIRNAME/../src/app" "$BATS_TEST_DIRNAME/../src/plugin" -name "*.sh" -type f)
}
