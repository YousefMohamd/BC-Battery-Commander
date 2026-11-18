# Agent repoint note — 14 old user agents → `~/.battery-commander/`

**Date:** 2026-11-10 (~18:49–18:53 EET). **Status: COMPLETE (13 repointed + 1 retired).**
Deploy Part 1 flag 3 closed. No sudo, no daemon load (Phase C), no deletions,
no commit/push, no live battery test, no /Applications or login-item change
(parallel task's scope). Old root daemon (PID 88736) untouched; old root
powerwatch already unloaded at activation.

## 1. Per-agent table

Plist backups: `battopt-project/bc-build/agent-plists-backup-20261110/` (Mac) +
`~/workspace/bc-build/agent-plists-backup-20261110/` (local) — all 14 originals,
md5-verified (original = backup). All 13 edited plists: `plutil -lint` OK,
zero `.battopt-swiftbar` remaining (grep check). All 13 reloads: unload=0 load=0.

| Agent (label) | Script | Source | Plist edit | Reload / status |
|---|---|---|---|---|
| com.battopt.morning-report | morning_report.sh | repo 2,315 B, `cf285214…` | → new dir | unload=0 load=0, loaded (`-`, RunAtLoad false, 08:00 daily) |
| com.battopt.hygiene | state_hygiene.sh | repo 9,635 B, `5e1dc862…` | → new dir | unload=0 load=0, loaded (PID 14568) |
| com.battopt.acwatcher | ac_watcher.sh | repo 5,157 B, `e46d0034…` | → new dir | unload=0 load=0, loaded (PID 14571) |
| com.battopt.self-healing | self_healing.sh | already in new dir 7,630 B, `e6839c89…` | → new dir | unload=0 load=0, loaded (PID 14574) |
| com.battopt.process-monitor | process_monitor.sh | already in new dir 2,678 B, `7ae7996a…` | → new dir | unload=0 load=0, loaded (PID 14577) |
| com.battopt.sleepmonitor | sleep_monitor.sh | repo 1,417 B, `aace9b11…` | → new dir | unload=0 load=0, loaded (`-`, RunAtLoad false, 30 s) |
| com.battopt.pmsetcheck | pmset_check.sh | repo 1,442 B, `cc6611fd…` | → new dir | unload=0 load=0, loaded (`-`, RunAtLoad false, 10:00 daily) |
| com.battopt.swiftbar-watchdog | swiftbar_watchdog.sh | repo 1,157 B, `38233d11…` (= live md5) | → new dir | unload=0 load=0, loaded (PID 14584) |
| com.battopt.sleepmanager | sleep_manager.sh | repo 2,741 B, `d8359cfd…` | → new dir | unload=0 load=0, loaded (PID 14587) |
| com.battopt.wakeanalyzer | wake_analyzer.sh | repo 2,642 B, `e1116d26…` | → new dir | unload=0 load=0, loaded (PID 14590) |
| com.battopt.predictive | predictive.sh | already in new dir 3,592 B, `9cecaa09…` | → new dir | unload=0 load=0, loaded (PID 14593) |
| com.battopt.selfmaintenance | self_maintenance.sh | repo 4,818 B, `57885748…` | → new dir (`$HOME` form preserved) | unload=0 load=0, loaded (PID 14596) |
| com.battopt.log-cleanup | cleanup_logs.sh | repo 7,116 B, `554e12bc…` | → new dir | unload=0 load=0, loaded (`-`, RunAtLoad false, 03:00 daily) |
| com.battopt.adaptive-governor | adaptive_governor.sh | **NOT copied** (see §3) | **NOT edited** (backup only) | **RETIRED** — unloaded, not reloaded |

Populate script: `battopt-project/bc-build/repoint-populate.sh` (re-runnable;
10 copied + 4 already-present verified, FAIL=0, all `bash -n` OK, all `+x`).
Note: `adaptive.sh` (1,748 B, already in the new dir from Deploy Part 1) is a
*different* script from `adaptive_governor.sh` (the W0 KEEP "adaptive", never
triggered) — it stays as-is; it is not the governor.

## 2. Flag-3 verifications (all three fixed)

### (a) ac_watcher now runs the W4 rewrite
- Code: repo `ac_watcher.sh` defines `bc_reapply_limit()` (line 69) and calls it
  (line 126); all `battopt` matches are comments only (lines 4, 9, 11, 19, 24)
  — zero `battopt` calls. No unplug/plug test was run (code-path only).
- Runtime: new-dir `.ac_state` advanced 18:51 → 18:52 after the reload (3 B,
  `Yes` — the W4 rewrite's no-newline write style); old-dir `.ac_state`
  frozen at 18:50 (4 B, `Yes\n` — the old write style). The new agent writes
  the new dir; the old agent is dead. (ps sampling missed the short-lived
  10 s runs — not a failure; the `.ac_state` evidence is definitive.)

### (b) self_maintenance false alarm stops
- Code: repo `self_maintenance.sh` uses `bc-status` (check 1, lines 7/25/35/41);
  all `battopt` matches are comments only — zero `battopt` calls.
- Runtime: manual run of the deployed script (`bash
  ~/.battery-commander/self_maintenance.sh`) → **EXIT=0**, no output, no alert.
  `.maint_alerted` identical before/after (mtime Nov 9 18:29, content
  `1794241765`) — no new false-alarm entry. The agent (PID 14596, 300 s) now
  runs the fixed script.

### (c) cleanup_logs rotates new-dir logs
- Code: rotation list covers `powerwatch.log`, `bc-limit-daemon.log`,
  `.watchdog.out`, `.watchdog.err`, `bc-build/bc-limit-daemon.log` plus all
  state-dir logs; `rotate_log` caps at 100 KB, keeps last 200 lines, archives
  a copy, never deletes a log file. `.bak` purge is NOT part of the daily run
  (only with `purge-bak` arg AND `.bak_purge_approved` flag — two gates).
- Runtime: manual run → **EXIT=0**; `.cleanup.log` (new dir) lists every
  new-dir log as OK/under-threshold (`.watchdog.log` 3,589 B,
  `powerwatch.log` 61 B, `actions.log` 2,714 B, `.watchdog.out`/`.err` 0 B,
  `limit.log` 8,562 B, …). Archive/Notify/Guard/Reports cleanup removed 0
  files. No purge ran. (`bc-limit-daemon.log` does not exist yet — the daemon
  is not loaded — so `rotate_log` skips it silently, by design.)

## 3. adaptive-governor — RETIRED, not repointed (deliberate deviation)

The task said "repoint the 14 agents", but repointing this one is impossible
and harmful — evidence:
- The repo copy (`src/daemon-helpers/adaptive_governor.sh`, 3,234 B, md5
  `37e96651…`) is byte-identical to the live old-dir copy, and it is the OLD
  script: it sources the dead `.throttle_helper.sh`, runs `sudo -n battopt
  status` (dead source), and calls `sudo -n battopt limit` (old binary, stale
  85/80 defaults) on state changes. W0 verdict: REPLACE → BC APG guard (now
  inside `bc-watchdog.sh`, which is running and classifying APG — heartbeat
  shows `APG=yellow` / `APG: state RED … suppressed`). W6 removal-list addendum:
  DROP.
- The script hardcodes `$HOME/.battopt-swiftbar/` for its log/state/config
  paths, so repointing the plist would NOT change where it reads/writes.
- Copying it to the new dir would violate the task's own constraint ("Do NOT
  copy dead files from the approved removal list") and would leave a
  `battopt limit`-capable agent running alongside BC.
- Action taken: `launchctl unload com.battopt.adaptive-governor.plist`
  (exit 0); the plist file is left in place (not deleted) and its original is
  in the backup dir — retirement is reversible by reloading it. The agent is
  gone from `launchctl list`. No further action needed unless the parent
  agent disagrees.

## 4. Verification summary

- `launchctl list | grep -E "battopt|batterycommander"` after reload: all 13
  repointed agents loaded; adaptive-governor gone; guardian/enforce/
  consolidated still gone; `com.batterycommander.watchdog` (`-`, 60 s) +
  `com.batterycommander.powerwatch` (PID 44060) still loaded.
- Watchdog heartbeat in the new-dir log: `PCT=87 BCLM=10 cfg=86/85 … mode=hold
  APG=yellow backend=bclm` (18:31–18:32 EET) — the BC stack is live and
  classifying APG itself.
- Observation (not this task's scope): `com.batterycommander.launcher.181732`
  (PID 5462) is running — the parallel app-install task's new launcher.
  Untouched.

## 5. What still needs a decision

- **None for this task.** All 13 repoints + the 1 retirement are done and
  verified. Remaining deploy items are unchanged (W6 CONDITIONAL PASS
  blockers): sudoers verification (decision 8, still owed), dead-file removal
  at deploy (approved 17:46 EET — `.baks` purge Nov 13–14), Phase C
  (rejected unless necessary), old-dir deletion only after a full day of
  normal use on the new dir + explicit approval.

## 6. Files

- This note: `battopt-project/bc-build/agent-repoint-note.md` (Mac) +
  `~/workspace/bc-build/agent-repoint-note.md` (local).
- Populate script: `battopt-project/bc-build/repoint-populate.sh` (Mac) +
  `~/workspace/bc-build/repoint-populate.sh` (local).
- Plist backup: `battopt-project/bc-build/agent-plists-backup-20261110/`
  (Mac, 14 files, md5-verified) + `~/workspace/bc-build/agent-plists-backup-20261110/`
  (local, 14 files, md5-verified).
- Download helper: `~/workspace/bc-build/download_plists.py` (local).
