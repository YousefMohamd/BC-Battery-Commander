# State-dir migration DRY-RUN note — live state dir

**Date:** 2026-11-10 17:35 EET. **Verdict: CONDITIONAL GO** — the migration
content is correct and safe, but two small fixes must land first (§4).
DRY-RUN ONLY: nothing was copied, created, or changed (proof in §3).
The real migration is still a deploy step, Yousef present — NOT run here.

## 1. What the dry-run would copy (22 files, exit 0, failed=0)

- **Top-level state (8):** `config`, `.active_mode`, `.sleep_profile`,
  `.power_saver`, `.sailing_state`, `.sailing_history`, `.apg_state`,
  `.maint_alerted`.
- **`.notify/` (1):** `hold_reached`.
- **`icons/` (13):** `README.markdown`, `battopt.icns`, `battopt.png`,
  `charging.png`, `charging22.png`, `charging44.png`, `discharging.png`,
  `discharging22.png`, `discharging44.png`, `electric.png`, `electric22.png`,
  `electric44.png`, `tn.zip`.

Full output: `state-dir-migration-dryrun-2026-11-10.log` (Mac copy in
`battopt-project/bc-build/`, 2,853 B, md5 `a1307b66…`; local copy identical).

Config is canonical: `LAST_UPPER=86 LAST_LOWER=85 SAILING=false SAIL_GAP=1`.

## 2. What would NOT be copied — all correct, except one item (§4.2)

- **Absent from the old dir (correctly not copied):** `.active_token`,
  `.sleep_mode`, `.current_power_mode`, `.charge_target`, `.hold_override`,
  `.hold_token`, `.pre_hold_config`, `.enforce_state`, `.drift_state`,
  `.last_wake` (powerwatch agent not installed yet), `.daemon_check_state`,
  `.enforce_last_discharge`, `.user_shutdown`, `.apg_paused`, `.sd_session`.
- **Empty dirs (nothing to copy):** `.guard_alerts/` (0 files),
  `disabled/` (0 files — no shutdown-park in effect).
- **Present, correctly excluded per plan:** orphaned state (`.7day_test_start`,
  `.native.lock`, `.charging_guard_cooldown`, `.sentinel.*`), caches
  (`.status_cache`, `.wake_cache`, `.usb_cache`, `.ac_cache`), `*.log`,
  `*.bak`, scripts / `powerwatch` / `bc-*` binaries, `.DS_Store`.
- **`icons/` subdirectories (skipped, non-files — verified harmless):**
  `icon.iconset/` (old battopt iconset build artifact) and
  `terminal-notifier.app/` — the new BC stack resolves terminal-notifier
  from `/Applications/terminal-notifier.app/...` (grep-verified in plugin,
  dispatch, watchdog, launcher), never from the state dir. Safe to skip.
- **Old `battopt.*` icon filenames ARE copied** (`icons/battopt.icns`,
  `icons/battopt.png`) — cosmetic only; the plugin reads the charging /
  discharging / electric PNGs from this dir, so copying them keeps the menu
  icons working. Same cosmetic flag as W6 (`icons/battopt.png` filename).

## 3. Proof nothing was written

- `~/.battery-commander` did NOT exist before and still does NOT exist after.
- md5 of 8 sample files (config, .active_mode, .power_saver,
  .sailing_state, .sleep_profile, .maint_alerted, .sailing_history,
  .apg_state) identical before and after the dry-run.
- The only write in this task was the dry-run log file in `bc-build/`.

## 4. Findings — fix before the real migration

1. **Script is not executable (invocation):** `src/migrate-state-dir.sh` is
   mode `-rw-r--r--` (File API transfer artifact). The plan's
   `./src/migrate-state-dir.sh --dry-run` fails with `Permission denied`,
   exit 126. The dry-run was executed as `bash src/migrate-state-dir.sh
   --dry-run` instead (same script, no state change). At deploy, either
   `chmod +x src/migrate-state-dir.sh` or invoke via `bash` — update the
   plan's command accordingly.
2. **Dotfile glob miss (script bug, minor):** the DIRS loop uses
   `"$OLD_DIR/$_d"/*`, which never matches dotfiles. `.notify/` holds
   `.daily_20261108`, `.daily_20261109`, `.daily_20261110` (daily
   notification-cap markers, 39 B each) — only `hold_reached` would
   migrate. Effect if un-fixed: the daily notification cap resets on
   migration day (up to 3 notifications could fire that day even if some
   already fired); self-heals the next day. No other dir is affected
   (`.guard_alerts/` and `disabled/` are empty; `icons/` has no dotfiles).
   Fix: `shopt -s dotglob` in the DIRS loop (or iterate `.*` too), then
   re-run the dry-run to confirm `copied=25`.

## 5. Verdict

**CONDITIONAL GO.** The 22 files are exactly per plan, config is canonical,
nothing unexpected would be copied, and the dry-run proved zero writes.
Run the real migration only after fixing §4.1 (invocation) and §4.2
(dotglob, or explicitly accept the one-day cap reset). Old dir stays
untouched either way; rollback is deleting the new dir.
