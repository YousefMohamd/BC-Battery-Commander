# State-dir migration plan — `~/.battopt-swiftbar/` → `~/.battery-commander/`

W6.3. Approved 2026-11-09 01:07 EET (decision 1 of 6). **Deploy step,
user present. Nothing in this plan runs in W6.**

## Why

The tool is renamed Battery Commander. Every BC script resolves the state
dir with the same fallback block (W6.3): `~/.battery-commander/` if it
exists, else `~/.battopt-swiftbar/`. The migration makes the new dir the
live one; the fallback keeps everything working until it runs.

## What migrates (script: `src/migrate-state-dir.sh`)

State files only — copied with `cp -p`, each verified with `cmp`
after the copy, receipt at `~/.battery-commander/.migration_receipt`:

- **Top-level state:** `config`, `.active_mode`, `.active_token`,
  `.sleep_mode`, `.current_power_mode`, `.sleep_profile`, `.power_saver`,
  `.sailing_state`, `.sailing_history`, `.apg_state`, `.apg_paused`,
  `.charge_target`, `.hold_override`, `.hold_token`, `.pre_hold_config`,
  `.enforce_state`, `.drift_state`, `.last_wake`, `.daemon_check_state`,
  `.enforce_last_discharge`, `.maint_alerted`, `.user_shutdown`.
- **Directories (files only):** `.notify/`, `.guard_alerts/`, `icons/`,
  `disabled/` (the parked plugin, if a shutdown-park is in effect).
  Dotfiles are included (`.daily_*` notification-cap markers in
  `.notify/`) — the script sets `shopt -s dotglob` around the directory
  loop (fix 2026-11-10; without it the markers were missed and the daily
  notification cap would reset on migration day).

## What does NOT migrate

- `.sd_session` — legacy/stale (BC v1 never creates it; W6.4).
- Orphaned state: `.sentinel.*`, `.7day_test_start`, `.native.lock`,
  `.charging_guard_cooldown` (W5 removal list).
- Caches (`.status_cache`, `.wake_cache`, `.usb_cache`, `.ac_cache`) —
  recreated on demand. `.throttle_*` — dead. `*.log`, `*.bak` — logs and
  backups stay in the old dir; fresh logs start in the new dir.
- Scripts, `powerwatch`, `bc-*` binaries, `src/` — the state dir's copies
  are old; scripts deploy from the repo, never from the state dir.

## Side effect (good)

`.power_saver` is root-owned in the old dir (W5 flag — needs
`sudo chown Yousef:staff` to fix). The migrated copy is created by the
user running the script, so it is **user-owned in the new dir** — the
flag is fixed for the new dir by the migration itself. The old
root-owned file stays in the old dir and is deleted with it.

## Deploy order

0. **Make the script executable (once):** `chmod +x src/migrate-state-dir.sh`
   — File API transfers strip the exec bit, so the `./src/...` commands
   below fail with `Permission denied` (exit 126) until this runs.
1. **Dry-run first:** `./src/migrate-state-dir.sh --dry-run` — read the
   "would copy" list, confirm nothing unexpected.
2. **Run it:** `./src/migrate-state-dir.sh` — exit 0, receipt written.
3. **Verify the new dir:** `ls -la ~/.battery-commander/` (config present,
   `LAST_UPPER=86 LAST_LOWER=85`); `diff` a few files against the old dir;
   run `src/verify-install.sh` (it resolves DASH to the new dir).
4. **Smoke-test the menu:** the plugin renders from the new dir
   (actions.log in the new dir gets entries).
5. **Only after steps 3–4 pass:** install the watchdog + powerwatch user
   agents and the bc-limit daemon (they all point at the new dir).
6. **Only after a full day of normal use on the new dir:** delete the old
   dir — and only with Yousef's explicit approval (deletion is Red).

## Rollback

- **Before step 5:** delete `~/.battery-commander/` — every script falls
  back to `~/.battopt-swiftbar/` automatically. No other change needed.
- **After step 5:** unload the agents/daemon first, then delete the new
  dir (same fallback). The old dir was never modified, so the old setup
  is intact.
- The migration script is **idempotent**: re-running it skips files that
  are already identical (`cmp`) and only copies what changed.

## Verification checklist (at deploy)

- [ ] `--dry-run` output reviewed, no unexpected files.
- [ ] Exit 0, receipt exists, `copied=N skipped=M failed=0`.
- [ ] `~/.battery-commander/config` reads 86/85, SAILING=false, SAIL_GAP=1.
- [ ] `cmp` spot-checks pass (config, .active_mode, .sleep_mode).
- [ ] `verify-install.sh` passes against the new dir.
- [ ] Plugin renders; actions.log grows in the new dir.
- [ ] Old dir untouched (`ls -la ~/.battopt-swiftbar/` unchanged).
