# Logo (transparent PNG) + About / brand-text fix — Battery Commander (BC)

**Date:** 2026-11-10. **Status: COMPLETE.** Yousef tested ("عمل ممتاز") and gave two
instructions (18:53 EET): (1) the image must load as PNG the way HE made it — background
must NOT be white; he downloaded the correct version `Battery Commander-.png`;
(2) edit the About info and most informational content inside (tool usage + our brand),
using "BC" as the abbreviation next to the main name.

## 1. The correct PNG — found + verified

- **Location:** repo root `/Users/Yousef/Projects/BattOpt-CC-Release/Battery Commander-.png`
  (found by `find` in the repo root; NOT in Downloads/Desktop — it landed in the repo).
  mtime **Nov 10 18:51** (matches the download, ~18:50–18:53 EET).
- **File:** 4,592,890 B, md5 `b0c478cbc373124d7bcef811c3e68d24`.
  PIL: 3508×2614, RGBA, 16-bit, 600 dpi, hasAlpha yes.
- **Pixel decode (Pillow, direct):** transparent = **0.0%**, opaque = 100%,
  white-opaque = **11.6%**. Corners: top (128,128,128,255) grey, bottom (0,0,0,255)
  black — a **DARK grey→black gradient background**, NOT transparent, NOT white.
  The 11.6% white is logo elements (battery/text), not a background.
- **Correction to the task's assumption:** the task assumed the correct PNG would be
  transparent (alpha=0 background). It is NOT transparent — it is opaque with a DARK
  background. Yousef's requirement was "background not white", and this file delivers
  exactly that (dark, as he made it). The regeneration below preserves his dark
  background and pads transparently (never white).

## 2. The white-background bug — confirmed by pixel decode

- **Repo-root `Battery Commander.png`** (3,328,469 B, md5 `a517de6c…`, 3508×2964):
  transparent = **0.0%**, white-opaque = **79.0%**, corners (255,255,255,255) white.
  This was the source for the old 512 PNG + old .icns. The icon note's claim
  "(transparent background)" was WRONG — `hasAlpha: yes` does not mean the background
  is transparent; the alpha channel is all 255 (opaque). That is the root of the bug.
- **Old state-dir `battery-commander.png`** (512×512, 149,164 B, md5 `242b6758…`):
  corners transparent (sips padding) but **59.5% white-opaque interior** — a white
  square with the logo. That is what Yousef saw in About/notifications.
- **Old `.icns`** (764,914 B, md5 `0314bdfa…`): same — transparent corners,
  **62.3% white-opaque interior** (via sips → PNG check at 1024).

## 3. Regenerated files (all from the correct PNG, sips only — no ImageMagick/Pillow)

- `square.png`: `sips --padToHeightWidth 3508 3508` → 3508×3508, 8-bit, hasAlpha yes,
  2,065,170 B, md5 `1d2558fdb348ce759bea53c3f7edd9e3`. Pixel decode: corners
  (0,0,0,0) transparent (padding 25.4%), dark background (128 grey / 0 black),
  white-opaque 8.7% (logo elements only).
- **New state-dir `battery-commander.png`**: `sips -z 512 512` from square.png →
  512×512, **163,028 B, md5 `159f9d6687024afdc351398e9a226b89`**, placed at
  `~/.battery-commander/icons/battery-commander.png` (old dir untouched).
  Pixel decode: corners (0,0,0,0) transparent, dark background,
  white-opaque **2.1%** (logo elements only — down from 59.5%). **Bug fixed.**
- **New `.icns`**: 10-image `.iconset` from square.png (`sips -z` 16/32/64/128/256/
  512/1024 + @2x) → `iconutil -c icns` → **848,315 B, md5
  `bf88d95db5a78225f70f4e3492be3afd`**. Converted check (1024): corners transparent,
  dark background, white-opaque **4.5%** (down from 62.3%).
- **Old `.icns` backed up** (not deleted): `battopt-project/bc-build/Battery Commander.icns.pre-white-bg-fix`
  (764,914 B, md5 `0314bdfa…`).
- **Placement:** new `.icns` → `assets/icons/Battery Commander.icns` AND
  `~/.battery-commander/icons/Battery Commander.icns` (both md5 `bf88d95d…`).
  **Important:** `build-app.sh` `find_icon()` checks the state-dir `.icns` FIRST —
  the first rebuild used the OLD state-dir `.icns` (0314bdfa…); I updated the
  state-dir copy to the new one and rebuilt again.
- **Bundle rebuilt + reinstalled:** `src/app/build-app.sh --test` (PASS: all required
  app checks passed) → `ditto` to repo `app/BatteryCommander.app` → `ditto` to
  `/Applications/BatteryCommander.app`. Verified: repo + installed bundle `.icns`
  md5 `bf88d95d…` (new). Installed launcher md5 `69cdbee7…` (new text, §5).
  Launcher still running (PID 5462) — not killed/quit; the Dock icon refreshes on
  next launch/logout (the running process loaded its icon at launch).
- **Old `battopt.icns` / `battopt.png` untouched everywhere** (Fix 5).

## 4. NEW About text (verbatim — as it will appear in the dialog)

Title: **"About Battery Commander (BC)"**. The limit is dynamic
(`$LAST_UPPER` / `$LAST_LOWER`, defaults 86/85, passed as argv to osascript).

```
Battery Commander (BC)
Independent battery charge-limit tool.

Keeps your battery between the limits you set.
Limit: 86% / 85% — hold at the upper, resume at the lower.

Sailing mode: keeps the battery between upper and lower.

Smart Discharge / Calibration:
Arrive in later phases — not in v1.
```

AppleScript compiles OK (`osacompile`, /tmp/about-test.scpt 3,332 B).
No dialog was opened and no notification was triggered — Yousef clicks About to
confirm visually.

## 5. Informational-text changes (brand: "Battery Commander (BC)")

Edit script: `battopt-project/bc-build/brand_text_fix.py` (local + Mac copy).
Backups (before editing): `dispatch.sh.pre-brand-text-fix` (md5 `f4095d71…`),
`battery-commander.10s.sh.pre-brand-text-fix` (md5 `a6c2db74…`),
`BatteryCommander-launcher.sh.pre-brand-text-fix` (md5 `b368f2dc…`).
All replacements verified by exact count before writing (two-phase script);
one run aborted on a trailing-space mismatch in the About block (fixed, re-ran clean).

- **dispatch.sh** (76,953 B, md5 `cad0ff1f3eb0f3aec58079bc6e29068b`):
  78 notify titles → "Battery Commander (BC)"; 5 bare dialog titles → "(BC)";
  5 suffixed dialog titles → "Battery Commander (BC) - …"; About title → "(BC)";
  Details header → "=== Battery Commander (BC) Status ===" + title
  "Battery Commander (BC) - Details"; Reset dialog → "Reset all Battery Commander
  (BC) settings…"; notify() stale comment updated (rebrand is installed);
  2 shutdown comments updated; About block rewritten (dynamic limits, §4);
  osascript now passes limits as argv. Total "Battery Commander (BC)" in file: 95.
- **battery-commander.10s.sh** (42,717 B, md5 `6c00b97363327b084faca80732919d39`):
  xbar.title → "Battery Commander (BC) Control Center"; xbar.desc → "(BC) — …";
  plugin comment → "Battery Commander (BC) plugin v2.0.0"; notifier -title → "(BC)";
  daemon_recovery title → "(BC)"; "Open Battery Commander Logs" → "Open Battery
  Commander (BC) Logs"; "About Battery Commander..." → "About Battery Commander
  (BC)..."; Calibration description "Runs a full discharge then charge cycle." →
  **"Not in v1 yet — arrives in a later phase."** (calibration is not in v1 — the
  old text implied it works); stale login-item comment updated (installed app is
  now BatteryCommander.app). Total occurrences: 7.
  Button/action names UNCHANGED (same buttons in this shape). "Open Battery
  Commander.app" left as-is (file name). "Remove Hold (return to 86/85%)" left
  as-is (deliberate W6.3 label).
- **BatteryCommander-launcher.sh** (9,933 B, md5 `69cdbee763d420dd3dba789afc94c189`):
  comment → "Battery Commander (BC) Launcher (W5.1)"; log prefix → "Battery
  Commander (BC): …"; 3 notify titles → "(BC)".
- **display_state.sh**: no user-facing brand text (code comments + mode logic only) —
  left unchanged.

## 6. Verification

- `bash -n` OK (dispatch.sh, plugin, launcher.sh).
- `deploy-populate.sh` (via `bash` — direct execution failed "Permission denied",
  exec bit stripped by File API): **21/21 files OK, FAIL=0**, all +x.
- Deployed md5s match repo: state-dir dispatch.sh `cad0ff1f…` = repo;
  SwiftBar plugin `6c00b973…` = repo (cp -p + chmod +x);
  /Applications launcher `69cdbee7…` = repo; /Applications .icns `bf88d95d…` = new.
- Grep (deployed): state-dir dispatch.sh 95 × "Battery Commander (BC)",
  78 × `notify "Battery Commander (BC)"`; SwiftBar plugin 7 ×.
- About-path simulation: **FIRST-CHOICE-EXISTS**
  (`~/.battery-commander/icons/battery-commander.png`, 163,028 B) — fallback no
  longer fires.
- AppleScript compile OK (see §4). No dialog opened, no notification triggered.
- No sudo, no launchctl load/unload, no bc-limit daemon load (Phase C),
  no deletions, no commit/push, no live battery tests, no SMC writes.
- Scratch left in place (harmless, ephemeral /tmp): `/tmp/bc-logo2/` (square.png,
  iconset, .icns, check PNGs), `/tmp/bc-icns-check.png`, `/tmp/about-test.applescript`,
  `/tmp/about-test.scpt` (`rm -rf` blocked by the /run safety policy).

## 7. What needs Yousef (testing)

- Click **About** in the menu — expected: new dark (not white) logo + the new text in §4.
- Check the app icon in Finder/Dock — expected: new dark logo (may need a logout or
  relaunch of the app to refresh the Dock icon; Finder should show it).
- If anything in the About/info text should change during testing, say so and it will
  be adjusted.
