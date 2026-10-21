#!/bin/bash
# BattOpt Log Cleanup — runs daily at 3 AM via LaunchAgent
LOG="$HOME/.battopt-swiftbar/actions.log"
ARCHIVE_DIR="$HOME/.battopt-swiftbar/reports"
CLEANUP_LOG="$HOME/.battopt-swiftbar/.cleanup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$CLEANUP_LOG"; }

log "=== Cleanup started ==="

# 1. actions.log — rotate if > 100 KB (≈ 5-7 days)
if [ -f "$LOG" ]; then
    SIZE=$(wc -c < "$LOG" | tr -d ' ')
    if [ "$SIZE" -gt 102400 ]; then
        mkdir -p "$ARCHIVE_DIR"
        ARCHIVE="$ARCHIVE_DIR/actions-$(date +%Y%m%d-%H%M).log"
        cp "$LOG" "$ARCHIVE"
        tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
        log "actions.log rotated (was ${SIZE}B, archived to $(basename "$ARCHIVE"), kept last 500 lines)"
    else
        log "actions.log OK (${SIZE}B, under 100KB threshold)"
    fi
fi

# 2. reports/ archives — delete > 30 days
if [ -d "$ARCHIVE_DIR" ]; then
    COUNT=$(find "$ARCHIVE_DIR" -type f -name "actions-*.log" -mtime +30 2>/dev/null | wc -l | tr -d ' ')
    find "$ARCHIVE_DIR" -type f -name "actions-*.log" -mtime +30 -delete 2>/dev/null
    log "Archive: removed $COUNT files > 30 days"
fi

# 3. /tmp/battopt_* — delete > 24 hours
COUNT=$(find /tmp -maxdepth 1 -name "battopt_*" -mtime +1 2>/dev/null | wc -l | tr -d ' ')
find /tmp -maxdepth 1 -name "battopt_*" -mtime +1 -delete 2>/dev/null
log "Tmp: removed $COUNT files > 24h"

# 4. .notify/ — delete > 48 hours
NOTIFY="$HOME/.battopt-swiftbar/.notify"
if [ -d "$NOTIFY" ]; then
    COUNT=$(find "$NOTIFY" -type f -mtime +2 2>/dev/null | wc -l | tr -d ' ')
    find "$NOTIFY" -type f -mtime +2 -delete 2>/dev/null
    log "Notify: removed $COUNT files > 48h"
fi

# 5. .guard_alerts/ — delete > 7 days
GUARD="$HOME/.battopt-swiftbar/.guard_alerts"
if [ -d "$GUARD" ]; then
    COUNT=$(find "$GUARD" -type f -mtime +7 2>/dev/null | wc -l | tr -d ' ')
    find "$GUARD" -type f -mtime +7 -delete 2>/dev/null
    log "Guard: removed $COUNT files > 7 days"
fi

# 6. Keep .cleanup.log under 50 KB
if [ -f "$CLEANUP_LOG" ]; then
    SIZE=$(wc -c < "$CLEANUP_LOG" | tr -d ' ')
    if [ "$SIZE" -gt 51200 ]; then
        tail -100 "$CLEANUP_LOG" > "$CLEANUP_LOG.tmp" && mv "$CLEANUP_LOG.tmp" "$CLEANUP_LOG"
        log "cleanup.log trimmed"
    fi
fi

# 7. Clear .armed_for_sleep if past sleep hours
FLAG="$HOME/.battopt-swiftbar/.armed_for_sleep"
if [ -f "$FLAG" ]; then
    H=$(date +%H)
    if [ "$H" -ge 9 ] && [ "$H" -lt 22 ]; then
        rm -f "$FLAG"
        log "Cleared .armed_for_sleep flag"
    fi
fi

# 8. Reports — delete > 30 days
REPORTS_DIR="$HOME/.battopt-swiftbar/reports"
if [ -d "$REPORTS_DIR" ]; then
    COUNT=$(find "$REPORTS_DIR" -type f \( -name "morning-*.txt" -o -name "*.baseline" \) -mtime +30 2>/dev/null | wc -l | tr -d ' ')
    find "$REPORTS_DIR" -type f \( -name "morning-*.txt" -o -name "*.baseline" \) -mtime +30 -delete 2>/dev/null
    log "Reports: removed $COUNT files > 30 days"
    
    # Keep only latest 7 morning reports
    ls -t "$REPORTS_DIR"/morning-*.txt 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null || true
fi

# 9. /tmp/battopt extras — delete > 7 days
for pattern in "battopt_health_*.txt" "battopt_heat_*.txt" "battopt_conflicts_*.txt" "battopt_sleep_report_*.txt" "battopt_recovery_*.txt"; do
    COUNT=$(find /tmp -maxdepth 1 -name "$pattern" -mtime +7 2>/dev/null | wc -l | tr -d ' ')
    find /tmp -maxdepth 1 -name "$pattern" -mtime +7 -delete 2>/dev/null
    [ "$COUNT" -gt 0 ] && log "Tmp ($pattern): removed $COUNT files"
done

# 10. Trim .healing.log + .audit.log
for f in "$HOME/.battopt-swiftbar/.healing.log" "$HOME/.battopt-swiftbar/.audit.log"; do
    if [ -f "$f" ]; then
        SIZE=$(wc -c < "$f" | tr -d ' ')
        if [ "$SIZE" -gt 102400 ]; then
            tail -200 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
            log "Trimmed $(basename $f) (was ${SIZE}B)"
        fi
    fi
done

log "=== Cleanup completed ==="
exit 0
