# Release v1.6.0 — Testing + CI

## What Changed
- 40 bats tests across 8 files
- bats-core submodule (tests/bats)
- tests/run.sh wrapper
- SECURITY.md (trust model, sudoers, session isolation)
- .github/workflows/ci.yml (bash -n + shellcheck + bats)

## How to Run Tests

tests/run.sh


## CI
![ci](https://github.com/YousefMohamd/BatterOpt/actions/workflows/ci.yml/badge.svg)

## Known Issues
- Stale .active_token scenario — fixed in commit 2a05c93
