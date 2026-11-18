#!/bin/bash
# Battery Commander Log Cleanup - runs daily at 3 AM via LaunchAgent
# (W5.3: rotation extended to EVERY log in the state dir.)
#
# Rotation keeps the last N lines (never deletes a log file itself).
# The .bak purge is NOT part of the daily run: it only runs when this
# script is invoked with the argument `purge-bak` AND the flag file
# .bak_purge_approved exists (two gates - user approval, W5.3).
# BC state dir: ~/.battery-commander/ is the ONLY live state dir
# (consolidation 2026-11-13, M2: the old-dir fallback is retired — the
# pre-migration dir is a kept, inert backup and must never be read or
# written as a live target). BC_DASH overrides (tests / dry-runs).
if [ -n "${BC_DASH:-}" ]; then
    DASH="$BC_DASH"
elif [ -d "$HOME/.battery-commander" ]; then
    DASH="$HOME/.battery-commander"
else
    echo "ERROR: Battery Commander state dir missing - ~/.battery-commander not found; refusing to run (old-dir fallback retired)" >&2
    exit 1
fi
LOG="$DASH/actions.log"
BC_BUILD_DIR="${BC_BUILD_DIR:-$HOME/Projects/BattOpt-CC-Release/battopt-project/bc-build}"
ARCHIVE_DIR="$DASH/reports"
CLEANUP_LOG="$DASH/.cleanup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$CLEANUP_LOG"; }

# Rotate one log file at 100 KB: archive a copy, keep the last N lines.
# Never deletes the log file itself. Usage: rotate_log <file> <keep-lines>
rotate_log() {
    local f="$1"
    local keep="${2:-200}"
    [ -f "$f" ] || return 0
    local size
    size=$(wc -c < "$f" | tr -d ' ')
    if [ "$size" -gt 102400 ]; then
        mkdir -p "$ARCHIVE_DIR"
        local archive="$ARCHIVE_DIR/$(basename "$f" .log)-$(date +%Y%m%d-%H%M).log"
        cp "$f" "$archive" 2>/dev/null || true
        tail -"$keep" "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
        log "$(basename "$f") rotated (was ${size}B, archived to $(basename "$archive"), kept last $keep lines)"
    else
        log "$(basename "$f") OK (${size}B, under 100KB threshold)"
    fi
}

log "=== Cleanup started ==="

# 1. Rotate EVERY log in the state dir (100 KB cap, keep last 200 lines).
#    Before W5.3 only actions.log, .healing.log and .audit.log were
#    rotated; .sleep_manager.log (2.05 MB) and .enforce.log (1.71 MB)
#    grew unbounded, as did .guardian.log, maintenance.log and .arm_log.
for f in \
    "$DASH/actions.log" \
    "$DASH/.sleep_manager.log" \
    "$DASH/.enforce.log" \
    "$DASH/.guardian.log" \
    "$DASH/maintenance.log" \
    "$DASH/.arm_log" \
    "$DASH/.audit.log" \
    "$DASH/.healing.log" \
    "$DASH/.hygiene.log" \
    "$DASH/.sleep_analysis.log" \
    "$DASH/.watchdog.log" \
    "$DASH/powerwatch.log" \
    "$DASH/powerwatch.err" \
    "$DASH/bc-limit-daemon.log" \
    "$DASH/discharge.log" \
    "$DASH/calibration.log" \
    "$DASH/.watchdog.out" \
    "$DASH/.watchdog.err" \
    "$DASH/.watchdog_sentinel.log" \
    "$DASH/verdicts.jsonl" \
    "$BC_BUILD_DIR/limit.log" \
    "$BC_BUILD_DIR/bc-limit-daemon.log" \
    ; do
    rotate_log "$f" 200
done
# (.watchdog_sentinel.log and verdicts.jsonl added 2026-11-14,
# hardening seed 6: both were produced but never rotated.
# verification/episodes.jsonl carries its own 100 KB rotation from
# the verification design, so it stays out of this list.)

# 2. reports/ archives - delete > 30 days. Archives are named
# "<basename>-YYYYMMDD-HHMM.log" (rotate_log step 1); the old
# "actions-*.log" pattern left every other log's archives unpruned.
if [ -d "$ARCHIVE_DIR" ]; then
    COUNT=$(find "$ARCHIVE_DIR" -type f -name "*-20[0-9][0-9][0-9][0-9][0-9][0-9]-*.log" -mtime +30 2>/dev/null | wc -l | tr -d ' ')
    find "$ARCHIVE_DIR" -type f -name "*-20[0-9][0-9][0-9][0-9][0-9][0-9]-*.log" -mtime +30 -delete 2>/dev/null
    log "Archive: removed $COUNT files > 30 days"
fi

# 2b. Orphaned temp files in the state dir (added 2026-11-14,
#     hardening seed 6): atomic_write and log rotation leave
#     "<file>.tmp.<pid>" behind when a process dies mid-write (one
#     such orphan, bc-limit-daemon.log.tmp.75302, sat here from
#     05:14). Anything *.tmp.* untouched for > 24 h is definitionally
#     orphaned — live writers finish in seconds. Fresh temp files
#     are never touched.
TMP_N=0
for f in "$DASH"/*.tmp.*; do
    [ -f "$f" ] || continue
    if [ -n "$(find "$f" -mtime +0 -print 2>/dev/null)" ]; then
        rm -f "$f" 2>/dev/null && TMP_N=$((TMP_N+1))
    fi
done
[ "$TMP_N" -gt 0 ] && log "Orphaned temp files: removed $TMP_N files > 24h"

# 3. /tmp/battopt_* and /tmp/battery-commander_* - delete > 24 hours
#    (both patterns: transition-safe while the rebrand completes)
for pattern in "battopt_*" "battery-commander_*"; do
    COUNT=$(find /tmp -maxdepth 1 -name "$pattern" -mtime +1 2>/dev/null | wc -l | tr -d ' ')
    find /tmp -maxdepth 1 -name "$pattern" -mtime +1 -delete 2>/dev/null
    [ "$COUNT" -gt 0 ] && log "Tmp ($pattern): removed $COUNT files > 24h"
done

# 4. .notify/ - delete > 48 hours. EXCEPT hold_reached_session: the
# plugin owns its lifecycle (once-per-hold-session dedup); deleting it
# re-arms the "Battery at Limit" notification (audit 2026-11-11, M1).
NOTIFY="$DASH/.notify"
if [ -d "$NOTIFY" ]; then
    COUNT=$(find "$NOTIFY" -type f -mtime +2 ! -name "hold_reached_session" 2>/dev/null | wc -l | tr -d ' ')
    find "$NOTIFY" -type f -mtime +2 ! -name "hold_reached_session" -delete 2>/dev/null
    log "Notify: removed $COUNT files > 48h"
fi

# 5. .guard_alerts/ - delete > 7 days
GUARD="$DASH/.guard_alerts"
if [ -d "$GUARD" ]; then
    COUNT=$(find "$GUARD" -type f -mtime +7 2>/dev/null | wc -l | tr -d ' ')
    find "$GUARD" -type f -mtime +7 -delete 2>/dev/null
    log "Guard: removed $COUNT files > 7 days"
fi

# 6. Keep .cleanup.log under 50 KB
if [ -f "$CLEANUP_LOG" ]; then
    SIZE=$(wc -c < "$CLEANUP_LOG" | tr -d ' ')
    if [ "$SIZE" -gt 51200 ]; then
        tail -100 "$CLEANUP_LOG" > "$CLEANUP_LOG.tmp.$$" && mv "$CLEANUP_LOG.tmp.$$" "$CLEANUP_LOG"
        log "cleanup.log trimmed"
    fi
fi

# 7. Clear .armed_for_sleep if past sleep hours
FLAG="$DASH/.armed_for_sleep"
if [ -f "$FLAG" ]; then
    H=$(date +%H)
    if [ "$H" -ge 9 ] && [ "$H" -lt 22 ]; then
        rm -f "$FLAG"
        log "Cleared .armed_for_sleep flag"
    fi
fi

# 8. Reports - delete > 30 days
REPORTS_DIR="$DASH/reports"
if [ -d "$REPORTS_DIR" ]; then
    COUNT=$(find "$REPORTS_DIR" -type f \( -name "morning-*.txt" -o -name "*.baseline" \) -mtime +30 2>/dev/null | wc -l | tr -d ' ')
    find "$REPORTS_DIR" -type f \( -name "morning-*.txt" -o -name "*.baseline" \) -mtime +30 -delete 2>/dev/null
    log "Reports: removed $COUNT files > 30 days"

    # Keep only latest 7 morning reports
    ls -t "$REPORTS_DIR"/morning-*.txt 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null || true
fi

# 9. /tmp/battopt extras - delete > 7 days (both name patterns)
for pattern in "battopt_health_*.txt" "battopt_heat_*.txt" "battopt_conflicts_*.txt" "battopt_sleep_report_*.txt" "battopt_recovery_*.txt" "battery-commander_health_*.txt" "battery-commander_conflicts_*.txt" "battery-commander_sleep_report_*.txt" "battery-commander_recovery_*.txt"; do
    COUNT=$(find /tmp -maxdepth 1 -name "$pattern" -mtime +7 2>/dev/null | wc -l | tr -d ' ')
    find /tmp -maxdepth 1 -name "$pattern" -mtime +7 -delete 2>/dev/null
    [ "$COUNT" -gt 0 ] && log "Tmp ($pattern): removed $COUNT files"
done

# 10. .bak purge - MANUAL ONLY, two gates. The daily 3 AM run never
#     reaches this: it requires the argument `purge-bak` AND the flag
#     file .bak_purge_approved (created only after Yousef approves the
#     list in bak-removal-list.md). Policy: keep the latest 3 per file,
#     purge the rest only if older than 30 days.
if [ "${1:-}" = "purge-bak" ]; then
    if [ ! -f "$DASH/.bak_purge_approved" ]; then
        log "purge-bak REFUSED: .bak_purge_approved flag file is absent (user approval required)"
        echo "purge-bak refused: .bak_purge_approved flag file is absent" >&2
    else
        log "purge-bak approved: applying policy (latest 3 per file, purge > 30 days)"
        for base in $(find "$DASH" -maxdepth 1 -name "*.bak*" -exec basename {} \; 2>/dev/null | sed -E 's/\.bak.*//' | sort -u); do
            # Newest 3 first; delete the rest only if older than 30 days.
            ls -t "$DASH"/"$base".bak* 2>/dev/null | tail -n +4 | while read -r f; do
                if [ -n "$(find "$f" -mtime +30 2>/dev/null)" ]; then
                    rm -f "$f"
                    log "purge-bak: removed $(basename "$f")"
                else
                    log "purge-bak: kept $(basename "$f") (under 30 days)"
                fi
            done
        done
        log "purge-bak done"
    fi
fi

log "=== Cleanup completed ==="
exit 0


