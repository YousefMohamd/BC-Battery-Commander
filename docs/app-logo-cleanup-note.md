# App logo refresh + old app cleanup — Battery Commander (BC)

**Date:** 2026-11-10. **Status: COMPLETE.** Yousef's instructions (19:18 EET):
(1) change the app logo to the new PNG logo too; (2) there is an application named
`battopt.app`; (3) get rid of the old version of the app. (His 4th question —
how/when to test the project — is answered by the main agent in chat, not here.)

## 1. Full app-bundle inventory (read-only, before any change)

| # | Path | CFBundleIdentifier | CFBundleName | IconFile | .icns md5 | Size | mtime |
|---|---|---|---|---|---|---|---|
| 1 | `/Applications/BatteryCommander.app` | com.batterycommander.launcher | Battery Commander | Battery Commander | **bf88d95d… (NEW, 848,315 B)** | 948K | 2026-11-10 16:12 |
| 2 | repo `app/BattOpt.app` | com.yousef.battopt.app | BattOpt | battopt | 2d8d334a… (OLD, 1,007,233 B) | 1.0M | 2026-10-07 23:56 |
| 3 | repo `app/BatteryCommander.app` | com.batterycommander.launcher | Battery Commander | Battery Commander | **bf88d95d… (NEW, 848,315 B)** | 948K | 2026-11-10 16:12 |
| 4 | bc-build `BattOpt.app.installed-backup-20261110` | com.yousef.battopt.launcher | BattOpt | battopt | 2d8d334a… (OLD, 1,007,233 B) | 1.1M | 2026-10-25 19:30 |
| 5 | `/Users/Yousef/BattOpt-Installer/BattOpt.app` | com.yousef.battopt.app | BattOpt | battopt | 2d8d334a… (OLD, 1,007,233 B) | 1.0M | 2026-10-07 23:55 |
| 6 | 18× `/Applications/BattOpt.app.backup-YYYYMMDD-HHMMSS` | com.yousef.battopt.launcher (sample 20261025-193056) | BattOpt | battopt | 2d8d334a… (OLD, 1,007,233 B) | **18M total** | Oct 21–25, 2026 |
| 7 | `BattOpt-CC-Release.bak-pre-consolidation-20261014-1815/app/BattOpt.app` | (not read — inside the old backup folder) | BattOpt | battopt | (not read) | — | — |
| 8 | repo `src/native/BattOpt.app` | (not read — dropped native-app build artifact) | BattOpt | battopt | (not read) | — | — |

Notes:
- `/Applications` contains exactly ONE live `.app` matching batt: `BatteryCommander.app`.
  No `BattOpt.app` and no `battopt.app` live in /Applications.
- Desktop/Downloads: no `.app` at all.
- The 18 backup dirs (#6) are timestamped backups of the old app (Oct 21–25), created
  by the old build process. Two are root-owned (`20261021-152223`, `20261023-031800`),
  the rest Yousef:wheel.
- `applet.icns` md5 `220ad36a…` (71,867 B) is identical in the old and new bundles
  (default AppleScript applet icon, unused — the bundle icon is the named .icns).

### Dock persistent-apps (read-only)

`defaults read com.apple.dock persistent-apps | grep -i batt` → **nothing**.
There is NO BattOpt/BatteryCommander entry in the Dock's persistent apps. The app is
`LSUIElement` (menu-bar/login app, no Dock icon by design), so there is no Dock entry
to change. The "app icon" refresh is about Finder/Launchpad/Activity Monitor and the
running process's icon.

### `battopt.app` finding

**No exact lowercase `battopt.app` exists anywhere found** (Desktop/Downloads: none;
`/Applications`: none; `mdfind -name "battopt.app"` (case-insensitive) returned only
the backup dirs + the bc-build backup; case-insensitive filesystem `find` over
Projects/Desktop/Downloads/Documents (maxdepth 4) returned only the two `BattOpt.app`
copies #7 and #8 above). Yousef's "battopt.app" is a loose reference to one of the
`BattOpt.app` copies — the old version, which is what §3 deletes.

## 2. App logo refresh — installed bundle already had the new icon

- Installed `/Applications/BatteryCommander.app` `.icns` md5 **`bf88d95d…` (NEW)**
  — verified BEFORE the restart. No `ditto` was needed; the icon file was already
  correct. The running launcher (PID 5462, launched 18:48 with the OLD .icns) had
  the old icon cached, so the refresh is a launcher restart.
- **Kill decision (delegated, same method Yousef approved 18:43 EET): `kill` (SIGTERM)
  to PID 5462**, not a normal quit. Reason (confirmed by reading
  `src/app/BatteryCommander.applescript`): a normal quit triggers the `on quit`
  handler, which runs new `dispatch.sh shutdown --force` — and the new dispatch
  shutdown releases the limit (`bc_apply_limit 100 99`), which would rewrite the
  new-dir config from 86/85 to 100/99. `kill` skips the handler; the config stays
  86/85 and the battery state does not change. The old daemon (PID 88736) and the
  agents are separate processes and are UNAFFECTED.
- Pre-kill check: the bash child (PID 5465, from the 18:48 launch) was ALREADY gone
  (`pgrep -f "BatteryCommander-launcher"` → rc=1); the applet (5462, PPID 1) had no
  children (`pgrep -P 5462` → rc=1). Killing the applet leaves no orphan.
- **After kill:** `APPLET-GONE`, `NO-LAUNCHER-CHILD`, old daemon still running
  (PID 88736). bc-status (read-only): Capacity 86.8%, BCLM 10, IsCharging No,
  ExternalConnected Yes — UNCHANGED.
- **Relaunch:** `open /Applications/BatteryCommander.app` (exit 0, no Gatekeeper
  dialog). **New applet PID 7952** (PPID 1). Launcher log
  (`~/.battery-commander/actions.log`, 19:22:40): `=== LAUNCH START ===`
  ("Battery Commander (BC)"), config limits 86/85 (authoritative),
  `bc_apply_limit: config written 86/85 (pct=86 BCLM=10)`,
  `reapplied configured limit 86/85 via dispatch`,
  `Reconciler: PCT=87% >= LOWER=85% - holding (no discharge)`,
  `BCLM read-back: 10`, `PCT=87% > UPPER=86% post-launch - asserting idle for
  watchdog`, plugin present in ~/SwiftBar, `=== LAUNCH COMPLETE in 5s ===`.
- **Battery state unchanged across all four readings** (before kill / after kill /
  after relaunch / final): Capacity 86.8%, BCLM 10, IsCharging No, ExternalConnected
  Yes, Health 75.9%, Cycle 568. No SMC modification (all reads read-only).
- Watchdog still ticking (19:22:43 heartbeat: PCT=87 BCLM=10 cfg=86/85 mode=hold
  APG=yellow backend=bclm).
- The new launcher loaded at 19:22 with the NEW .icns (`bf88d95d…`) in the bundle,
  so its icon is now the new dark logo. Visual confirmation (Finder/Dock/Launchpad)
  is Yousef's.

## 3. Deletions — old app versions (trash, recoverable, File API two-phase)

Method: File API delete/prepare with `recursive: true` (the server's own requirement
for non-empty dirs — `delete_file.py` without it fails HTTP 400 "directory not empty;
use recursive: true") + delete/confirm. Both went to the File API trash dir
(`/Users/Yousef/muse-fileapi/.muse-fileapi/trash/`); recover manually from there.
Helper: `battopt-project/bc-build/delete_recursive.py` (local copy in
`~/workspace/bc-build/delete_recursive.py`).

| # | Deleted path | Size | .icns md5 | confirmId | Trash location |
|---|---|---|---|---|---|
| (a) | repo `app/BattOpt.app` (stale, approved removal list 17:46 EET) | 1.0M | 2d8d334a… (OLD) | ac17c06d-9ae6-4281-b9d1-849302cd671a | `…/trash/2026-11-10T17-23-05-411Z___Users_Yousef_Projects_BattOpt-CC-Release_app_BattOpt.app` |
| (b) | bc-build `BattOpt.app.installed-backup-20261110` (Yousef 19:18 EET: get rid of the old version) | 1.1M | 2d8d334a… (OLD) | 3eab937d-6e75-4236-a32c-f448b91668c9 | `…/trash/2026-11-10T17-23-18-764Z___Users_Yousef_Projects_BattOpt-CC-Release_battopt-project_bc-build_BattOpt.app.installed-backup-20261110` |

Verified after deletion: repo `app/` contains ONLY `BatteryCommander.app`;
bc-build/ no longer contains the backup (grep matches are only files with "app" in
their names: `BatteryCommander.applescript.pre-w6`, `app-install-note.md`,
`build-app.sh.pre-w5/w6`, `w*-apply-*.py`).
**NOT deleted:** `/Applications/BatteryCommander.app` and repo
`app/BatteryCommander.app` (the new ones). Nothing else was deleted.

## 4. NOT deleted — old-version copies found, reported for Yousef's decision

These are old-version copies OUTSIDE the task's explicit deletion list; they were
left in place and are reported here (not deleted):

- **18× `/Applications/BattOpt.app.backup-*` (18M total, Oct 21–25)** — timestamped
  backups of the old app (bundle ID com.yousef.battopt.launcher, battopt.icns
  2d8d334a…). Two are root-owned (would need sudo to remove). Deleting them is a
  bigger action than this task authorized; needs Yousef's explicit say-so on these
  specific paths.
- **`/Users/Yousef/BattOpt-Installer/BattOpt.app` (1.0M, Oct 7)** — the installer
  copy (bundle ID com.yousef.battopt.app, battopt.icns 2d8d334a…). Deleting it would
  break the old installer folder; needs an explicit decision.
- **`BattOpt-CC-Release.bak-pre-consolidation-20261014-1815/app/BattOpt.app`** —
  inside the old pre-consolidation backup folder (the whole folder is a backup;
  do not touch its contents).
- **repo `src/native/BattOpt.app`** — build artifact of the dropped native Swift app
  (W0 DROP verdict); a source-tree artifact, not an installed app.

## 5. Final verification (all read-only unless noted)

- New applet running: **PID 7952** (`/Applications/BatteryCommander.app/Contents/MacOS/applet`).
- Old daemon still running and enforcing: **PID 88736** (untouched).
- Installed `.icns`: **bf88d95d… (NEW)**.
- Login items (read-only): Macs Fan Control, Keyboard Maestro, SwiftBar, Android
  File Transfer Agent, **BatteryCommander** (`/Applications/BatteryCommander.app`) —
  correct, unchanged.
- Repo `app/`: ONLY `BatteryCommander.app`. `/Applications` `.app` matching batt:
  ONLY `BatteryCommander.app`. The 18 `.backup-*` dirs remain (see §4).
- bc-status final: Capacity 86.8%, BCLM 10, IsCharging No, ExternalConnected Yes,
  Health 75.9%, Cycle 568 — unchanged. Watchdog ticking (19:22:43 heartbeat).
- No sudo, no launchctl load/unload, no bc-limit daemon load (Phase C), no
  commit/push, no live battery tests, no SMC writes, no /etc/sudoers.d, no agent
  plist or login-item changes, no deletions other than §3.

## 6. What needs Yousef

- **Visual icon check (his):** confirm the new dark logo on
  `/Applications/BatteryCommander.app` in Finder/Dock/Launchpad and in the About
  dialog (click About — expected: new dark logo + the new "Battery Commander (BC)"
  text).
- **Decision on the remaining old copies (§4):** the 18× `/Applications/BattOpt.app.backup-*`
  (18M) and the `/Users/Yousef/BattOpt-Installer/BattOpt.app` installer copy — say
  the word and they go to trash too (note: 2 of the 18 backups are root-owned, so
  those two are a sudo step for him).
