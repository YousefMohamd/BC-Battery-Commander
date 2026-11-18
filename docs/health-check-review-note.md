# Battery Commander Health Check — review (2026-11-10)

**Trigger:** Yousef pasted the health check report (2026-11-10 20:20:00, PASS 14 / FAIL 2 / WARN 3) and said "راجع المهام دي" (review these tasks).
**Result:** Both FAILs were false alarms (script bugs / stale expectations), both fixed. Re-run 20:24:44: **PASS 16 | FAIL 0 | WARN 3 — "Project is HEALTHY".**

## 1. FAIL 1 — "Battery Commander.app exists (got: no, expected: yes)" — FALSE ALARM, script bug

**Root cause:** The check tested the wrong path. `project_health.sh` (repo + deployed):
```sh
check "Battery Commander.app exists" \
    "$([ -d "/Applications/Battery Commander.app" ] || [ -d /Applications/BattOpt.app ] && echo yes || echo no)" "yes"
```
- The installed bundle is `/Applications/BatteryCommander.app` (**no space**) — verified present (`drwxr-xr-x`, Nov 10 16:12, .icns bf88d95d…, launcher running PID 7952).
- The check looked for `/Applications/Battery Commander.app` (**with a space**) — which never existed.
- The fallback `/Applications/BattOpt.app` is gone (moved to backup 18:49 EET, deleted to trash 20:18 EET), so the check had nothing left to find.
- The check only ever passed because of the BattOpt.app fallback; once the old app was deleted, the bug surfaced.

**Fix** (backed up to `battopt-project/bc-build/project_health.sh.pre-healthcheck-fix`, md5 d40bae16… = pre-fix deployed copy):
```sh
# BC app bundle is "BatteryCommander.app" (no space) — the old
# "Battery Commander.app" (with space) never existed; the old
# BattOpt.app fallback is gone (deleted 2026-11-10).
check "Battery Commander.app exists" \
    "$([ -d "/Applications/BatteryCommander.app" ] && echo yes || echo no)" "yes"
```
**Verified:** re-run shows ✅ PASS: Battery Commander.app exists.

## 2. FAIL 2 — "standbydelay (Bat=600, profile=active_ac) — expected 900/300/3600" — FALSE ALARM, stale expectations

**Root cause:** The check's expected values were from before W4.3. The old logic branched on `.sleep_profile`:
- travel → 14400, long_battery → 3600, active_battery → 300, else → 900/300/3600.
- W4.3 REMOVED the long/travel profiles (approved decision 5). `power_saver.sh` now has exactly ONE profile — `default`:
  - battery: standbydelayhigh 600 / standbydelaylow 600 / autopoweroffdelay 1800
  - AC: standbydelayhigh 10800 / standbydelaylow 10800 / autopoweroffdelay 3600, sleep 90
  - any unknown profile name falls back to default (never fails silently).
- Actual `pmset -g custom` (read-only, 20:23 EET) matches the default profile exactly:
  - Battery Power: standbydelayhigh 600, standbydelaylow 600, autopoweroffdelay 1800, sleep 18
  - AC Power: standbydelayhigh 10800, standbydelaylow 10800, autopoweroffdelay 3600, sleep 90
  - `.power_saver` = ENABLED.
- `.sleep_profile` = `active_ac` (correct, current: EXT=Yes, Clamshell=No). `sleep_manager.sh` (Layer 13) only RECORDS the profile name — it does not apply pmset (MAPPED_PROFILE is computed but unused). `.sleep_mode` does not exist (SM_STATE defaults to "default"); the travel branch was dead.
- So STANDBY_BAT = 600 is CORRECT; the check's 900/300/3600 were stale. This was the known flag: "project_health standbydelay expectations still reference the removed long/travel profiles".

**Fix** (same backup, same script):
```sh
# Expected: 600 (W4.3 default profile — long/travel removed, only
# "default" exists in power_saver.sh; battery standbydelaylow is
# always 600. sleep_manager (Layer 13) only RECORDS the profile
# name in .sleep_profile — it does not apply pmset. The old
# expectations (900/300/3600, travel 14400, long_battery 3600,
# active_battery 300) were stale and caused a false FAIL.)
check "standbydelay (Bat=$STANDBY_BAT, profile=$LAYER13_PROFILE)" "$STANDBY_BAT" "600"
```
(The dead `SM_STATE`/travel branch was removed with it; LAYER13_PROFILE is still read and shown in the check label.)
**Verified:** re-run shows ✅ PASS: standbydelay (Bat=600, profile=active_ac).

**Note:** No pmset settings were changed (that is a Red action). The actual values were already correct; only the check's expectations were fixed. If Yousef later defines distinct profile values, the expectation (600) will need updating then.

## 3. The 3 WARNs — reviewed, no action needed

- **(a) Enforcer daemon not loaded (Phase C gate) — EXPECTED.** The bc-limit daemon is deliberately not loaded (Phase C gate, rejected unless necessary). The script warns (not a FAIL) by design. No action.
- **(b) Load = 3.65 (20:20) → 4.24 (20:24) — NOT BC.** `top` at 20:23: CPU 6.85% user, 12.15% sys, **80.98% idle**; load avg {3.02, 4.09, 4.32}; 584 processes, 3539 threads, 1 stuck. Top CPU processes all 0.0% at sample time. BC processes: SwiftBar PID 1998 (0.0% CPU, 22 MB), powerwatch PID 44060 (0.0% CPU, 580 KB). The load is the user's workload + system I/O, not BC. No action, do not kill anything.
- **(c) Swap = 8027.50 MB (20:20) → 8311.25 MB (20:24) — NOT BC.** `memory_pressure`: system-wide memory free 72%; `vm_stat`: 16 GB RAM (15G used, 770M unused), 6.36M pages in compressor. The memory hog is **Krita PID 97566 — 8423M resident (7707M compressed)** — Yousef's artwork app (RliBook), plus Firefox plugin-container (403M). BC uses ~22 MB (SwiftBar) + 580 KB (powerwatch). The swap is the user's workload, not BC. The check's 2000 MB threshold is low for a 16 GB Mac running Krita. No action.

## 4. Root helpers verification (Yousef's sudo rm, 20:20 EET)

`ls -l /usr/local/bin/battopt-*` → only one entry remains:
- `-rwxr-xr-x 1 root admin 223 Oct 16 16:07 /usr/local/bin/battopt-trial-renew.bak-20261016-1607`
- **The 8 root helpers are GONE** (battopt-daemon-start/stop/restart, battopt-powerwatch-start/stop, battopt-release-cfg, battopt-restore-cfg, battopt-trial-renew) — Yousef's sudo rm worked, no errors.
- Leftover (not one of the 8): `battopt-trial-renew.bak-20261016-1607` (223 B, root-owned, Oct 16) — a backup of the dead trial-renew helper. Removing it needs sudo (Yousef's step if he wants it gone). Not deleted here.

## 5. Verification of the fixes

- Edit script: `battopt-project/bc-build/healthcheck_fix.py` (local copy `~/workspace/bc-build/healthcheck_fix.py`) — both replacements verified by exact count (1 each) before writing; backup `project_health.sh.pre-healthcheck-fix` (md5 d40bae16… = pre-fix copy).
- `bash -n` OK on the edited file.
- Redeployed via re-runnable `deploy-populate.sh`: FAIL=0; repo md5 = deployed md5 = `9d364a524fb2c1346f3e560e176fa40e` (9,426 B, down from 9,774 B — dead branches removed).
- Re-run health check (deployed copy, 2026-11-10 20:24:44): **PASS 16 | FAIL 0 | WARN 3 — "Project is HEALTHY"**.
  - Both former FAILs now PASS. The 3 WARNs are the same as before (enforcer/Phase C expected; Load/Swap from the user's workload).

## 6. Open items (for the parent agent)

- The leftover `battopt-trial-renew.bak-20261016-1607` in /usr/local/bin (root-owned, 223 B) — Yousef sudo step if he wants it removed (`sudo rm /usr/local/bin/battopt-trial-renew.bak-20261016-1607`).
- The 7 repo copies of root helpers in `src/daemon-helpers/` need a removal decision (offered to Yousef 20:19 EET, option widget pending).
- The 17 dispatch.sh `.bak`s purge only Nov 13–14 (30-day rule).
- Phase C (bc-limit daemon load + full-cycle test) — still rejected unless necessary; needs its own approval.
- Note: the first transfer.py call used a relative remote path and failed HTTP 403 (path outside allowedRoots — it resolved under /Users/Yousef/muse-fileapi/); the absolute remote path worked. transfer.py requires an absolute remote path.
