#!/bin/bash
# charging_guard.sh — Layer 14: skip ALL operations when active_mode is hold or charge_full

ACTIVE_MODE=$(cat "$HOME/.battopt-swiftbar/.active_mode" 2>/dev/null | tr -d '[:space:]')

case "$ACTIVE_MODE" in
    hold|charge_full|calibration|discharge)
        # Never interfere with user-initiated sessions
        exit 0
        ;;
esac

# (Original logic omitted since we now rely on the early exit above)
exit 0
