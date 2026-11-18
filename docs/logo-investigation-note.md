# Logo investigation — old logo surfaces (READ-ONLY)

**Date:** 2026-11-10. **Status: investigation complete, nothing changed.**
**Trigger:** Yousef (18:33 EET): "the application and the logo still aren't done" and
"inside About Battery the old logo is still there."

## 1. The About dialog — root cause (confirmed)

- Menu item: `About Battery Commander...` — `src/plugin/battery-commander.10s.sh:684`
  (`bash=$DISPATCH param1=about`).
- Handler: `src/daemon-helpers/dispatch.sh`, `about)` branch (~line 1551):
  ```sh
  LOGO="$DASH/icons/battery-commander.png"
  [ -f "$LOGO" ] || LOGO="$DASH/icons/battopt.png"
  [ -f "$LOGO" ] && osascript - "$LOGO" <<'A'
  ...
  display dialog aboutText buttons {"OK"} default button "OK" \
      with title "About Battery Commander" with icon (POSIX file logoPath)
  ```
- The file `$DASH/icons/battery-commander.png` **does not exist in either state dir**,
  so the fallback fires and the dialog shows the OLD `battopt.png` (66,778 B, Oct 7).
  That is exactly what Yousef sees. No code change is needed for About — only the
  missing PNG file.

## 2. Full old-logo inventory (every place + the file behind it)

| # | Surface (what the user sees) | File behind it | Status |
|---|---|---|---|
| 1 | About dialog icon | `$DASH/icons/battopt.png` (fallback; `battery-commander.png` missing) | OLD logo shown |
| 2 | Notifications — `dispatch.sh` `notify()` (~line 441) | `ICON="$DASH/icons/battery-commander.png"`, fallback `battopt.png` | OLD logo shown |
| 3 | Notifications — plugin `notify` (`battery-commander.10s.sh:141`, `-appIcon` + `-contentImage $BC_ICON`) | `BC_ICON="$DASH/icons/battery-commander.png"` (missing → terminal-notifier shows no custom icon) | NO icon shown (not old, just absent) |
| 4 | Notifications — launcher `notify()` (`BatteryCommander-launcher.sh` ~line 44, `-appIcon "$DASH/icons/battery-commander.png"`) | Same missing file | NO icon shown |
| 5 | Notifications — `arm_sleep.sh` local `notify()` (line 31) | Hard-coded `$DASH/icons/battopt.png`, **but `-appIcon` is never passed** (ICON defined, unused) | NO logo shown (default icon); stale reference only |
| 6 | App icon in Finder / Dock / Launchpad + Login Items | `/Applications/BattOpt.app`, `CFBundleIconFile "battopt"` → `Contents/Resources/battopt.icns` (1,007,233 B, OLD) | OLD logo shown |
| 7 | Login-item entry | `/Applications/BattOpt.app` (old) | OLD app launches at login |
| 8 | Repo source files | `assets/icons/battopt.icns` (1,007,233 B) + `assets/icons/battopt.png` (66,778 B) | Source only, not directly visible |
| 9 | State-dir copies (BOTH dirs) | `icons/battopt.icns` + `icons/battopt.png` (migrated 17:50, md5-verified) | Inert — nothing in the new stack references `.icns`; `.png` only as fallback |
| 10 | Dead-code references | `src/launcher/main.c` (DROP verdict), `src/native/build.sh` (native app DROPPED), `src/swiftbar-plugin/battopt.15s.sh` (DROP), backup `battopt.10s.sh.installed-backup-20261110` (`BATTOPT_ICON=.../battopt.png`) | Dead, not visible |
| 11 | Mode glyphs `charging.png` / `discharging.png` / `electric.png` (both state dirs) | **NOT the logo.** Zero references in the new stack (and none in the old plugin either — it only used `BATTOPT_ICON=battopt.png`). | Unused, not logo surfaces |
| 12 | Menu-bar icon | Emoji (🔋 / 🔴 / 🔌 / ⚡), no image file | Not a logo surface |

**New-logo assets that DO exist (for reference):**
- Repo-root `Battery Commander.png` — 3,328,469 B, 3508×2964 px, 16-bit, hasAlpha.
- `assets/icons/Battery Commander.icns` — 764,914 B, md5 `0314bdfa34d95b2f8e6b909ca9745941`.
- Repo bundle `app/BatteryCommander.app` — `CFBundleIconFile "Battery Commander"`,
  `CFBundleName "Battery Commander"`, `CFBundleIdentifier com.batterycommander.launcher`;
  `Contents/Resources/Battery Commander.icns` md5 matches the assets copy. **NOT installed
  in /Applications, unsigned.**
- `build-app.sh` `find_icon()` checks, in order: `$HOME/.battery-commander/icons/Battery Commander.icns`
  → `$HOME/.battopt-swiftbar/icons/Battery Commander.icns` → `assets/icons/Battery Commander.icns`.
  Neither state dir has it; the repo copy is found third.

**State-dir `icons/` contents (verified by `ls`):**
- Old `~/.battopt-swiftbar/icons/`: `battopt.icns`, `battopt.png`, `charging*.png`,
  `discharging*.png`, `electric*.png`, `icon.iconset/`, `terminal-notifier.app/`, `tn.zip`.
  No `battery-commander.png`, no `Battery Commander.icns`.
- New `~/.battery-commander/icons/`: identical migrated set (13 files). No
  `battery-commander.png`, no `Battery Commander.icns`.

## 3. What the user actually sees now

- The app he opens / the login item = `/Applications/BattOpt.app` (OLD:
  `CFBundleName BattOpt`, old icon, old launcher PID 2204).
- The About dialog = old `battopt.png` (fallback — §1).
- Notifications = old `battopt.png` (dispatch) or no custom icon (plugin/launcher).
- The menu-bar icon = emoji (no logo file involved).
- The repo bundle with the new logo exists but is not installed — that is why
  "the application and the logo still aren't done."

## 4. Fix plan (recommended order)

### Fix 1 — Add the new-logo PNG (fixes About + all notifications, no code change)
- Generate `battery-commander.png` (~512×512, from repo-root `Battery Commander.png`
  via `sips` — same native-tools rule as the `.icns` task, never ImageMagick/Pillow)
  and place it at `~/.battery-commander/icons/battery-commander.png` (canonical new dir).
- This fixes surfaces #1–#4 at once: the code already looks for that exact filename
  first (`battery-commander.png`, lowercase, hyphen). Verify by file presence + Yousef
  clicking About.
- Do NOT also put it in the old dir (the old system is being retired; keep the old
  dir as fallback).

### Fix 2 — `arm_sleep.sh` notify (small code fix)
- `src/daemon-helpers/arm_sleep.sh` line 31: `ICON="$DASH/icons/battopt.png"`, and the
  notifier call never passes `-appIcon` (ICON is dead code there).
- Fix: point ICON at `$DASH/icons/battery-commander.png` AND add `-appIcon "$ICON"`
  to the terminal-notifier call. Repo edit + redeploy via `deploy-populate.sh`
  (re-runnable). Without the `-appIcon` addition, changing the filename alone shows
  nothing.

### Fix 3 — (Optional) `.icns` in the state dir
- Copy `Battery Commander.icns` → `~/.battery-commander/icons/Battery Commander.icns`
  (`find_icon()` first check; makes the state dir self-contained for future rebuilds).
  Not required for any visible surface — the repo copy already satisfies `build-app.sh`.

### Fix 4 — Install the new app to /Applications (the "application" part)
Current state: installed `/Applications/BattOpt.app` (old, `com.yousef.battopt.launcher`,
`CFBundleName BattOpt`, old icon, launcher PID 2204, login item
`/Applications/BattOpt.app`); repo `app/BatteryCommander.app` (new, unsigned).
Steps (NOT done — report only):
1. Quit the old launcher applet (PID 2204). NOTE: quitting triggers its `on quit`
   handler → runs OLD `dispatch.sh shutdown --force` (old dir, old `battopt` calls).
   Alternative is `kill` (skips the handler) — a Red action, do not do without
   Yousef's explicit say-so.
2. Install the new bundle as `/Applications/BatteryCommander.app` (new name + new
   bundle ID — do NOT overwrite in place under the old name) and remove
   `/Applications/BattOpt.app`. Recommend moving the old bundle to a backup location
   first (same "keep saved" principle Yousef set for the plugin), not deleting it.
   The installed `/Applications/BattOpt.app` is NOT on the approved removal list.
3. Switch the login item: remove `/Applications/BattOpt.app`, add
   `/Applications/BatteryCommander.app` (System Preferences → Users & Groups →
   Login Items, or `osascript`).
4. Launch the new app once. Unsigned → first launch may need right-click → Open on
   Catalina; no quarantine flag (built locally, not downloaded), so Gatekeeper should
   not block outright — verify on launch.
5. Verify: new icon in Finder/Dock, login item points at the new app, new launcher
   log shows startup checks, SwiftBar still runs, old launcher PID gone.
Risks:
- (i) **Leaving the old app as login item actively undoes the activation on every
  login.** Its step 5 force-reloads ALL `com.battopt.*` agents (undoes activation
  Step B — guardian/enforce/consolidated come back), re-applies `battopt limit`,
  and `touch ~/SwiftBar/battopt.10s.sh` re-creates an EMPTY old-plugin file (the old
  plugin was just moved to backup). The login-item switch is not cosmetic — it
  protects the activation.
- (ii) Installing the new app does NOT change enforcement: the old daemon (PID 88736)
  is still the enforcer until Phase C; the new launcher only checks the daemon, never
  loads it.
- (iii) Unsigned bundle — first-launch prompt possible (see step 4).
- (iv) The new launcher's `on quit` runs NEW `dispatch.sh shutdown --force` (new dir)
  — correct, but a behavior change vs the old quit handler.

### Fix 5 — Leave the old files in place
- Do NOT overwrite `battopt.icns` / `battopt.png` with the new logo. The code's
  first-choice filename is `battery-commander.png`; overwriting the fallback would
  also rebrand the old system's surfaces and lose the fallback distinction.
- State-dir `battopt.icns` files are inert (nothing references them). Repo
  `assets/icons/battopt.*` are source files; keep for reference (not on the approved
  removal list).

### Note for the future standalone menu-bar app (separate task, after stability is confirmed)
- It needs the new `.icns` as its app icon + a menu-bar template image derived from
  the new logo. The assets (`Battery Commander.png` + `Battery Commander.icns`) are
  ready. The current SwiftBar menu-bar icon is emoji, not an image file.

## Verification evidence (all read-only)

- `GET /info` OK; allowed root = `/Users/Yousef/Projects/BattOpt-CC-Release`.
- `grep About` → plugin:684, dispatch:1562; `dispatch.sh` about-branch read (lines
  1535–1575) and `notify()` read (lines 430–460).
- `ls` both state-dir `icons/` (13 files new dir, 15 entries old dir incl. subdirs);
  neither contains `battery-commander.png` or `Battery Commander.icns`.
- `PlistBuddy` on both bundles (installed: `battopt` / `BattOpt` /
  `com.yousef.battopt.launcher`; repo: `Battery Commander` / `Battery Commander` /
  `com.batterycommander.launcher`); bundle `.icns` md5 `0314bdfa…` matches assets copy.
- Login items read via `osascript`: `... /Applications/BattOpt.app` (old).
- Old launcher read in full (`/Applications/BattOpt.app/Contents/Resources/BattOpt-launcher.sh`):
  step 5 force-reloads all `com.battopt.*` agents; final `touch "$PLUGIN_DIR/battopt.10s.sh"`.
- New launcher `notify()` read (lines 25–70); new AppleScript read
  (`src/app/BatteryCommander.applescript`); installed `main.scpt` decompiled with
  `osadecompile` (runs `BattOpt-launcher.sh`, quit handler runs old dispatch shutdown).
- `grep` for `charging.png|discharging.png|electric.png` in new stack: zero hits;
  old plugin backup: only `BATTOPT_ICON=.../battopt.png` (line 21).
