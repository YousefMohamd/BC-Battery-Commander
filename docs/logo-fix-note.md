# Logo fix — steps 1–3 (About + notifications now use the new logo)

**Date:** 2026-11-10. **Status: COMPLETE.** Steps 1–3 only (file fixes).
Nothing installed to /Applications, no login-item change, no process touched,
no sudo, no launchctl, no deletions, no commit/push, no live battery test,
no dialog opened, no notification triggered.

## 1. New-logo PNG — `~/.battery-commander/icons/battery-commander.png`

- Source: repo-root `Battery Commander.png` (3,328,469 B, 3508×2964 px,
  16-bit, hasAlpha).
- Generated on the Mac with `sips` ONLY (native macOS tool — no ImageMagick,
  no Pillow): `sips --padToHeightWidth 3508 3508` → square (transparent
  padding, same as the `.icns` task) → `sips -z 512 512`.
- Result: **512×512 px, hasAlpha: yes, 149,164 B,
  md5 `242b6758a6ecb3082412bd1bdb8c9398`**.
- Placed in the NEW state dir ONLY (`~/.battery-commander/icons/`).
  The old dir was not touched.
- This single file fixes the About dialog + all notifications: the code
  already looks for `battery-commander.png` first (`dispatch.sh` about
  branch, `notify()`, plugin `BC_ICON`, launcher `notify()`).

## 2. `arm_sleep.sh` notify fix

- Repo copy `src/daemon-helpers/arm_sleep.sh` read first (6,765 B, 154 lines).
- Line 31: `local ICON="$DASH/icons/battopt.png"` →
  `local ICON="$DASH/icons/battery-commander.png"`.
- Line 33: added `-appIcon "$ICON"` to the terminal-notifier call
  (ICON was dead code there — never passed before).
- Backup: `battopt-project/bc-build/arm_sleep.sh.pre-logo-fix` (6,765 B,
  original, written once).
- Edit script: `battopt-project/bc-build/logo-fix-arm_sleep.py` (local copy
  `~/workspace/bc-build/logo-fix-arm_sleep.py`); both replacements verified
  exactly-once before writing.
- New repo md5: `f283e00688ab3fbc8ea4c023f94304e9` (6,792 B); `bash -n` OK.
- Redeployed via re-runnable `battopt-project/bc-build/deploy-populate.sh`:
  **21/21 files OK, FAIL=0**. Deployed copy verified by grep (lines 31, 33)
  + md5 match with the repo copy.

## 3. `.icns` in the state dir

- Copied repo `assets/icons/Battery Commander.icns` (764,914 B) →
  `~/.battery-commander/icons/Battery Commander.icns`.
- md5 `0314bdfa34d95b2f8e6b909ca9745941` — matches the repo source.
- `find_icon()` first check; makes the state dir self-contained for
  future rebuilds. Not required for any visible surface (the repo copy
  already satisfies `build-app.sh`).

## 4. About-path verification (simulation only — no dialog opened)

Simulated the exact `dispatch.sh` about-branch fallback logic in `sh`:
```sh
LOGO="$DASH/icons/battery-commander.png"
[ -f "$LOGO" ] || LOGO="$DASH/icons/battopt.png"
```
- Result: `ABOUT-LOGO=/Users/Yousef/.battery-commander/icons/battery-commander.png`
  — **FIRST-CHOICE-EXISTS**. The fallback no longer fires.
- `ls -l` confirms all three files in the new dir: `Battery Commander.icns`
  (764,914 B), `battery-commander.png` (149,164 B), `battopt.png`
  (66,778 B, old fallback — left untouched per Fix 5).
- No `about)` branch was executed and no UI dialog/notification was
  triggered on the user's Mac. Final visual confirmation is Yousef
  clicking About (expected: new logo).

## Not done — fix step 4 (needs Yousef's separate approval)

- `/Applications` install of `app/BatteryCommander.app` + login-item switch
  (old `/Applications/BattOpt.app` still installed and still the login item).
  See the investigation note §4 for the full plan and the risks (notably:
  the old login item force-reloads all `com.battopt.*` agents on every login,
  undoing activation Step B, and re-creates an empty old-plugin file).

## Scratch

- `/tmp/bc-logo/square.png` (intermediate, ephemeral) left in place;
  `rm -rf` is blocked by the /run safety policy — harmless, same as the
  `/tmp/bc-icon/` scratch from the `.icns` task.
