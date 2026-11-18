#!/bin/sh
# bc-verify — Battery Commander natural-use verification evaluator (v1).
# Design: natural-verification-design.md §5. Reader/judge only — never
# touches the SMC, the config, or any agent.
# Implementation: bc-verify.py (Python 3, stdlib only).
PY=$(command -v python3 || echo /usr/local/bin/python3)
exec "$PY" "$(dirname "$0")/bc-verify.py" "$@"
