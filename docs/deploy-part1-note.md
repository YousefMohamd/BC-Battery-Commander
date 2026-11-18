# Deploy Part 1 note — file work + activation prep (NO activation)

**Date:** 2026-11-10 (~18:12–18:16 EET). **Status: COMPLETE.**
File work + prep only. **Nothing was activated:** no `launchctl load/unload`,
no sudo, no daemon load (Phase C), no deletions, no /Applications install,
no signing, no commit/push, no live battery test. The old system is still
fully live (old battopt root daemon PID 88736, old root powerwatch PID 158,
17 old user agents loaded, old launcher applet PID 2204).

## 1. What was populated — `~/.battery-commander/` (21 files, all md5-verified)

Populate script: `battopt-project/bc-build/deploy-populate.sh` (re-runnable).
All copies are from the repo ONLY, never from the old state dir. `FAIL=0`,
exit 0. All scripts + bc-status are `-rwxr-xr-x`.

| File | Size | md5 (repo = new dir) | Source |
|---|---|---|---|
| dispatch.sh | 76,218 | f4095d71145ba5906400fd48a7e41df4 | src/daemon-helpers/ |
| display_state.sh | 4,486 | a3ffeae9647f13511fd77cad3132f94d | src/plugin/ |
| state_guard.sh | 2,900 | 3c0b799ad2e6d4eacf9046402483f691 | src/daemon-helpers/ |
| bc-watchdog.sh | 50,258 | b0ce3d54d5be05ec44341a6fa7cdd845 | src/daemon-helpers/ |
| arm_sleep.sh | 6,765 | 35d7387abe91a1563292b062a5164367 | src/daemon-helpers/ |
| pre_sleep_cleanup.sh | 2,429 | b4ff3845a3de21369a72490a0c81ad89 | src/daemon-helpers/ |
| post_wake_restore.sh | 1,035 | 1258a80b022286f1c51e88e9d9cf2f6d | src/daemon-helpers/ |
| sailing_tracker.sh | 2,691 | a75bb01c225afdc8364a5990f5f147e5 | src/daemon-helpers/ |
| adaptive.sh | 1,748 | e0bc10f031a2f80815ad709cf83f42c6 | src/daemon-helpers/ |
| ensure_limit.sh | 4,037 | 47e9aad444ef14d98eb987c573146d51 | src/daemon-helpers/ |
| system_guard.sh | 2,003 | 91f6b51bf4b16be73b45386054d7dc6c | src/daemon-helpers/ |
| conflict_check.sh | 2,233 | e7bcc3aaddfcf9a7c02a18b75b912802 | src/daemon-helpers/ |
| force_reset.sh | 3,363 | 0cdfd598615a351a592921cef9bd4346 | src/daemon-helpers/ |
| power_mode.sh | 4,094 | 227c131c4e686b8818bc4ede3f024a1b | src/daemon-helpers/ |
| power_saver.sh | 6,228 | 3bdf5ebe99394affcf1a63d83e79ff1d | src/daemon-helpers/ |
| predictive.sh | 3,592 | 9cecaa09dea6baf2c4970a030c7c99ae | src/daemon-helpers/ |
| process_monitor.sh | 2,678 | 7ae7996aad409ea2025d48f8d89b7885 | src/daemon-helpers/ |
| project_health.sh | 9,774 | d40bae1688bc8cc1f6141709d4bdd9e1 | src/daemon-helpers/ |
| self_healing.sh | 7,630 | e6839c89e265a4ce7453b408d522fbaf | src/daemon-helpers/ |
| launch_swiftbar.sh | 1,030 | 2d44eb56d0f9ef9eb2b064ec2384a405 | src/daemon-helpers/ |
| bc-status | 51,376 | 14528e6d81268189c71c6af879546af7 | battopt-project/bc-build/ |

Selection rule (task step 3): scripts the NEW stack references via `$DASH`
(plugin, dispatch, watchdog incl. its 600 s fan-out, powerwatch, launcher).
`bc-status` is included because the launcher requires `$DASH/bc-status`
(it has no repo fallback — `read_bclm()` returns 1 without it).

NOT copied (deliberate, not an omission):
- Dead files from the approved removal list (charge_upper_watcher,
  charging_guard, guardian, enforce_watchdog, consolidated_checks,
  sd_watcher, adaptive_governor, sentinel, daemon_watchdog, heat_analysis,
  check_permissions, check_spotlight, log-change, battopt-daemon-start,
  emergency-stop, BattOpt-launcher, trial-renew files, root helpers).
- Agent-driven scripts whose old agents still point at the OLD dir
  (see §5 flag): ac_watcher, cleanup_logs, self_maintenance,
  morning_report, pmset_check, sleep_manager, sleep_monitor,
  state_hygiene, wake_analyzer, swiftbar_watchdog, overnight_drain_test
  (hand-run diagnostic), test_enforce_watchdog (test). Copying them to the
  new dir would leave dead files there — no new-stack code invokes them
  via `$DASH`.

## 2. powerwatch binary — built, verified, NOT run

- Command: `clang -Wall -Wextra -framework CoreFoundation -framework IOKit src/powerwatch/powerwatch.c -o ~/.battery-commander/powerwatch`
- Result: exit 0, **no warnings** (stderr empty).
- `file`: Mach-O 64-bit executable x86_64. `otool -L`: CoreFoundation,
  IOKit, libSystem — links cleanly. Size 52,568 B, `-rwxr-xr-x`,
  user-owned. Same size as the W5 test binary.
- The binary was NOT executed (running it would start a second powerwatch
  alongside the old root one — PID 158 — and sleep handling has side
  effects). First run happens when the user agent loads at activation.

## 3. Plugin installed — `~/SwiftBar/battery-commander.10s.sh`

- `cp -p` from `src/plugin/battery-commander.10s.sh`, `chmod +x`.
- md5 repo = installed: `a6c2db743345a02a2e3deb542727bcea`. Size 42,834 B.
- Dependencies verified present + executable in the new dir:
  display_state.sh, state_guard.sh, dispatch.sh, bc-watchdog.sh,
  bc-status, powerwatch — all OK.
- The old `~/SwiftBar/battopt.10s.sh` (38,768 B) is untouched. **Both
  plugins now render in the menu bar** (two battery icons) until the old
  one is removed — see §5 flag.

## 4. verify-install.sh — stale wording fixed (finding 4)

- Backup: `battopt-project/bc-build/verify-install.sh.pre-deploy`
  (md5 `261c0e0295d61540b75abb98b3cd3f5f`, 7,605 B — byte-identical to the
  pre-fix repo copy).
- Changes (2 lines): header comment "INFO until W5.1 builds it" →
  "INFO until it is installed in /Applications (built in the repo since
  W5.1 + icon task)"; line 138 `info "Battery Commander.app bundle"
  "not yet built (W5.1)"` → `"not installed in /Applications (built in
  repo)"`.
- New file: 7,694 B, md5 `ddf81d8a6fd94fe28d548cd724a36d2c` (local↔Mac
  match). `bash -n` OK locally and on the Mac.

## 5. Substituted plists — `battopt-project/bc-build/deploy/` (Mac + local)

`@HOME@` → `/Users/Yousef` via `sed` (launchd does not expand `$HOME`).
`plutil -lint` OK for all three; zero `@HOME@` remaining in any file.
Local copies in `~/workspace/bc-build/deploy/` (md5-identical to Mac).

| Plist | Size | md5 | Program (after substitution) |
|---|---|---|---|
| com.batterycommander.watchdog.plist | 1,513 B | 49193379bd07e32ca3bbc902fd7c415e | /Users/Yousef/.battery-commander/bc-watchdog.sh (60 s, RunAtLoad) |
| com.batterycommander.powerwatch.plist | 1,174 B | 9220348413e215f7729de8b9011f3228 | /Users/Yousef/.battery-commander/powerwatch (KeepAlive, RunAtLoad) |
| com.batterycommander.bclimit.plist | 2,073 B | e364b20d5d0ff8ca6c8dc969c40196fb | /Users/Yousef/Projects/BattOpt-CC-Release/battopt-project/bc-build/bc-limit --config /Users/Yousef/.battery-commander/config --write (60 s, RunAtLoad) |

These copies are NOT installed anywhere in this task (no copy to
`/Library/LaunchDaemons` or `~/Library/LaunchAgents`, no load).

## 6. verify-install.sh — before / after

Before (17:53 EET, migration verification): **8 PASS, 2 FAIL, exit 1**
(plugin missing; powerwatch binary missing).
After (18:16 EET, this task): **ALL CHECKS PASSED (10/10), exit 0.**
Log: `battopt-project/bc-build/verify-install-2026-11-10-deploy1.log`
(829 B, md5 `78e7ac47b889ba36c9092d1ebf0db1cf`, local↔Mac match).

```
[PASS] BC binaries executable in bc-build (bc-status, bc-limit, bc-candidates)
[PASS] BC LaunchDaemon plist exists and lints (com.batterycommander.bclimit)
[INFO] BC LaunchDaemon: not loaded (expected until Phase C approval)
[PASS] all 17 user LaunchAgents installed and loaded
[PASS] all .sh scripts in /Users/Yousef/.battery-commander executable
[INFO] sudoers /etc/sudoers.d/battopt: not readable without sudo (BC sudoers is pmset-only, W5.1)
[PASS] SwiftBar plugin battery-commander.10s.sh executable
[INFO] Battery Commander.app bundle: not installed in /Applications (built in repo)
[PASS] powerwatch binary executable
[PASS] config parses with LAST_UPPER/LAST_LOWER
[PASS] .active_mode = hold
[PASS] bc-status returns output (Capacity line present)
[PASS] no dispatch.sh shutdown process running
```

## 7. EXACT activation command list — for Yousef (NOT run in this task)

Order: populate (DONE in this task) → sudo daemon-plist copy →
disable 3 old agents → unload old root powerwatch (sudo) → install +
load new agents → verify. **Do NOT load the bc-limit daemon (Phase C).**

Prerequisite still owed: **sudoers verification (decision 8)** — Yousef
has the command (`sudo cat /etc/sudoers.d/battopt`); the output has NOT
arrived yet. The pmset-only sudoers replacement install is BLOCKED until
it arrives. (The activation below does not install sudoers.)

### Step A — install the bc-limit daemon plist (sudo, from the repo root)

```sh
cd /Users/Yousef/Projects/BattOpt-CC-Release
sudo cp battopt-project/bc-build/deploy/com.batterycommander.bclimit.plist /Library/LaunchDaemons/com.batterycommander.bclimit.plist
sudo chown root:wheel /Library/LaunchDaemons/com.batterycommander.bclimit.plist
sudo chmod 644 /Library/LaunchDaemons/com.batterycommander.bclimit.plist
```

(The deploy/ copy is already `@HOME@`-substituted, so it is copied
directly — no `/tmp` intermediate needed. The plist is installed but
NOT loaded here; loading it is Phase C.)

### Step B — disable the 3 old user agents (NO sudo — user domain)

Verified: `com.battopt.guardian`, `com.battopt.enforce`,
`com.battopt.consolidated` are user LaunchAgents
(`~/Library/LaunchAgents/`, loaded — `launchctl list` shows all three).

```sh
launchctl unload ~/Library/LaunchAgents/com.battopt.guardian.plist
launchctl unload ~/Library/LaunchAgents/com.battopt.enforce.plist
launchctl unload ~/Library/LaunchAgents/com.battopt.consolidated.plist
```

Verify: `launchctl list | grep battopt` — guardian / enforce /
consolidated must be gone; the other 14 old agents remain (see §8).

### Step C — unload the OLD root powerwatch (sudo — system domain)

The old root powerwatch is still RUNNING (PID 158,
`/Users/Yousef/.battopt-swiftbar/powerwatch`, root). The new BC
powerwatch user agent would otherwise run alongside it and both would
fire arm_sleep on every sleep (double sleep handling). Unload it BEFORE
loading the new agent:

```sh
sudo launchctl unload /Library/LaunchDaemons/com.battopt.powerwatch.plist
```

Verify: `pgrep -f powerwatch` shows nothing (until the new agent loads).

### Step D — install + load the 2 new user agents (NO sudo — user domain)

```sh
cp /Users/Yousef/Projects/BattOpt-CC-Release/battopt-project/bc-build/deploy/com.batterycommander.watchdog.plist ~/Library/LaunchAgents/com.batterycommander.watchdog.plist
cp /Users/Yousef/Projects/BattOpt-CC-Release/battopt-project/bc-build/deploy/com.batterycommander.powerwatch.plist ~/Library/LaunchAgents/com.batterycommander.powerwatch.plist
launchctl load ~/Library/LaunchAgents/com.batterycommander.watchdog.plist
launchctl load ~/Library/LaunchAgents/com.batterycommander.powerwatch.plist
```

Verify: `launchctl list | grep batterycommander` shows both labels;
`tail ~/.battery-commander/.watchdog.log` shows watchdog ticks;
`tail ~/.battery-commander/powerwatch.log` shows the agent starting.
The watchdog must NOT write BCLM and must NOT call `bc-limit --write`
(it never does — it only reads + logs until Phase C).

### Step E — DO NOT load the bc-limit daemon (Phase C — separate approval)

```sh
# DO NOT RUN (Phase C — rejected unless necessary):
# sudo launchctl load /Library/LaunchDaemons/com.batterycommander.bclimit.plist
```

Loading it starts REAL enforcement (`--write` every 60 s): if the live %
is below 85% the first run writes BCLM=100 (resume charging) — that is
the full enforcement cycle (see launchdaemon-install.md).

### Before Phase C (NOT now) — unload the OLD root battopt daemon

The old battopt root daemon is still RUNNING (PID 88736,
`/Library/Application Support/battopt/battopt daemon`, root, plist
`/Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist`). It is
the current enforcer (BCLM=10 hold). Do NOT unload it until Phase C:
unloading it now would leave no enforcer at all. At Phase C, unload it
first, then load the BC daemon:

```sh
sudo launchctl unload /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist
sudo launchctl load /Library/LaunchDaemons/com.batterycommander.bclimit.plist
```

## 8. Flags / open items (for the parent agent + Yousef)

1. **Sudoers verification (decision 8) still owed.** One direct on-Mac
   read (`sudo cat /etc/sudoers.d/battopt`) — Yousef's action, output not
   yet received. The pmset-only replacement
   (`src/sudoers/battery-commander`) must NOT be installed until the
   installed file is read and compared.
2. **Both plugins render now.** Old `~/SwiftBar/battopt.10s.sh` + new
   `~/SwiftBar/battery-commander.10s.sh` both render (two battery icons).
   Removing the old installed plugin is a deletion — NOT on the approved
   removal list (the list covers the repo copy) — needs Yousef's explicit
   say-so.
3. **Remaining 14 old user agents still point at the OLD dir and run
   STALE scripts (deploy-design gap — needs a decision).** Verified:
   installed plists hardcode `/Users/Yousef/.battopt-swiftbar/*.sh`
   (e.g. acwatcher → old ac_watcher.sh). Consequences until those agents
   are repointed/replaced: (a) the W4 ac_watcher rewrite
   (`bc_reapply_limit`) does NOT run — the old copy still calls
   `battopt limit` on AC connect; (b) the W2 self_maintenance fix does
   NOT run — the old copy still false-alarms hourly
   (`sudo -n battopt status`); (c) the W6.2 cleanup_logs rotation does
   NOT run — the old copy rotates only old-dir logs, so the new-dir logs
   (bc-limit-daemon.log, .watchdog.out/.err, powerwatch.log) grow
   unbounded (~1.5 MB/day for the daemon log at 60 s cadence) until
   `com.battopt.log-cleanup` is repointed to the new dir or a new
   cleanup agent is added. The 3 disabled agents (guardian/enforce/
   consolidated) are the only ones the deploy retires; the rest were
   never in the deploy scope. Decision needed: repoint the old agent
   plists to `~/.battery-commander/` (plist edits + reload) or accept
   the transition state.
4. **App install + login-item switch not done.** `app/BatteryCommander.app`
   is built (with the new-logo .icns) but NOT installed in /Applications
   and unsigned; the old `/Applications/BattOpt.app` launcher applet
   (PID 2204, login item `com.yousef.battopt.launcher.181332`) is still
   running. Copying the new app to /Applications + switching the login
   item is a separate deploy step (signing is a deploy step — not done).
5. **Dead-file removal at deploy** (approved 17:46 EET, incl.
   charge_upper_watcher) — deletion happens AFTER activation is verified,
   NOT in this task. `.baks` purge Nov 13–14 when they cross 30 days.
6. **Phase C** (bc-limit daemon load + full-cycle test) — REJECTED unless
   necessary. The daemon plist is installed (step A) but must stay
   unloaded.
7. **Old dir deletion:** only after a full day of normal use on the new
   dir + Yousef's explicit approval. The old dir is untouched (95
   entries) and remains the fallback + safety net.

## 9. Files

- Populate script: `battopt-project/bc-build/deploy-populate.sh` (Mac) +
  local `~/workspace/bc-build/deploy-populate.sh`.
- Transfer helper (local): `~/workspace/bc-build/transfer.py`
  (prepare + confirm + size check); `/run` helper (local):
  `~/workspace/bc-build/run_mac.py`.
- Fixed verify-install.sh: `src/verify-install.sh` (Mac + local,
  7,694 B, md5 `ddf81d8a6fd94fe28d548cd724a36d2c`); backup
  `battopt-project/bc-build/verify-install.sh.pre-deploy` (7,605 B,
  md5 `261c0e0295d61540b75abb98b3cd3f5f`).
- Substituted plists: `battopt-project/bc-build/deploy/` (Mac) +
  `~/workspace/bc-build/deploy/` (local, md5-identical).
- Re-run log: `battopt-project/bc-build/verify-install-2026-11-10-deploy1.log`
  (829 B, md5 `78e7ac47b889ba36c9092d1ebf0db1cf`, local↔Mac match).
- This note: `battopt-project/bc-build/deploy-part1-note.md` (Mac) +
  `~/workspace/bc-build/deploy-part1-note.md` (local).
