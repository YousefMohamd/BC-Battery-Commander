# State-dir migration dry-run — fix note (both findings fixed, re-run 2)

**Date:** 2026-11-10. **Status: GO for the real migration** (deploy step,
Yousef present, per the plan). DRY-RUN ONLY in this task — the real
migration was NOT run; nothing went live.

## Background

First dry-run 2026-11-10 17:35 EET: CONDITIONAL GO — exit 0, copied=22,
zero writes proven, config canonical (86/85, SAILING=false). Two findings
were left to fix before the real migration. Both are fixed here, and the
dry-run was re-run to confirm.

## Fix 1 — script not executable

- **Was:** `src/migrate-state-dir.sh` mode `-rw-r--r--` (File API transfer
  artifact). The plan's exact command `./src/migrate-state-dir.sh
  --dry-run` failed with `Permission denied`, exit 126.
- **Fix:** `chmod +x` applied on the Mac via /run (plain chmod, not sudo).
  Mode is now `-rwxr-xr-x`. The plan gained a step 0: run
  `chmod +x src/migrate-state-dir.sh` once before the `./src/...`
  commands (File API transfers strip the exec bit).
- **Verified:** the re-run below used the plan's exact command
  `./src/migrate-state-dir.sh --dry-run` and it ran (exit 0).

## Fix 2 — dotfile glob miss (script bug, minor)

- **Was:** the DIRS loop used `"$OLD_DIR/$_d"/*`, which never matches
  dotfiles. `.notify/` holds `.daily_20261108/09/10` (daily
  notification-cap markers) — only `hold_reached` would have migrated,
  so the daily notification cap would reset on migration day (up to 3
  notifications could fire that day even if some already fired);
  self-heals the next day.
- **Fix:** `shopt -s dotglob` before the DIRS loop, `shopt -u dotglob`
  right after (scoped — no other glob in the script is affected).
  Original backed up to
  `battopt-project/bc-build/migrate-state-dir.sh.pre-dotglob-fix`
  (md5 `567cd032d2b01555fbe00e7592f6d207`, identical to the original).
  Diff backup vs fixed script shows ONLY the 5 added lines (3 comment
  lines + `shopt -s` + `shopt -u`). `bash -n` OK locally and on the Mac.
- **Plan updated:** the "Directories (files only)" section now states
  dotfiles are included (`.daily_*` markers in `.notify/`).

## Re-run result (2026-11-10 17:40 EET, plan's exact command)

- **copied=25, skipped-identical=0, failed=0, dryrun-exit=0.**
- 25 = 22 from run 1 + the 3 `.daily_20261108/09/10` markers, now listed
  as "would copy". No other change to the list.
- Log: `battopt-project/bc-build/state-dir-migration-dryrun-2026-11-10-r2.log`
  (3,261 B, md5 `f5bcaf22d121b0be97af4cf1b2d06686` local↔Mac match).

## Zero-writes proof (after the re-run)

- `~/.battery-commander` still does NOT exist.
- md5s of the 8 sample state files identical before/after the re-run:
  config `07be808a…`, .active_mode `0ee2cdec…`, .sleep_profile
  `4c6c484d…`, .power_saver `c8cf6eea…`, .sailing_state `380cc377…`,
  .sailing_history `079400ea…`, .apg_state `4b5f9407…`, .maint_alerted
  `7c0f7f30…`.

## Verification summary (all md5 local↔Mac)

- `src/migrate-state-dir.sh`: 4,056 B, `85a82e841e37bd35083e588ad5c63f4d`.
- `battopt-project/bc-build/state-dir-migration-plan.md`: 4,403 B,
  `08ab72fbb063806ce9be19ad360502a4`.
- Dry-run log r2: 3,261 B, `f5bcaf22d121b0be97af4cf1b2d06686`.

## Verdict: GO

Both findings are fixed and proven by the re-run (copied=25, failed=0,
zero writes). The real migration is ready to run at deploy, with Yousef
present, dry-run first per the plan. The real migration itself, agent/
daemon install, and Phase C remain gated on Yousef's deploy approvals
(W6 CONDITIONAL PASS blockers).
