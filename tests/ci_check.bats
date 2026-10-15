#!/usr/bin/env bats

CI="$BATS_TEST_DIRNAME/../.github/workflows/ci.yml"

@test "ci.yml exists" {
  [ -f "$CI" ]
}

@test "ci.yml uses ubuntu-latest with macos comment" {
  grep -q 'runs-on: ubuntu-latest # use macos-10.15 if available' "$CI"
}

@test "ci.yml checkout uses submodules true" {
  grep -q 'with: {submodules: true}' "$CI"
  ! grep -q 'submodules: recursive' "$CI"
}

@test "ci.yml has bash syntax step" {
  grep -q 'find src -name "*.sh" -type f -exec bash -n {} \;' "$CI"
}

@test "ci.yml has shellcheck step with severity warning" {
  grep -q 'ludeeus/action-shellcheck@master' "$CI"
  grep -q 'severity: warning' "$CI"
}

@test "ci.yml has bats step" {
  grep -q 'tests/bats/bin/bats tests/' "$CI"
}

@test "ci.yml has no sudo or battopt daemon lines" {
  ! grep -q 'sudo' "$CI"
  ! grep -q 'battopt daemon' "$CI"
}

@test "ci.yml is <=40 lines" {
  lines=$(wc -l < "$CI" | tr -d ' ')
  [ "$lines" -le 40 ]
}

@test "ci.yml has exactly 3 named test steps plus checkout" {
  # checkout + bash syntax + shellcheck + bats = 4 steps total
  count=$(grep -cE '^[[:space:]]*- (uses:|name:)' "$CI")
  [ "$count" -eq 4 ]
}
