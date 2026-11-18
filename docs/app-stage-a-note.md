# Standalone App — STAGE A (Bench Build) Note — 2026-11-14

Approved by Yousef 2026-11-14 20:21 EET ("ابدأ المرحلة A من التطبيق المستقل").
Governed by `standalone-app-design.md`. **Bench only**: nothing installed,
/Applications untouched, login item untouched, SwiftBar/plugin untouched.

## Headline

**Stage A COMPLETE.** The native Swift + AppKit app builds clean from
scratch on the first attempt, its menu is machine-verified **identical
to the current plugin's menu (146/146 canonical lines)**, it ran live
in the menu bar holding the correct state on a 10 s cadence, and it
was quit at the end — the menu bar is back to exactly one BC UI (the
plugin). Live system verified untouched: 86% hold, BCLM=10, config
86/85, daemon/watchdog/sentinel all healthy.

## Build result

- Toolchain: CLT `swiftc` 5.3.2 (x86_64-apple-darwin19.6.0), target
  `x86_64-apple-macos10.15`, UI 100 % in code, manual bundle assembly
  (build-app.sh pattern), ad-hoc signature. **Zero errors, zero
  warnings** (build log: `battopt-project/bc-build/app-stage-a/build.log`).
- The design's §11 step-1 spike risk (CLT-only Swift friction) did
  **not** materialize: no SDK/module/linking dead-ends. The ObjC
  fallback (§2.4) was not needed.
- Bundle: `src/app/build/BatteryCommander.app` — **1.5 MB** total;
  executable verified `Mach-O 64-bit executable x86_64`;
  `Identifier=com.batterycommander.launcher`, `Signature=adhoc`;
  Info.plist carries LSUIElement=true, the existing BC `.icns`
  (md5 `bf88d95d…`) as `Battery Commander.icns`, version 1.0.
- Sources (all in repo `src/app/`, next to the launcher applet files):
  `main.swift` (entry + `--dump-menu`), `Shell.swift` (process runner),
  `StatusProvider.swift` (the plugin's data collection, ported 1:1),
  `MenuModel.swift` (menu as data + canonical dump), `AppDelegate.swift`
  (status item, 10 s timer, action runner), `Info.plist`,
  `build-app-native.sh` (clean build → verify; has NO install path).

## Design decisions taken inside the approved design

- **Same sources, not re-derived values**: StatusProvider runs
  `bc-status` and the state's own **`display_state.sh`** (the sole
  icon/colour decider — executed, never re-implemented), reads the
  canonical config, ioreg, pmset, the daemon log, the verification
  state/summary, and every state file the plugin reads. Checkmarks
  and conditional items follow the plugin's exact rules.
- **No writes**: where the plugin refreshes cache files
  (.status_cache/.login_cache/.usb_cache/.wake_cache), the app only
  READS a fresh cache and otherwise computes the same value itself.
  The plugin's notification/audit side effects are not ported.
- **One model, two renderers**: the menu is built once as a data tree;
  the NSMenu and the `--dump-menu` text both render from that tree, so
  the verified dump is the shipped menu by construction.
- **Stage A scope guards**: Quit is a plain UI exit (amended FR-007's
  full shutdown is Stage C); launcher housekeeping (FR-006) is NOT
  performed by the bench app; the app never triggers state-changing
  actions during tests.

## Parity result (smoke test b)

Method: fresh headless plugin render captured on the Mac
(`battopt-project/bc-build/app-stage-a/plugin-render.txt`), then the
bench binary's `--dump-menu` seconds later (`app-dump.txt`); both
converted to one canonical form (title, tree order/indentation,
titles, ✓ state, dispatch action, open target, disabled flag, colour)
and diffed by `compare_parity.py` (copy in the same Mac folder +
`~/workspace/bc-build/app-stage-a/`). Volatile values normalized:
daemon tick age/timestamp, SwiftBar CPU/RAM, idle minutes, wake count.

**Result: PARITY PASS — 146 canonical lines identical.** Every title,
checkmark, state value and action matches, including the Calibration
section, the Verification submenu (live values: "Last full cycle:
Nov 13 — PASS", "Phase C: VERIFIED Nov 13"), the daemon lines, and
"Services: 17 agents loaded". Raw renders were both 148 lines.

Complete difference list — only the documented §5.3 deviations:

| # | Difference | Side | Basis |
|---|---|---|---|
| 1 | "Open Battery Commander.app" (open_app) absent | app | §5.3.1 — meaningless inside the app |
| 2 | "Refresh Now" runs the app's own refresh (no dispatch) | app | §5.3.2 — same title/position/effect |
| 3 | Extra separator + "Quit Battery Commander" at menu bottom | app | §5.3.3 — native convention; Stage A Quit = plain exit |

No other differences. No unexplained diffs.

## Smoke evidence

- **(a) Clean build**: `build-app-native.sh` always rebuilds from an
  empty `build/` — PASS lines for compile, ad-hoc sign, Mach-O type,
  bundle id, LSUIElement (log cited above).
- **(b) Dump parity**: PASS, above.
- **(c) Live launch**: executable launched detached 20:32:19 EET
  (PID 82040). Bench log: `launched` → first correct header
  `status: 🔌 86% mode=hold` at 20:32:20 (**≤ 1 s to first correct
  render**, NFR-003 ≤ 2 s), then ticks at exactly 10 s intervals
  (20:32:30/40/50, 20:33:00) all reading `🔌 86% mode=hold`.
  Footprint while running: **RSS 18,788 KB (~18 MB)**, 0.0 % CPU
  between ticks (NFR-001 ≤ ~30 MB ✓).
- **Menu-path clicking was NOT automatable**: UI scripting from the
  agent shell is denied by the OS ("osascript is not allowed
  assistive access", -1719), so no menu items were clicked. No
  state-changing action was triggered by any test. Menu-content
  correctness rests on (b)'s machine diff plus (c)'s live status
  item; interactive clicking is a Stage B soak observation (his eyes).
- **(d) Quit**: bench process terminated; `pgrep -x BatteryCommander`
  = 0 processes; SwiftBar still running (PID 33341) — the plugin is
  again the only BC menu-bar UI. Nothing was left running.

## Live system after Stage A (verified 20:33 EET)

- Daemon tick 20:32:52: `pct=86% BCLM=10 charging=0 external=1`,
  config LAST_UPPER=86 / LAST_LOWER=85.
- Watchdog heartbeat 20:32:47: hold, APG green. 17
  com.batterycommander agents loaded (incl. sentinel).
- Deployed plugin md5 unchanged: `b286e9ccb886c900e6356a9fb74c0526`.
- /Applications/BatteryCommander.app untouched (applet, Nov 13).
  No `.calibration_run`, no `.discharge_session`. NOTHING installed.

## Friction found (reported, not routed around)

1. **No Swift friction** — see Build result. The fallback stays
  unneeded.
2. The File API `/run` 30 s cap still forces detached builds (known
  project constraint; handled with nohup + log, as before).
3. osascript assistive access is denied from the agent shell, so
  menu clicking/screenshots are not automatable here (see smoke c).
  This is an environment limit, not an app defect.

## Stage B readiness statement

**Ready to propose.** The bench bundle above is exactly what the
48 h soak (duration already approved) would run:

- **What Stage B runs**: this native app, continuously, alongside the
  still-installed plugin (two BC icons, per his soak decision), with
  periodic `--dump-menu` vs plugin-render parity spot-checks and the
  design §12 criteria (no crash, footprint, no missed-tick drift).
- **What must happen first, inside Stage B's own approval**:
  1. **FR-006 launcher merge** — before the app can replace the
     /Applications bundle contents at the same path, it must absorb
     the launcher applet's login housekeeping; that sequence still
     needs implementing + a behaviour checklist diff against
     `BatteryCommander-launcher.sh` (build plan step 4). Until then
     the applet stays exactly as it is.
  2. The gated install step itself (design §11 step 5): assemble the
     verified bundle at `/Applications/BatteryCommander.app` (same
     path, same bundle id — the existing login item keeps working
     with zero re-registration).
- **Stage C remains separate**: plugin file retirement + FR-007 Quit
  (full tool shutdown with limit release) are cutover items, not
  soak items.
