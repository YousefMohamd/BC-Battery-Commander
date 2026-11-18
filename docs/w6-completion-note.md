# W6 completion note — integration review (pre-live-test gate)

**Date:** 2026-11-10. **Status: CONDITIONAL PASS** — the wrapper code passes
every check; deploy is blocked only on Yousef's approvals/actions (list in
§6). Nothing went live in W6: no daemon load, no Phase C, no live battery
test, no install, no sudo, no SMC write, no commit/push.

## 1. What W6 did (by task)

### W6.1 — Config unification (plist `--config` fix)
- `battopt-project/bc-build/com.batterycommander.bclimit.plist` (1,701 → 2,024 B):
  `--config @HOME@/.battery-commander/config` added (canonical state-dir
  config; `bc-build/limit.conf` is dev/test only); binary path, working
  directory and both log paths `@HOME@`-ized; daemon log moved to
  `@HOME@/.battery-commander/bc-limit-daemon.log` (state dir, so
  cleanup_logs.sh rotates it). `plutil -lint`: OK. NOT installed/loaded.
- `launchdaemon-install.md` (4,270 → 5,155 B): `@HOME@` `sed` substitution
  step, migration-first ordering, new log paths, stale "battery is
  currently 84%" note replaced with the live-% rule; battopt rollback line
  kept (genuine rollback path).

### W6.2 — Logs/notifications audit
- `cleanup_logs.sh` (6,548 → 7,116 B): rotation extended to
  `$DASH/bc-limit-daemon.log`, `$DASH/.watchdog.out/.err`, and
  `bc-build/limit.log` + the legacy bc-build daemon-log path. The
  bc-limit logs were the only unrotated logs in the stack (~1.5 MB/day
  unbounded at 60 s cadence); now every log is covered.
- `dispatch.sh`: `notify()` gains the osascript fallback (was silently
  dropping the notify when terminal-notifier was absent).
- `self_maintenance.sh`: alert notifier gains the osascript fallback and
  is backgrounded (was a blocking direct call with no fallback).
- Notification discipline verified per component: plugin
  (`notify_proactive_v2`: quiet hours 23:00–08:00 non-critical, daily cap
  3, per-key cooldown 1800 s, notifier → osascript); watchdog
  (`notify_ratelimited`: per-key cooldown + quiet hours); launcher
  (`notify()`: notifier → osascript → log); arm_sleep (local notify,
  sleep-bounded); self_maintenance (1 h cooldown via `.maint_alerted`).
  Dispatch `notify()` has no cooldown/cap — ACCEPTED as-is (every call
  site is user-triggered or physical-event-triggered). Watchdog drift + L8
  notifies may both fire pre-Phase-C (accepted, W3).

### W6.3 — Rebrand/path audit + state-dir migration
- **DASH fallback block** (identical everywhere): `BC_DASH` override →
  `~/.battery-commander/` if it exists → `~/.battopt-swiftbar/` fallback.
  Applied to 23 scripts + the plugin + watchdog + dispatch + launcher +
  cleanup_logs + verify-install; `SG_DIR` variant in state_guard.sh.
  Verified by a smoke test (4 cases: new dir, old dir only, BC_DASH
  override, neither → old dir). DASH resolution is the single migration
  mechanism: no script hardcodes the new dir alone.
- **Migration script** `src/migrate-state-dir.sh` (NEW, 3,853 B) +
  **plan** `battopt-project/bc-build/state-dir-migration-plan.md` (NEW,
  3,923 B): idempotent (`cmp` skip), copies state files only (config +
  flags + markers + `.notify/` + `.guard_alerts/` + `icons/` +
  `disabled/`), NEVER deletes the old dir, writes a receipt, `--dry-run`
  supported. Dry-run tested locally against a fake HOME: 5 files would
  copy; real run copied 5, failed 0, re-run copied 0 / skipped 5
  (idempotent); `.sd_session`, orphaned state and logs correctly skipped;
  old dir untouched. **NOT run on the Mac — deploy step, user present.**
  Side effect: the migrated `.power_saver` copy is user-owned, which
  fixes the W5 root-ownership flag for the new dir.
- **Plugin label:** `Remove Limit (hold at current)` →
  `Remove Hold (return to 86/85%)` (param1 unchanged).
- **Plugin 3-case safe default: KEEP** (documented): it fires only when
  display_state.sh is absent and does not duplicate the icon table; it
  keeps the menu bar from rendering blank.
- **`BC_BUILD_DIR` `battopt-project` path: ACCEPTED** (documented): it is
  the project documentation folder name, not a reference to the battopt
  tool; overridable via `$BC_BUILD_DIR` env. The folder is NOT renamed.
- **Descriptive "battopt" mentions in comments** ("replacement for the
  closed-source battopt tool", "no battopt binary") are legitimate
  documentation — kept.
- **Login-item name:** the installed login item is still BattOpt.app until
  deploy swaps it. Dispatch resume/toggle/open_app prefer
  BatteryCommander.app and fall back to BattOpt.app; all login-item greps
  match both names. The installed item itself is NOT changed in W6.
- **Stale names fixed:** dispatch SwiftBar refresh URL
  (`battopt.10s` → `battery-commander.10s` — the menu would not refresh
  after actions); shutdown park-plugin glob + resume restore
  (`disabled/battopt.10s.sh` → `battery-commander.10s.sh`); build-app
  `find_icon` (new dir first); applescript dispatch/log paths (new dir
  first, `/bin/test` fallback); powerwatch.c `resolve_paths` default
  (new-first via `access()`); powerwatch plist (3 refs → new dir);
  power_saver title comment.
- **User-visible BattOpt titles/groups fixed** (found by the final sweep):
  arm_sleep notifier `-group battopt` → `battery-commander`; adaptive
  "BattOpt Safety", morning_report "BattOpt — Morning Report",
  pmset_check "BattOpt Recovery", system_guard "BattOpt Guard" (2×),
  overnight_drain_test banner — all → "Battery Commander …". Zero
  user-visible BattOpt titles/groups remain in the new stack (the 2
  matches left are in `enforce_watchdog.sh`, the old replaced file on the
  removal list).
- **Remaining transitional refs (documented, not bugs):** DASH fallback
  to `~/.battopt-swiftbar/` (31×, until migration); old-app / old-plist /
  old-login-item / old-cron matches in dispatch shutdown/resume/toggle
  and verify-install's old-agent list (needed until deploy removes the
  old items); `icons/battopt.png` filename (2× in dispatch — the file on
  disk is named that; rename it at deploy if desired); `battopt-project/`
  folder name (accepted, above).

### W6.4 — Full integration review + test execution
- **Single-enforcer rule VERIFIED:** zero `smc_write` /
  `SMC_CMD_WRITE_BYTES` in any .sh (only bc-limit.c writes); zero
  `bc-limit --write` calls in scripts (comments only); zero `eval` in the
  new stack; sudo ONLY `sudo -n /usr/bin/pmset` (dispatch sleep-mode
  branches, power_saver `_ps`, self_healing sleep-mode sections,
  project_health pmset check) — **W1.9 final verdict: pmset needs sudo;
  the sudoers replacement is pmset-only; installed sudoers STILL
  UNVERIFIED (decision 8 owed)**.
- **7 live scripts that still called battopt — all fixed:**
  sailing_tracker (→ ioreg PCT + config limits, KEY=value state parse —
  also fixes the W0-extension stale-85/80 sailing-state bug),
  predictive (TEMP/HEALTH/CYCLES → bc-status), process_monitor
  (powerwatch → BC user agent, battopt-daemon section deleted),
  state_hygiene (hold legitimacy via BCLM=10 read from bc-status;
  `.sd_session` always stale in v1; charge_full legitimate iff config
  is 100/99; WANT_UP default 85 → 86; config recreate atomic),
  self_healing (§5 daemon restart deleted; §6 drift-reapply deleted —
  watchdog owns drift; plugin → battery-commander.10s.sh; config
  validator canonical 86/85 + SAILING=false + SAIL_GAP=1, atomic;
  `.sleep_mode`/`.current_power_mode` writes atomic; zombie pattern →
  Battery Commander), force_reset (**full rewrite** — BC recovery:
  re-verify BCLM + config + daemon-log proxy, clear stale guard/session
  state, reapply via dispatch; no battopt, no sudo, no BCLM write, no
  daemon load; dispatch `force_reset` stub wired to call it),
  project_health (daemon → log-mtime proxy warn, powerwatch → BC agent,
  agent loop → watchdog + powerwatch, TEMP → bc-status, battopt NOPASSWD
  check deleted, `fail()` defined — it was called but never defined —
  vacuous standbydelay `check` fixed; standbydelay expectations still
  reference the removed long/travel profiles — see §7 flag).
- **Launcher bug fixed:** `daemon_loaded()` (`launchctl list`, user
  domain) can never see the system daemon — replaced for the enforcer
  with `daemon_running_system()` (daemon-log mtime proxy, < 180 s).
  Same proxy in verify-install.sh and project_health.sh.
- **conflict_check:** rebranded; own processes/agents excluded from the
  conflict lists.
- **verify-install.sh:** DASH block + daemon log-mtime proxy (was a
  false-negative `launchctl list` check).
- **W6.4 decision: bc-limit does NOT read `.apg_paused`.** The APG guard
  applies to the watchdog's corrective-discharge gate only (already
  implemented); the enforcer's hold/resume writes are not discharges.
- **New watchdog agent:** `src/agents/com.batterycommander.watchdog.plist`
  (NEW, 1,485 B): user LaunchAgent, StartInterval 60, RunAtLoad,
  `@HOME@/.battery-commander/bc-watchdog.sh`, stdout/stderr →
  `.watchdog.out/.watchdog.err`, no KeepAlive. NOT installed/loaded.
  Old agents (guardian / enforce / consolidated) are disabled at deploy.
- **Removal-list addendum (W6, for user approval at deploy):**
  guardian.sh, enforce_watchdog.sh, consolidated_checks.sh,
  sd_watcher.sh, adaptive_governor.sh (all replaced by the watchdog; the
  consolidated agent stays loaded until deploy disables it — intended
  transition). Plus the W5 list (incl. charge_upper_watcher.sh — needs
  explicit user approval — and src/launcher/main.c).
- **test_bc_watchdog.sh EXECUTED on the Mac — PASS.** First run: 1
  failure (`suppress_logs=0`, expected ≥ 1). Root cause: the test's
  Phase A window (30 ticks) was one tick short — the CRITICAL rung fires
  first at COUNT≥16 (tick 16) then every 300 s cooldown (ticks 21, 26,
  31); the cap-suppression log only appears on the 4th firing (tick 31).
  The watchdog was correct; the test window was short. Fix (test only):
  Phase A 30 → 35 ticks, later phases shifted +300 s. Re-run: **PASS**
  (log `battopt-project/bc-build/test_bc_watchdog-2026-11-10.log`,
  507 B, 15 lines — local copy in `~/workspace/bc-build/`).

## 2. Files changed (before → after size, Mac = local by md5)

| File (repo path) | Before | After |
|---|---|---|
| src/daemon-helpers/dispatch.sh | 76,515 | 76,218 |
| src/daemon-helpers/bc-watchdog.sh | 49,914 | 50,258 |
| src/daemon-helpers/arm_sleep.sh | 6,428 | 6,765 |
| src/daemon-helpers/ac_watcher.sh | 4,813 | 5,157 |
| src/daemon-helpers/ensure_limit.sh | 3,693 | 4,037 |
| src/daemon-helpers/pre_sleep_cleanup.sh | 2,085 | 2,429 |
| src/daemon-helpers/power_saver.sh | 5,934 | 6,228 |
| src/daemon-helpers/self_maintenance.sh | 4,162 | 4,818 |
| src/daemon-helpers/sleep_manager.sh | 2,415 | 2,741 |
| src/daemon-helpers/sleep_monitor.sh | 1,073 | 1,417 |
| src/daemon-helpers/wake_analyzer.sh | 2,298 | 2,642 |
| src/daemon-helpers/power_mode.sh | 3,752 | 4,094 |
| src/daemon-helpers/overnight_drain_test.sh | 4,102 | 4,456 |
| src/daemon-helpers/post_wake_restore.sh | 731 | 1,035 |
| src/daemon-helpers/morning_report.sh | 2,019 | 2,315 |
| src/daemon-helpers/pmset_check.sh | 1,106 | 1,442 |
| src/daemon-helpers/adaptive.sh | 1,398 | 1,748 |
| src/daemon-helpers/launch_swiftbar.sh | 690 | 1,030 |
| src/daemon-helpers/system_guard.sh | 1,643 | 2,003 |
| src/daemon-helpers/state_guard.sh | 2,546 | 2,900 |
| src/daemon-helpers/sailing_tracker.sh | 1,652 | 2,691 |
| src/daemon-helpers/predictive.sh | 3,047 | 3,592 |
| src/daemon-helpers/process_monitor.sh | 1,743 | 2,678 |
| src/daemon-helpers/force_reset.sh | 3,543 | 3,363 |
| src/daemon-helpers/state_hygiene.sh | 8,664 | 9,635 |
| src/daemon-helpers/self_healing.sh | 8,862 | 7,630 |
| src/daemon-helpers/project_health.sh | 8,777 | 9,774 |
| src/daemon-helpers/conflict_check.sh | 2,140 | 2,233 |
| src/daemon-helpers/cleanup_logs.sh | 6,548 | 7,116 |
| src/plugin/battery-commander.10s.sh | 42,370 | 42,834 |
| src/plugin/display_state.sh | 4,128 | 4,486 |
| src/verify-install.sh | 6,890 | 7,605 |
| src/migrate-state-dir.sh | NEW | 3,853 |
| src/app/BatteryCommander-launcher.sh | 9,121 | 9,923 |
| src/app/BatteryCommander.applescript | 948 | 1,304 |
| src/app/build-app.sh | 9,780 | 9,956 |
| src/powerwatch/powerwatch.c | 13,812 | 14,083 |
| src/agents/com.batterycommander.powerwatch.plist | 1,163 | 1,146 |
| src/agents/com.batterycommander.watchdog.plist | NEW | 1,485 |
| battopt-project/bc-build/test_bc_watchdog.sh | 10,397 | 11,367 |
| battopt-project/bc-build/com.batterycommander.bclimit.plist | 1,701 | 2,024 |
| battopt-project/bc-build/launchdaemon-install.md | 4,270 | 5,155 |
| battopt-project/bc-build/state-dir-migration-plan.md | NEW | 3,923 |
| app/BatteryCommander.app (rebuilt) | W5 bundle | rebuilt 2026-11-10 |

Backups: every changed file has a `battopt-project/bc-build/<name>.pre-w6`
backup on the Mac (40 files). Patch scripts (local):
`w6-apply.py`, `w6-apply-part2.py`, `w6-apply-part3.py`,
`w6-apply-part4.py`, `w6-repair-dash.py`, `w6-transfer.py`
(in `~/workspace/bc-build/`).

## 3. Verification evidence

- **Transfer:** 43 files + 40 `.pre-w6` backups transferred via File API
  two-phase write; batch verification **83/83 md5 + size match**
  (report `w6-transfer-report.json`). Two later fixes re-transferred
  separately and re-verified (dispatch report paths, 6 title/group
  fixes — all md5 match).
- **bash -n on the Mac: 0 failures** (35 .sh files, incl. the 6
  re-transferred title fixes and the fixed dispatch).
- **plutil -lint on the Mac: OK** for all 3 plists (bclimit, powerwatch,
  watchdog). (Local plistlib check needs comments stripped — the plist
  comments contain `--write`/`--config`, which Python's expat rejects
  but Apple's parser accepts; the pre-existing bclimit plist already
  did this and passed plutil. Authoritative check is plutil on the Mac.)
- **clang on the Mac:** `clang -Wall -Wextra -framework CoreFoundation
  -framework IOKit -o /tmp/powerwatch-w6-test src/powerwatch/powerwatch.c`
  → exit 0, NO warnings, binary 52,568 B, Mach-O 64-bit x86_64. (First
  attempt without the frameworks failed at LINK (undefined
  CFRunLoop/IOKit symbols) — a missing-link-flags error, not a code
  error; W5's note omitted the frameworks.)
- **App bundle rebuilt** with `build-app.sh --test`: all checks PASS
  (Mach-O applet, CFBundleIdentifier com.batterycommander.launcher,
  LSUIElement true, launcher present + executable, unsigned as expected,
  icon SKIP as expected). Bundle copied to `app/BatteryCommander.app`:
  Resources launcher md5 = src/app launcher md5
  (b368f2dc81dc312a195c485f1074005e); main.scpt md5 matches the fresh
  build (ede5e308df65fecda99fd595757510c3).
- **test_bc_watchdog.sh on the Mac: PASS** (see §1 W6.4). Full log in
  `battopt-project/bc-build/test_bc_watchdog-2026-11-10.log`:
  Phase A notifier_crit=3, holdwait=6, final_count=35, crit_logs=4,
  suppress_logs=1, drift_logs=1, consolidated_logs=4; Phase B cleanup
  OK; Phase C apg_suppress=10, holdwait 6→6, APG suppression OK; Phase D
  charge_target cleanup OK; Phase E daemon not-loaded log OK.
- **Postconditions (new stack, code lines):** `battopt <subcommand>` = 0;
  `eval` = 0; `bc-limit --write` = 0; `smc_write` = 0 in .sh;
  `sudo` = only `sudo -n /usr/bin/pmset` (dispatch 14, self_healing 8,
  project_health 1) + read-only `ls /etc/sudoers.d/` in conflict_check.
- **DASH smoke test (local):** new dir → new dir; old dir only → old
  dir; BC_DASH set → override wins; neither → old dir.
- **Migration dry-run (local, fake HOME):** 5 files would copy; real run
  copied 5, failed 0; re-run copied 0 / skipped 5; old dir untouched.

## 4. Incidents found and fixed inside W6 (all in the note so they are not repeated)

1. **DASH-block corruption (patch-script bug, caught by the final
   sweep — NOT by bash -n).** `dash_paths()` ran after the DASH block
   was inserted and replaced `~/.battopt-swiftbar` INSIDE the block:
   fallback became `DASH="$DASH"` (self-assignment — DASH would stay
   empty at runtime) in 23 files. bash -n passed (syntactically valid,
   semantically broken). Fixed by `w6-repair-dash.py` (23 files),
   re-verified (no corrupted blocks remain; every file has exactly 1
   correct fallback), plus the 4-case smoke test. Lesson: a patch script
   must never run a global replace over text it just inserted; verify
   with a behavioral test, not only bash -n.
2. **Test window one tick short** (see §1 W6.4): Phase A 30 → 35 ticks.
3. **Dispatch report-path bug** (found by the final rebrand sweep):
   dispatch read `/tmp/battopt_health_latest.txt` /
   `/tmp/battopt_conflicts_latest.txt` while the scripts now write the
   `battery-commander_*` names — the diagnostics intents would have read
   a stale/missing file. Fixed (4 + 3 occurrences), re-transferred,
   re-verified (old names 0, new names 7 on the Mac).
4. **Bundle copy nesting:** `cp -R /tmp/.../Contents app/.../Contents`
   created a nested `Contents/Contents/` instead of merging. Fixed:
   nested dir moved to trash (recoverable), re-copied with `ditto`,
   md5s verified. (Also: `/run` blocks `rm -rf` — use the File API
   delete (trash) or `ditto`.)
5. **Transfer 502s:** one HTTP 502 on a backup prepare (backed off 65 s,
   retried with the fixed script); one HTTP 502 on a find (backed off,
   retried); one HTTP 413 "command too long" on the batch-verify /run
   call (split into chunks of 10). One run-confirm timed out at 30 s
   while the detached test was starting — the test itself ran fine
   (log proves it).

## 5. W6 gate verdict: CONDITIONAL PASS

The wrapper code is complete and verified (see §3). It is ready for the
deploy gate subject to the deploy blockers in §6 — all of which are
Yousef's approvals/actions, not code defects. No code item blocks
deploy.

## 6. Deploy blockers (exact — all need Yousef)

1. **Approve the dead-file removal list** (W5 `bak-removal-list.md` +
   W6 addendum §1: guardian.sh, enforce_watchdog.sh,
   consolidated_checks.sh, sd_watcher.sh, adaptive_governor.sh;
   charge_upper_watcher.sh needs explicit approval). Nothing is deleted
   until he approves.
2. **Run the state-dir migration** (`src/migrate-state-dir.sh`, user
   present, dry-run first) — the plist, watchdog agent and powerwatch
   agent all point at `~/.battery-commander/`.
3. **Install the agents + daemon** (his sudo steps): watchdog user agent
   + powerwatch user agent (both `@HOME@` substitution) + the bc-limit
   LaunchDaemon plist (`launchdaemon-install.md`, `@HOME@` substitution);
   disable the 3 old `com.battopt.*` agents (guardian / enforce /
   consolidated).
4. **Sudoers verification (decision 8, still owed):** one direct on-Mac
   read of installed `/etc/sudoers.d/battopt` before installing the
   pmset-only replacement `src/sudoers/battery-commander`.
5. **`.power_saver` root ownership:** `sudo chown Yousef:staff
   ~/.battopt-swiftbar/.power_saver` (user step) — note the migration
   fixes this for the NEW dir (the copy is user-owned); the old file
   still needs the chown if the old dir is kept.
6. **Phase C approval + `sudo launchctl load`** for the enforcer, and the
   full-cycle test (daytime, user present — currently REJECTED unless
   necessary).

## 7. Flags carried to deploy (W5 flags + new W6 flags)

- `.power_saver` root ownership NOT fixed (see §6.5).
- Installed `/etc/sudoers.d/battopt` STILL UNVERIFIED (decision 8).
- `.last_wake` write implemented but NOT live (agent not installed);
  watchdog post-wake delay still uses the `pmset -g log` fallback until
  deploy.
- Plist templates use `@HOME@` — deploy must substitute the actual home.
- State-dir `src/powerwatch.c` divergence (3 md5s) documented — repo
  copy canonical.
- `build-app.sh --test` discovery (always use `--test` to retain the
  bundle).
- PCT rounding edge (watchdog rounds, dispatch floors — 1% boundary,
  enforcer is authority).
- **NEW (W6):** project_health standbydelay expectations still reference
  the removed long/travel profiles (travel 14400 / long_battery 3600 /
  active_battery 300) — needs the same power_saver profile-values
  decision Yousef still owes (define distinct values later if he wants
  them).
- **NEW (W6):** `icons/battopt.png` filename (2 refs in dispatch) —
  cosmetic; rename the file at deploy if desired.
- **NEW (W6):** the `battopt` rollback line in launchdaemon-install.md
  is kept deliberately (genuine rollback path).
- **NEW (W6):** test log local copy is 508 B vs Mac 507 B (one trailing
  newline added by the download helper) — content identical.
- Git status (NOT committed): M 31 files; D BattOpt-launcher.sh,
  BattOpt.applescript, battopt.10s.sh (all in trash, recoverable); new
  files incl. app/BatteryCommander.app/, both agent plists,
  migrate-state-dir.sh, battery-commander.10s.sh, bc-watchdog.sh.
  35 files changed, 2315 insertions, 2405 deletions (cumulative W1–W6).
