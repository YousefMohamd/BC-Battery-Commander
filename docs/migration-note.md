# State-dir migration — REAL run (deploy step)

**Date:** 2026-11-10 17:50:57 EET. **Status: MIGRATION COMPLETE.**
Yousef approved the real migration and was present. Script exit 0
(456 ms), `copied=25 skipped-identical=0 failed=0`. Nothing else went
live in this task: no agent/daemon install or load, no deletions, no
sudo, no Phase C, no live battery test, no commit/push.

## 1. What was migrated

`~/.battopt-swiftbar/` → `~/.battery-commander/` (25 files). Script:
`src/migrate-state-dir.sh` (4,056 B, mode `-rwxr-xr-x` — step 0 chmod
was already done, no re-chmod needed). Plan:
`battopt-project/bc-build/state-dir-migration-plan.md`.

- **Top-level state (8):** config, .active_mode, .sleep_profile,
  .power_saver, .sailing_state, .sailing_history, .apg_state,
  .maint_alerted.
- **.notify/ (4):** hold_reached, .daily_20261108, .daily_20261109,
  .daily_20261110.
- **icons/ (13):** README.markdown, battopt.icns, battopt.png,
  charging.png, charging22.png, charging44.png, discharging.png,
  discharging22.png, discharging44.png, electric.png, electric22.png,
  electric44.png, tn.zip.

New dir holds 26 files total: the 25 migrated + `.migration_receipt`.

## 2. md5 verification — 25/25 identical (old → new)

| File | md5 |
|---|---|
| config | 07be808a4000b7bb77fa6669be853421 |
| .active_mode | 0ee2cdecd2d9ca288274eecdd87bd56c |
| .sleep_profile | 4c6c484da64ee7b51ad99ffb75575005 |
| .power_saver | c8cf6eea8f096ed51160b484d97c5bbd |
| .sailing_state | 2491708a429c26df4bebca62270620c5 |
| .sailing_history | 079400eaf9d1d4e4eac34fb7eb1121a0 |
| .apg_state | 4b5f940728b232b034e4e50555ba4046 |
| .maint_alerted | 7c0f7f30fe288d8551865eedb1bfeead |
| .notify/hold_reached | 361f4e3bc031bf80e813db7e8998e291 |
| .notify/.daily_20261108 | c62853461a830040ebd32ccb184d3b8e |
| .notify/.daily_20261109 | c62853461a830040ebd32ccb184d3b8e |
| .notify/.daily_20261110 | c62853461a830040ebd32ccb184d3b8e |
| icons/README.markdown | ed8185561390b1c64c10868e7c694879 |
| icons/battopt.icns | 2d8d334a669ce5cd36930a2c180ecf9b |
| icons/battopt.png | 4b36fbc42a277dc521e06a99b13f585c |
| icons/charging.png | 48282599e973eb2c8ffb87fe52db68c2 |
| icons/charging22.png | 3d3a3235a747a13104cd64569a7457d6 |
| icons/charging44.png | e69b0b4782a1fd600d186d9283d970d7 |
| icons/discharging.png | 108920801b223f01a486bbbf6efa2cbc |
| icons/discharging22.png | 57a4c08f8ab42caed7c29d64afac5422 |
| icons/discharging44.png | 0f19559ce31dd9ecd6a7afd972a6156e |
| icons/electric.png | b050f768666cfc9f984a370051eb1af8 |
| icons/electric22.png | b947c85c47cd94226e12674611226a37 |
| icons/electric44.png | 4c1e537e2ef856f1af6a1990112cdcf6 |
| icons/tn.zip | f1e9d1e40b26e886b7f1063f101bc539 |

## 3. Old dir untouched — proof

- md5s of the 8 sample files identical before/after the run (config
  07be808a…, .active_mode 0ee2cdec…, .sleep_profile 4c6c484d…,
  .power_saver c8cf6eea…, .sailing_state 2491708a…, .sailing_history
  079400ea…, .apg_state 4b5f9407…, .maint_alerted 7c0f7f30…).
- Old-dir entry count unchanged: 95 before, 95 after.
- Note: `.sailing_state` md5 differs from the 17:40 dry-run value
  (380cc377… → 2491708a…) — the live old system updated it between
  the dry-run and this run. The pre-run baseline recorded at 17:50
  was used for this verification, and the post-run value matches it.

## 4. Receipt

`~/.battery-commander/.migration_receipt`:
```
migration: /Users/Yousef/.battopt-swiftbar -> /Users/Yousef/.battery-commander
date: 2026-11-10 17:50:57 EET
copied=25 skipped-identical=0 failed=0
old dir kept untouched — delete it only after the new setup is verified
```

## 5. Config + .power_saver

- New-dir config is canonical:
  `LAST_UPPER=86 LAST_LOWER=85 SAILING=false SAIL_GAP=1`.
- Migrated `.power_saver` is user-owned (`-rw-r--r-- 1 Yousef staff`,
  7 B) — the W5 root-ownership flag is fixed for the new dir by the
  migration itself. Its value is unchanged (md5 c8cf6eea… matches the
  old dir); the flag's value was NOT changed.

## 6. Verdict: MIGRATION COMPLETE

All 25 files copied and md5-verified, old dir untouched, receipt
written, config canonical, `.power_saver` user-owned. The new dir is
now the live one (BC scripts resolve DASH to it first, with fallback
to the old dir). The old battopt system keeps running off the old
dir — nothing live changed.

Next deploy steps (NOT done here): verify-install.sh against the new
dir + plugin smoke test; install watchdog + powerwatch agents +
bc-limit daemon (Yousef's sudo steps, @HOME@ substitution); disable
the 3 old com.battopt.* agents; sudoers verification (decision 8);
dead-file removal at deploy (approved 17:46 EET — .baks purge
Nov 13–14); Phase C (rejected unless necessary). Delete the old dir
only after a full day of normal use on the new dir, and only with
Yousef's explicit approval.
