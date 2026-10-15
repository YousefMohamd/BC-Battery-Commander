#!/bin/bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BATS_BIN="$ROOT/tests/bats/bin/bats"

if [ -x "$BATS_BIN" ]; then
  exec "$BATS_BIN" "$ROOT/tests"/*.bats
fi

if command -v bats >/dev/null 2>&1; then
  exec bats "$ROOT/tests"/*.bats
fi

echo "bats not found at $BATS_BIN and not in PATH" >&2
exit 1
