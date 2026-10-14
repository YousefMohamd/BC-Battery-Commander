#!/bin/bash
# Runs sailing + adaptive + ensure-limit + system-guard
LOG="$HOME/.battopt-swiftbar/actions.log"

[ -x ~/.battopt-swiftbar/sailing_tracker.sh ] && ~/.battopt-swiftbar/sailing_tracker.sh 2>/dev/null
[ -x ~/.battopt-swiftbar/adaptive.sh ] && ~/.battopt-swiftbar/adaptive.sh 2>/dev/null
[ -x ~/.battopt-swiftbar/ensure_limit.sh ] && ~/.battopt-swiftbar/ensure_limit.sh 2>/dev/null
[ -x ~/.battopt-swiftbar/system_guard.sh ] && ~/.battopt-swiftbar/system_guard.sh 2>/dev/null

exit 0
