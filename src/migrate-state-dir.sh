#!/bin/bash
# migrate-state-dir.sh — state-dir rename migration (W6.3, approved 2026-11-09).
#
# Copies state files from ~/.battopt-swiftbar/ to ~/.battery-commander/.
# IDEMPOTENT: safe to re-run (files already identical are skipped).
# NEVER deletes the old dir — it stays untouched until the new setup is
# verified (see battopt-project/bc-build/state-dir-migration-plan.md).
# Deploy step, user present. The assistant never runs this.
#
# Usage: ./src/migrate-state-dir.sh [--dry-run]
# Exit 0 = migrated (or already migrated) and verified, 1 = error.
set -u

OLD_DIR="$HOME/.battopt-swiftbar"
NEW_DIR="$HOME/.battery-commander"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

COPIED=0
SKIPPED=0
FAILED=0

log() { echo "migrate: $*"; }

# State files (top level). NOT migrated on purpose:
#   .sd_session (legacy/stale — BC v1 never creates it, W6.4),
#   .sentinel.* / .7day_test_start / .native.lock /
#   .charging_guard_cooldown (orphaned state, W5 removal list),
#   .status_cache / .wake_cache / .usb_cache / .ac_cache (caches,
#   recreated), .throttle_* (dead), *.log / *.bak (logs and backups
#   stay in the old dir; fresh logs start in the new dir),
#   *.sh / powerwatch / bc-* binaries (scripts live in the repo,
#   deployed from there — never copied from the state dir).
FILES="config .active_mode .active_token .sleep_mode .current_power_mode
.sleep_profile .power_saver .sailing_state .sailing_history .apg_state
.apg_paused .charge_target .hold_override .hold_token .pre_hold_config
.enforce_state .drift_state .last_wake .daemon_check_state
.enforce_last_discharge .maint_alerted .user_shutdown"

# Whole directories (if present). NOT migrated: disabled/ holds the
# PARKED PLUGIN (battery-commander.10s.sh) — copied so a shutdown-park
# survives the migration; scripts/ and src/ inside the state dir are
# old copies, NOT migrated.
DIRS=".notify .guard_alerts icons disabled"

if [ ! -d "$OLD_DIR" ]; then
    log "old dir $OLD_DIR does not exist — nothing to migrate"
    exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
    log "DRY RUN — nothing will be copied"
else
    mkdir -p "$NEW_DIR" || { log "cannot create $NEW_DIR"; exit 1; }
fi

copy_one() {
    local _src="$1" _dst="$2"
    if [ ! -e "$_src" ]; then
        return 0
    fi
    if [ -e "$_dst" ] && cmp -s "$_src" "$_dst"; then
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log "would copy $_src -> $_dst"
        COPIED=$((COPIED + 1))
        return 0
    fi
    mkdir -p "$(dirname "$_dst")"
    if cp -p "$_src" "$_dst" && cmp -s "$_src" "$_dst"; then
        COPIED=$((COPIED + 1))
    else
        log "FAILED to copy $_src"
        FAILED=$((FAILED + 1))
    fi
}

for _f in $FILES; do
    copy_one "$OLD_DIR/$_f" "$NEW_DIR/$_f"
done

# dotglob: the glob in the DIRS loop must also match dotfiles
# (.daily_* notification-cap markers in .notify/) — scoped: set
# before the loop, restored right after.
shopt -s dotglob
for _d in $DIRS; do
    if [ -d "$OLD_DIR/$_d" ]; then
        # Copy the directory tree (files only — no recursion into
        # scripts/ or src/ inside these dirs; they hold flat state).
        for _src in "$OLD_DIR/$_d"/*; do
            [ -e "$_src" ] || continue
            [ -f "$_src" ] || continue
            copy_one "$_src" "$NEW_DIR/$_d/$(basename "$_src")"
        done
    fi
done
shopt -u dotglob

log "copied=$COPIED skipped-identical=$SKIPPED failed=$FAILED"
if [ "$FAILED" -gt 0 ]; then
    log "migration FAILED — old dir untouched, fix the errors and re-run"
    exit 1
fi

if [ "$DRY_RUN" = "0" ]; then
    {
        echo "migration: $OLD_DIR -> $NEW_DIR"
        echo "date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "copied=$COPIED skipped-identical=$SKIPPED failed=$FAILED"
        echo "old dir kept untouched — delete it only after the new setup is verified"
    } > "$NEW_DIR/.migration_receipt"
    log "receipt written to $NEW_DIR/.migration_receipt"
    log "old dir $OLD_DIR kept untouched — verify the new setup first"
fi
exit 0
