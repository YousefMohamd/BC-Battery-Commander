# App icon completion note — Battery Commander logo (.icns)

**Date:** 2026-11-10. **Status: COMPLETE.** The app bundle now carries the new
logo as its icon. Code/build work only — nothing installed to /Applications,
no agent/daemon install or load, no Phase C, no live battery test, no file
deletions, no commit/push, no signing (signing is a deploy step).

## 1. Icon source

- Source: repo-root `Battery Commander.png` (the new logo Yousef added).
- Size: **3,328,469 B**; dimensions **3508 × 2964 px**; PNG, RGB, 600 dpi.
- **16-bit per sample, hasAlpha: yes** (transparent background).
- Aspect is not square (3508:2964 ≈ 1.18:1), so the icon was padded to
  square rather than stretched.

## 2. How the .icns was made (native macOS tools only)

- `sips --padToHeightWidth 3508 3508` → `/tmp/bc-icon/square.png`
  (3508×3508, 8-bit, hasAlpha yes — sips converted 16-bit → 8-bit on pad).
- Padding verified transparent, centered: direct pixel decode of square.png
  rows 0–2 = all `(0,0,0,0)`; rows 270–274 = transparent (alpha ≤ 2);
  row 300 = logo content (156 unique colors, 48 opaque). No `--padColor`
  was needed — sips pads transparently for images with alpha.
  (Note: a 64×64 downscale row-scan looked inconsistent at first — rows
  16/32 fully transparent, row 60 mostly opaque — that was downscale
  aliasing of the logo's fine detail, not a padding problem; the direct
  row decode settles it.)
- `sips -z` from square.png into a 10-image `.iconset` (16, 32, 128, 256,
  512, 1024 + all @2x variants), all 8-bit RGBA. File sizes are substantial
  (16×16: 1,615 B; 1024: 418,508 B) — none blank.
- `iconutil -c icns` → `/tmp/bc-icon/Battery Commander.icns`.
- No ImageMagick (verified bugs on this Mac), no Pillow — sips + iconutil only.
- Work was done in `/tmp/bc-icon/` (iconset, square.png, check scripts);
  temp dir removed after the build.

## 3. .icns verification (parsed the icns element table)

- File: **764,914 B**, md5 `0314bdfa34d95b2f8e6b909ca9745941`.
- Header total-size field = 764,914 = actual file size; 11 elements,
  end position = file size (structurally complete).
- Elements: ic12 32×32@2x (3,555 B), ic07 128×128 (11,716 B),
  ic13 128×128@2x (40,199 B), ic08 256×256 (40,199 B), ic04 (358 B),
  ic14 256×256@2x (136,971 B), ic09 512×512 (136,971 B), ic05 (1,064 B),
  ic10 1024×1024 (392,305 B), ic11 64×64 (1,250 B), info (318 B).
  Every resolution present (16/32/64/128/256/512/1024); none empty.
- Content check (pure-Python PNG decode, no ImageMagick/Pillow):
  icon_16x16.png = 110 unique colors, real content in every row
  (incl. opaque and colored pixels) — not blank.
  icon_512x512@2x.png = 44,508 unique colors; row 0 and row 1023 fully
  transparent (top/bottom padding bars), row 768 = 120 unique colors.

## 4. Placement (no build-app.sh change needed)

- `src/app/build-app.sh` `find_icon()` already looks for
  `$SCRIPT_DIR/../../assets/icons/Battery Commander.icns` — the .icns was
  placed at **`assets/icons/Battery Commander.icns`** (764,914 B,
  md5 `0314bdfa34d95b2f8e6b909ca9745941`, matches the /tmp original).
- The old `assets/icons/battopt.icns` (1,007,233 B) was NOT touched.
- build-app.sh was read before the build; it needed no edit.

## 5. Bundle rebuild + verification

- Rebuilt with `src/app/build-app.sh --test` (exit 0):
  `Icon copied: .../assets/icons/Battery Commander.icns`,
  `Build completed: /tmp/BatteryCommander.app`,
  `PASS: all required app checks passed`.
- /tmp bundle checks: applet `Mach-O 64-bit executable x86_64`;
  CFBundleExecutable `applet`; CFBundleIdentifier
  `com.batterycommander.launcher`; LSUIElement `true`;
  `Battery Commander.icns` present; launcher present + executable;
  CFBundleIconFile `Battery Commander`; CFBundleName `Battery Commander`.
  codesign: `code object is not signed at all` (expected — deploy step).
- Repo bundle `app/BatteryCommander.app` updated via `ditto` from /tmp
  (no delete: `find` showed the ONLY difference between old and new
  bundle was the added `Battery Commander.icns`, so a merge left no stale
  files; the File API delete of the old bundle was attempted first and
  refused with HTTP 400 "directory not empty; use recursive: true" —
  the ditto merge made it unnecessary).
- Repo bundle verified in place: icon md5
  `0314bdfa34d95b2f8e6b909ca9745941` (matches); launcher 9,923 B,
  executable, md5 `b368f2dc81dc312a195c485f1074005e` (matches /tmp build);
  applet Mach-O 64-bit x86_64; CFBundleIconFile `Battery Commander`;
  CFBundleName `Battery Commander`; CFBundleIdentifier
  `com.batterycommander.launcher`; LSUIElement `true`;
  CFBundleExecutable `applet`; codesign: not signed at all.
- Note: the default `applet.icns` (71,867 B) remains in Resources — it is
  unused because CFBundleIconFile points at `Battery Commander`.

## 6. What still blocks / not done (deploy steps, unchanged)

- Signing the bundle (no certificate configured here; deploy step).
- Install to /Applications (user step, `build-app.sh --install` uses sudo).
- State-dir migration, agent/daemon install or load, Phase C — all still
  gated on Yousef's deploy approvals (W6 CONDITIONAL PASS blockers).
- Nothing was deleted, renamed, moved, committed, or pushed in this task.
