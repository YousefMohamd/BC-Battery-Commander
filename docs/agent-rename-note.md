# Agent rename — 13 repointed agents → `com.batterycommander.*`

**Date:** 2026-11-11 (~17:31–17:40 EET). **Status: COMPLETE (13 renamed + improvements + check).**
Yousef approved 2026-11-11 17:26 EET: "ايوه غير اسمائهم وحسن وظيفهم واعمل عليهم اتشيك"
(yes, change their names, improve their functions, and do a check on them).
He observed "in the service agents there are only 3 working" — he saw only the
3 `com.batterycommander.*` agents (watchdog, powerwatch, bclimit); the other 13
were still named `com.battopt.*`. After this rename, all 16 are
`com.batterycommander.*`.

## 1. Rename table (label + filename + /tmp log paths)

All 13: `com.battopt.<name>` → `com.batterycommander.<name>`. ProgramArguments
(pointing at `~/.battery-commander/`) unchanged. StandardOut/Error paths
renamed `/tmp/battopt-*` → `/tmp/batterycommander-*` (6 plists that had them).
All 13 new plists: `plutil -lint` OK. All 13: unload OLD = 0, load NEW = 0,
verified loaded, old label gone. Old plist files moved to `~/.Trash/`
(recoverable); originals backed up (see §4).

| Old label | New label | Script | Interval |
|---|---|---|---|
| com.battopt.acwatcher | com.batterycommander.acwatcher | ac_watcher.sh | 10 s, RunAtLoad |
| com.battopt.hygiene | com.batterycommander.hygiene | state_hygiene.sh | 300 s, RunAtLoad |
| com.battopt.log-cleanup | com.batterycommander.log-cleanup | cleanup_logs.sh | 03:00 daily |
| com.battopt.morning-report | com.batterycommander.morning-report | morning_report.sh | 08:00 daily |
| com.battopt.pmsetcheck | com.batterycommander.pmsetcheck | pmset_check.sh | 10:00 daily |
| com.battopt.predictive | com.batterycommander.predictive | predictive.sh | 3600 s, RunAtLoad |
| com.battopt.process-monitor | com.batterycommander.process-monitor | process_monitor.sh | 300 s, RunAtLoad |
| com.battopt.self-healing | com.batterycommander.self-healing | self_healing.sh | 300 s, RunAtLoad |
| com.battopt.selfmaintenance | com.batterycommander.selfmaintenance | self_maintenance.sh | 300 s, RunAtLoad |
| com.battopt.sleepmanager | com.batterycommander.sleepmanager | sleep_manager.sh | 60 s, RunAtLoad |
| com.battopt.sleepmonitor | com.batterycommander.sleepmonitor | sleep_monitor.sh | 30 s, RunAtLoad false |
| com.battopt.swiftbar-watchdog | com.batterycommander.swiftbar-watchdog | swiftbar_watchdog.sh | 120 s, RunAtLoad |
| com.battopt.wakeanalyzer | com.batterycommander.wakeanalyzer | wake_analyzer.sh | 60 s, RunAtLoad |

NOT renamed / NOT touched: `com.battopt.adaptive-governor` (RETIRED 2026-11-10,
stays retired), the 4 unloaded old plists (guardian, enforce, consolidated,
adaptive-governor) + 4 `.disabled` plists (left in place), `com.batterycommander.watchdog`
+ `com.batterycommander.powerwatch` (already BC names, already loaded),
`com.batterycommander.bclimit` (installed, NOT loaded — Phase C, untouched),
`com.batterycommander.launcher.181732` (the app, untouched).

## 2. Improvements (script fixes)

### (a) swiftbar_watchdog.sh — REWRITTEN (real bug, was the old script)
The deployed copy was the OLD script (Oct 14, 1,157 B, never rewritten in
W4/W6). It wrote to the OLD dir and re-created the old plugin:
- `LOG="$HOME/.battopt-swiftbar/actions.log"` → now `$DASH/actions.log`
  (DASH fallback block, same as the other 12 scripts).
- `.user_shutdown` check, `launch_swiftbar.sh` call, `plugin-backups` dir →
  all now under `$DASH` (new dir).
- DisabledPlugins check `grep -c "battopt"` + `touch "$HOME/SwiftBar/battopt.10s.sh"`
  → now `grep -c "battery-commander"` + `touch "$HOME/SwiftBar/battery-commander.10s.sh"`.
  The old version RE-CREATED an empty `battopt.10s.sh` in `~/SwiftBar/` whenever
  "battopt" appeared in DisabledPlugins (the KEY RISK from the logo
  investigation). Fixed.
- New: 1,685 B, md5 `af32ae70b12fa02d46fc571789e720df` (repo = deployed).
- Known limitation (kept, pre-existing behavior): `defaults delete
  com.ameba.SwiftBar DisabledPlugins` removes the WHOLE array, not just the
  battery-commander entry — so if the user disabled OTHER plugins too, this
  re-enables them as well. Fixing it properly needs PlistBuddy surgery on the
  array (a bigger change); left as-is, noted here.

### (b) sleep_manager.sh — removed long_battery / long_ac (stale, W4.3)
The `long_battery` / `long_ac` profiles were removed in W4.3 (approved
decision 5 — only "default" exists in power_saver.sh), but sleep_manager
still emitted them as profile names (and mapped them to a "long" profile).
Profile is now by power source only: battery → `active_battery`, AC →
`active_ac` (clamshell no longer changes the profile — clamshell dropped,
decision 4). The dead `MAPPED_PROFILE` case (computed, never used) was
removed. The `Clamshell=` value is still logged (diagnostic). sleep_manager
is profiler-only (records `.sleep_profile`, applies NO pmset) — behavior
unchanged.
- Verified live: `.sleep_profile` now reads `active_ac` (was `long_ac` on AC
  + clamshell). The health check's standbydelay line now shows
  `profile=active_ac` and PASSES.
- New: 2,432 B, md5 `07ebf66e9fcb20978fb8f39984883dbb` (repo = deployed).

### (c) self_maintenance.sh — label comment renamed
Line 3: `com.battopt.selfmaintenance` → `com.batterycommander.selfmaintenance`.
New: 4,827 B, md5 `ca7f5adec6b1a8467600a7b29537c760` (repo = deployed).

### (d) NOT changed (checked, correct as-is)
- `self_healing.sh` `VALID_MODES="default presentation download travel"` —
  "travel" is a legitimate SLEEP MODE (dispatch.sh `sleep_mode_travel` writes
  it to `.sleep_mode`), NOT the removed power_saver profile. `power_saver.sh
  apply-delays` falls back to `default` for any unknown profile (logs it),
  so `apply-delays travel` is safe. Left unchanged.
- DASH fallback block (`DASH="$HOME/.battopt-swiftbar"`) in the 12 scripts —
  kept by design (W6.3 safety net; the old dir is being kept as a backup).
  Historical comments mentioning the replacement (e.g. "the one `battopt
  limit` call is replaced…") kept as documentation.
- `BC_BUILD_DIR` path contains `battopt-project` — that is the actual repo
  folder name; renaming the folder is out of scope.

## 3. Check results (2026-11-11 ~17:35–17:40 EET)

- `launchctl list | grep batterycommander`: **all 16 loaded**, zero
  `com.battopt.*` loaded:
  - 13 renamed (acwatcher, hygiene, log-cleanup, morning-report, pmsetcheck,
    predictive, process-monitor, self-healing, selfmaintenance, sleepmanager,
    sleepmonitor, swiftbar-watchdog, wakeanalyzer)
  - watchdog (`-`, 60 s), powerwatch (PID 44060), launcher.181732 (PID 7952).
- `~/Library/LaunchAgents/`: 15 `com.batterycommander.*.plist` files (13
  renamed + powerwatch + watchdog). Remaining `com.battopt.*.plist`: only the
  4 unloaded (adaptive-governor, consolidated, enforce, guardian) + 4
  `.disabled`. The 13 old files are in `~/.Trash/` (recoverable).
- New `/tmp/batterycommander-*` log files are being created (acwatcher, heal,
  hygiene, sleepmgr, wakeanl `.out`/`.err`). Old `/tmp/battopt-*` files still
  exist (stale, from before the rename; cleanup_logs removes old ones).
- Battery: **86.1%**, IsCharging No, ExternalConnected Yes — holding.
  `bc-status` BCLM: 10 (from the watchdog heartbeat; the bc-status head
  output was cut at 12 lines, BCLM is line 13 — the heartbeat confirms
  BCLM=10). Watchdog heartbeats 17:32:40 / 17:33:41 / 17:34:41:
  `PCT=86 BCLM=10 cfg=86/85 NCR=14 EXT=Yes IsChg=No mode=hold APG=yellow backend=bclm`.
- `~/SwiftBar/` contains ONLY `battery-commander.10s.sh` — the old plugin
  was NOT re-created (swiftbar_watchdog fix works).
- `.sleep_profile` = `active_ac` (new sleep_manager working).
  `.ac_state` = `Yes` (ac_watcher running).
- **Health check (project_health.sh, re-run after the rename): PASS 16 |
  FAIL 0 | WARN 3 — "Project is HEALTHY".** The 3 WARNs are the known ones:
  enforcer daemon not loaded (Phase C, expected); Load 3.26 (not BC); Swap
  7758.25 MB (not BC — Krita).
- `bc-limit` daemon: NOT running (Phase C, expected). Plist exists
  (`/Library/LaunchDaemons/com.batterycommander.bclimit.plist`, root wheel,
  2,073 B, Nov 10 18:30).

### (e) project_health.sh — LAUNCHAGENTS section now lists all 15 agents
(Bonus fix, same task — Yousef's "only 3 working" came from this report.)
The section previously looped only over `watchdog powerwatch`, so the report
showed 3 lines. It now loops over all 15 BC agents (13 renamed + watchdog +
powerwatch) and prints each as loaded. Re-ran: all 15 listed as loaded,
still PASS 16 / FAIL 0 / WARN 3. Backup: `project_health.sh.pre-rename`
(9,426 B, md5 `9d364a52…`). New: md5 `3316c47c86234f466f39afe9b699cabe`
(repo = deployed). The `com.batterycommander.watchdog.plist` still contains
one historical "battopt" string (a comment in the plist: "disable the 3 old
com.battopt.* plists at deploy") — harmless, left as-is (the watchdog is
running; its plist was not touched).

## 4. Backups & files

- Plist originals (13): `battopt-project/bc-build/agent-plists-backup-20261111-rename/`
  (Mac) + `~/workspace/bc-build/agent-plists-backup-20261111-rename/` (local),
  all 13 md5-verified (FAIL=0). Helper: `~/workspace/bc-build/download_rename_backup.py`.
- Script backups (Mac): `battopt-project/bc-build/swiftbar_watchdog.sh.pre-rename`
  (1,157 B, md5 `38233d11…`), `sleep_manager.sh.pre-rename` (2,741 B, md5
  `d8359cfd…`), `self_maintenance.sh.pre-rename` (4,818 B, md5 `57885748…`),
  `project_health.sh.pre-rename` (9,426 B, md5 `9d364a52…`).
- Edit scripts (local): `~/workspace/bc-build/rename_fix.py`,
  `~/workspace/bc-build/healthcheck_rename.py`.
- Deploy: `repoint-populate.sh` re-run — FAIL=0 (10 copied + 4 present
  verified, incl. the 3 edited scripts at their new md5s).
- This note: `battopt-project/bc-build/agent-rename-note.md` (Mac) +
  `~/workspace/bc-build/agent-rename-note.md` (local).

## 5. Constraints kept

No sudo. No bc-limit daemon load (Phase C). No commit/push. No live battery
tests. No SMC writes. No pmset changes. No /etc/sudoers.d touch. No login-item
touch. No unload/reload of the old root battopt daemon or the bc-limit daemon.
Unload/reload of the 13 USER agents was authorized by Yousef's approval
(2026-11-11 17:26 EET). GET /info first. Read before writing.
