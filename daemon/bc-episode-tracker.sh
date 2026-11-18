#!/bin/sh
# bc-episode-tracker — Battery Commander natural-use verification (v1).
# Design: natural-verification-design.md §2/§4/§9 step 1. Sandbox form:
# offline episode extraction from log files; writes only to its --out-dir.
# Implementation: bc-episode-tracker.py (Python 3, stdlib only).
PY=$(command -v python3 || echo /usr/local/bin/python3)
exec "$PY" "$(dirname "$0")/bc-episode-tracker.py" "$@"
