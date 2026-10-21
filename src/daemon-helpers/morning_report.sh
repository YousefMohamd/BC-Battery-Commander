#!/bin/bash
# BattOpt Morning Report — runs at 8 AM daily
LOG="$HOME/.battopt-swiftbar/actions.log"
REPORT_DIR="$HOME/.battopt-swiftbar/reports"
mkdir -p "$REPORT_DIR"

STAMP=$(date '+%Y%m%d')
REPORT="$REPORT_DIR/morning-$STAMP.txt"

{
    echo "═══════════════════════════════════════════════════════════════"
    echo "  BattOpt Morning Report — $(date '+%Y-%m-%d %H:%M')"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    echo "─── Battery Now ───"
    if [ -f "$HOME/.battopt-swiftbar/.status_cache" ]; then
        cat "$HOME/.battopt-swiftbar/.status_cache"
    else
        echo "(status cache not available — will refresh on next plugin run)"
    fi
    echo ""
    
    echo "─── Baseline (from last night) ───"
    cat "$HOME/.battopt-swiftbar/.sleep_baseline" 2>/dev/null
    echo ""
    
    echo "─── Current Wakes ───"
    echo "Total: $(pmset -g log 2>/dev/null | grep -cE 'Wake from|DarkWake')"
    echo ""
    
    echo "─── Last Night's Wake Reasons ───"
    pmset -g log 2>/dev/null | grep -E "Wake from|DarkWake" | tail -20 | sed 's/^/  /'
    echo ""
    
    echo "─── Recent Actions ───"
    tail -20 "$LOG"
    echo ""
    
    echo "═══════════════════════════════════════════════════════════════"
} > "$REPORT"

# Notification
terminal-notifier \
    -title "BattOpt — Morning Report" \
    -message "Sleep report ready. Click to open." \
    -execute "open -e $REPORT" \
    -group "morning-report" 2>/dev/null || \
osascript -e "display notification \"Morning report ready\" with title \"BattOpt\""
