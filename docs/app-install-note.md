# App install note — Battery Commander to /Applications (fix step 4)

**Date:** 2026-11-10. **Status: COMPLETE.** The new Battery Commander app is
installed in /Applications, the old app is backed up (not deleted), the login
item is switched, and the new launcher is running. No sudo was needed for any
step. No LaunchAgent/LaunchDaemon was loaded or unloaded. The bc-limit daemon
stays UNLOADED (Phase C gate). No deletions, no commit/push, no live battery
test, no SMC write. The 14-agent repointing was NOT done here (parallel task).

## 1. Kill decision (old launcher, PID 2204)

- **Decision (delegated by Yousef 18:43 EET — "choose the best decision"): `kill`
  (SIGTERM) to PID 2204**, not a normal quit.
- **Reason:** a normal quit triggers the old launcher's `on quit` handler, which
  runs OLD `dispatch.sh shutdown --force` (old dir, old `battopt` calls) and could
  release the limit. `kill` skips the handler. The old daemon (PID 88736) and the
  agents are separate processes and are UNAFFECTED by killing the launcher applet.
- **Verified:** `pgrep -f "BattOpt.app"` after the kill → nothing
  (`OLD-LAUNCHER-GONE`). Re-checked after launch: still gone.
- One transient HTTP 502 on /run/prepare before the kill; the kill itself did NOT
  run on that attempt. Retried after a 65 s back-off; the retry succeeded.

## 2. Old bundle backup (NOT deleted)

- Moved `/Applications/BattOpt.app` →
  `battopt-project/bc-build/BattOpt.app.installed-backup-20261110` (in the repo —
  findable, preserved). `mv` exit 0, no sudo needed.
- Verified: old path gone (`No such file or directory`); backup exists;
  `Info.plist` md5 `2c6b2c7c43ab18ff636ec09451af9cc4` and
  `Resources/battopt.icns` md5 `2d8d334a669ce5cd36930a2c180ecf9b` — identical
  before/after the move. Backup contents: Info.plist (2,094 B),
  BattOpt-launcher.sh (5,929 B), applet.icns (71,867 B), applet.rsrc (388 B),
  battopt.icns (1,007,233 B), Scripts/.
- The installed `/Applications/BattOpt.app` was NOT on the approved removal list —
  that is why this is a backup move, not a deletion.

## 3. New bundle install

- `ditto` repo `app/BatteryCommander.app` → `/Applications/BatteryCommander.app`.
  Exit 0, no sudo needed. New name + new bundle ID; nothing overwritten in place.
- Verified in place:
  - `CFBundleIdentifier` = `com.batterycommander.launcher`
  - `CFBundleName` = `Battery Commander`
  - `CFBundleIconFile` = `Battery Commander`
  - `LSUIElement` = `true`
  - `Contents/Resources/Battery Commander.icns` md5
    `0314bdfa34d95b2f8e6b909ca9745941` — matches the repo source
  - Launcher `BatteryCommander-launcher.sh` 9,923 B, executable
  - `Contents/MacOS/applet`: Mach-O 64-bit executable x86_64
  - Bundle owned by Yousef (staff), installed 2026-11-10 16:12 UTC
    (18:12 local — the ditto time; note the install ran ~18:47 EET)

## 4. Login-item switch

- `osascript` (System Events): deleted login item `BattOpt` (exit 0), added
  `/Applications/BatteryCommander.app` (exit 0).
- Verified — login items now: Macs Fan Control, Keyboard Maestro, SwiftBar,
  Android File Transfer Agent, **BatteryCommander**; paths confirm
  `/Applications/BatteryCommander.app` present and `/Applications/BattOpt.app`
  absent.
- This protects the activation: the old login item would have force-reloaded ALL
  `com.battopt.*` agents on every login (undoing activation Step B) and
  re-created an empty `~/SwiftBar/battopt.10s.sh`.

## 5. Launch verification (new app launched once)

- `open /Applications/BatteryCommander.app` — exit 0. **No Gatekeeper dialog,
  no right-click → Open needed** (no quarantine flag; built locally).
- New applet running: PID 5462
  (`/Applications/BatteryCommander.app/Contents/MacOS/applet`); launcher bash
  PID 5465. Old launcher PID gone. SwiftBar still running (PID 1998).
- Launcher log (`~/.battery-commander/actions.log`, 18:48:08):
  - `=== LAUNCH START ===`
  - `WARN: enforcer com.batterycommander.bclimit is NOT running (Phase C gate -
    hold will not enforce)` + notification sent (expected, by design)
  - `powerwatch com.batterycommander.powerwatch is loaded`
  - `watchdog com.batterycommander.watchdog is loaded`
  - `config limits: 86/85 (authoritative); last_session mode: idle`
  - `reapplied configured limit 86/85 via dispatch` (config written 86/85,
    pct=87 BCLM=10)
  - `Reconciler: PCT=87% >= LOWER=85% - holding (no discharge)`
  - `BCLM read-back: 10 (expected 10 when holding, 100 when charging)`
  - `Reconciler: PCT=87% > UPPER=86% post-launch - asserting idle for watchdog`
- Battery at launch (bc-status, read-only): 87.4%, IsCharging No,
  ExternalConnected Yes, BCLM 10, Health 75.9%, Cycle 568. No SMC modification.

## 6. Enforcement state — unchanged (as designed)

- Old daemon still running and enforcing: PID 88736
  (`/Library/Application Support/battopt/battopt daemon`) — untouched.
- bc-limit daemon plist installed (`/Library/LaunchDaemons/`, 2,073 B,
  root:wheel, 644) but NOT loaded (Phase C gate intact).
- Watchdog still ticking every 60 s (heartbeats 18:46:32, 18:47:32 — PCT=87
  BCLM=10 cfg=86/85 mode=hold APG=yellow backend=bclm).
- `~/SwiftBar/` contains ONLY `battery-commander.10s.sh` (42,834 B) — no empty
  old-plugin file was re-created.

## 7. What needs Yousef

- **Visual icon check (his):** confirm the new logo shows on
  `/Applications/BatteryCommander.app` in Finder/Dock/Launchpad and in the
  About dialog (click About in the menu — expected: new logo after the
  step 1–3 logo fixes).
- Nothing else: no Gatekeeper dialog appeared, no sudo step was needed, no
  further action is required for this install.
- Still open (other tasks): sudoers verification (decision 8 — output not yet
  received); 14-agent repointing (parallel task); dead-file removal at deploy
  (approved; `.baks` purge Nov 13–14); Phase C (rejected unless necessary).
