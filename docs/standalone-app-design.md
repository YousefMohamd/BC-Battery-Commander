# Battery Commander (BC) — Standalone Menu-Bar App — Design

- **Date:** 2026-11-12
- **Status:** DESIGN ONLY — no code written, nothing built. Building needs
  Yousef's separate approval, per the project's phase rules.
- **Scope:** Replace the SwiftBar plugin as BC's user interface with a native
  menu-bar app. The backend does not change (see §10).
- **Inputs:** Yousef's spec of 2026-11-10 (reaffirmed since): icon only in the
  menu bar, the SAME buttons/menu items in the same shape as today's SwiftBar
  UI, UI improved in the same style, dynamic elements allowed. Menu facts from
  the menu audit of 2026-11-11 (the authoritative map) and a live read of the
  installed plugin on 2026-11-12.
- **Target machine (build + first run):** MacBook Pro 9,1, macOS Catalina
  10.15.8, x86_64. The tool will be published, so the design must not paint
  itself into a Catalina-only corner.

---

## 1. Goals and non-goals

### Goals
1. A native app that lives as an icon (+ charge %) in the menu bar and shows
   the BC menu on click — visually and functionally the same menu Yousef uses
   today, in the same style, with the same dynamic elements.
2. Same data, same cadence: header state from `bc-status`, refreshed every
   10 s (the plugin's cadence).
3. Same actions: every menu item runs the same `dispatch.sh` action the
   plugin runs today (§5). Zero backend changes.
4. Absorb the existing launcher applet's login duties, so ONE app —
   `/Applications/BatteryCommander.app` — is the whole UI + login story.
5. Publishable later: a real bundle that the DMG stage can sign/notarize
   without redesign.

### Non-goals
- No new features, no menu redesign, no new dialogs. "Improved in the same
  style" means native rendering quality (real checkmarks, real submenus,
  disabled states), not a different menu.
- No backend work: no changes to dispatch.sh, helpers, the watchdog, the
  enforcer, agents, or the state dir.
- No signing/notarization work (packaging stage; placeholders only, §13).
- No SwiftBar removal decision — cutover is staged and reversible (§8).

---

## 2. Technology evaluation

### 2.1 Verified toolchain facts (read-only check, 2026-11-12)

| Fact | Value |
|---|---|
| clang | Apple clang 12.0.0 at `/usr/bin/clang` |
| swiftc | **Present**: Apple Swift **5.3.2** (Command Line Tools) |
| xcodebuild | Present but **unusable** — "requires Xcode, but active developer directory is CommandLineTools" |
| Full Xcode | **Not installed** |
| In-project precedent | `powerwatch.c` and `bc-limit.c` already build with clang on this machine; `build-app.sh` already assembles a `.app` bundle by hand (no xcodebuild) |

Consequences: whichever language is chosen, the build is
"compile with the command-line compiler + assemble the bundle manually" —
exactly the pattern BC already uses for the launcher applet. No storyboards
or xibs (they want Xcode); any UI must be built in code. That is fine for a
status-item app: the whole UI is one status item + one menu built from a
table.

### 2.2 Options

**(a) Swift + AppKit (NSStatusItem), compiled with `swiftc`**
- Catalina build-ability: YES, today, zero installs (Swift 5.3.2 verified).
  UI 100 % in code. Manual bundle assembly (house pattern).
- Publish-ability: BEST long-term. Swift is the living language for macOS;
  a 10.15 deployment-target binary runs on current macOS; Swift's runtime
  has shipped inside macOS since 10.14.4, so no runtime bundling for
  10.15+ targets. Future contributors read Swift.
- Maintenance burden: LOW–MEDIUM. Small codebase (one controller, one menu
  builder, one process runner). Swift 5.3-era code may need touch-ups if a
  future build machine moves to a much newer Swift — bounded, mechanical.
- Parity risk: MEDIUM-LOW. The risk is not the language; it is re-expressing
  the plugin's render logic (menu + header state) natively. Same risk in (b).
- Risks: the CLT-only swiftc path (no Xcode) is less trodden — SDK/module
  quirks are possible. Mitigated by the build spike in §11 step 1.

**(b) Objective-C + AppKit, compiled with `clang`**
- Catalina build-ability: YES, today, zero installs — the most certain
  route. clang 12 + `-fobjc-arc` + AppKit is a completely standard
  combination, closest to the in-project C precedent.
- Publish-ability: GOOD technically (ObjC binaries run on every current
  macOS), WEAKER socially: fewer future maintainers, verbose code, and new
  contributors to a published tool increasingly do not write ObjC.
- Maintenance burden: MEDIUM. More code for the same behaviour (menu
  construction and string handling are wordier); memory care is on us
  (ARC reduces but does not erase it).
- Parity risk: MEDIUM-LOW — identical in kind to (a).

**(c) Script-hosted shell (minimal native stub rendering the plugin's
text protocol into an NSMenu, or staying on SwiftBar)**
- Catalina build-ability: trivial — but it does not deliver the thing
  Yousef asked for. The UI would still be produced by parsing SwiftBar's
  `title | param1=…` text protocol: a fragile contract (quoting, dynamic
  labels, separators) kept alive forever, a second failure layer between
  the data and the menu, and either a hard SwiftBar dependency (not
  standalone, poor publishing story) or a from-scratch text parser to
  maintain (the worst of both worlds).
- Verdict: REJECTED as the end state. (It remains implicitly available as
  the rollback — the plugin itself — see §8.)

### 2.3 Criteria summary

| Criterion | (a) Swift + swiftc | (b) ObjC + clang | (c) Script-hosted |
|---|---|---|---|
| Builds on this Catalina machine today | Yes (verified swiftc 5.3.2) | Yes (most certain) | Yes |
| Needs any install | No | No | No |
| Publish-ability to newer macOS | Best | Good | Poor |
| Maintenance burden | Low–medium | Medium | High (protocol) |
| Parity risk vs plugin | Medium-low | Medium-low | Low at first, high forever |
| Meets "standalone native app" spec | Yes | Yes | No |

### 2.4 Recommendation

**Adopt (a): Swift + AppKit, compiled with the Command Line Tools
`swiftc`, UI built entirely in code, bundle assembled by an extension of
the existing `build-app.sh` pattern.**

Rationale: the one fact that could have killed Swift — no toolchain — is
verified false (Swift 5.3.2 is installed). The codebase is small and
bounded, the publish/maintenance story is the best of the three, and the
manual-bundle build is already BC's house pattern.

**Explicit fallback:** if the §11 step-1 spike hits CLT-only swiftc
friction that costs more than ~a day (SDK linking quirks, module issues),
fall back to (b) Objective-C + clang. The architecture in §4 is
language-neutral (controller / status provider / menu builder / action
runner), so the fallback re-implements the same design; it does not
redesign anything.

**Architecture note (forward compatibility):** builds from this machine
are x86_64-only. That is consistent today (the whole BC backend is x86_64)
and runs on Apple Silicon under Rosetta 2. A universal (arm64) build
needs a newer build host and is a packaging-stage concern (§13), not a
design blocker.

---

## 3. Requirements (Spec Kit style)

### Functional requirements
- **FR-001** The app MUST present a single menu-bar status item showing
  the state glyph and the current charge % (e.g. `🔌 86%`), with no Dock
  icon and no main window (LSUIElement).
- **FR-002** The status item MUST refresh from `bc-status` every 10 s,
  on menu open, and immediately after any action completes.
- **FR-003** Clicking the status item MUST show a menu that mirrors the
  plugin's menu item-for-item (§5), including submenus, separators,
  checkmarks for the active power/sleep modes, and the dynamic elements
  of §6.
- **FR-004** Every actionable item MUST invoke the same `dispatch.sh`
  action name the plugin passes today (§5 table). The app MUST NOT
  reimplement any action's logic.
- **FR-005** The header state (glyph, colour, mode text) MUST follow the
  same decision rules as `display_state.sh`, with hold authoritative
  from BCLM = 10 (§7).
- **FR-006** On launch (including login launch), the app MUST perform the
  launcher applet's current housekeeping duties (read config, re-apply
  the configured limit through the existing dispatch path, start the
  launcher checks) so the applet can be retired into the app (§8).
- **FR-007 (AMENDED by Yousef, 2026-11-13 — supersedes the original
  pure-exit draft)** Quitting the app MUST close the tool completely:
  the enforcer releases the charge limit (writes BCLM=100 and stops
  enforcing — via the closed-flag contract the daemon polls; no sudo is
  needed at quit time because the daemon performs the release itself)
  so the Mac returns to stock system charging behaviour, and the UI
  exits. Enforcement silently staying alive after the owner closes the
  tool is not acceptable. (The original design assumed a pure UI exit;
  the owner explicitly rejected that on 2026-11-13: "when I close the
  tool, the tool closes completely and follows the system.")
- **FR-008** The app MUST degrade, never crash, when its inputs are
  missing (§9): no `bc-status`, unparsable output, or missing
  `dispatch.sh` each have a defined visible state.
- **FR-009** The app MUST read state only from `~/.battery-commander/`
  (honouring the `BC_DASH` override if set). It MUST NOT fall back to
  the old `~/.battopt-swiftbar/` directory (audit finding M2: silent
  fallback resurrects a stale backup).

### Non-functional requirements
- **NFR-001** Footprint: ≤ ~30 MB resident, ~0 % idle CPU between ticks
  (BC's whole current footprint is ~22 MB; the UI must not become the
  heavy part).
- **NFR-002** No network access. No new TCC/permission prompts in v1:
  the app only runs the user's own scripts and reads the user's own
  state dir, exactly as SwiftBar does today.
- **NFR-003** Startup to first correct header render ≤ ~2 s on this
  machine, including the first `bc-status` run.
- **NFR-004** All user-visible strings identical to the plugin's current
  strings (including "Battery Commander (BC)" branding and the dynamic
  About text), except the documented deviations in §5.3.

### Acceptance criteria (summary; full test plan in §12)
- Menu diff vs the plugin: item-for-item equal except §5.3 deviations.
- Header parity in every reachable state: hold on AC, charging on AC,
  discharging on battery, other battery modes, sailing.
- 48 h soak alongside the plugin with no missed refresh, no crash, no
  state disagreement > 1 tick.
- Rollback to the plugin demonstrated end-to-end.

---

## 4. Architecture

```
                ┌──────────────────── BatteryCommander.app (LSUIElement)
                │
  NSTimer 10 s ─┼─► StatusProvider ──runs──► ~/.battery-commander/bc-status
  menu open ────┤        │  (background queue; tolerant "Key: value" parser)
  action done ──┘        ▼
                    StateSnapshot ──► HeaderState (display_state rules, §7)
                    (Capacity,        │            │
                     BCLM, IsCharging,│            ▼
                     ExternalConn.,   │      StatusItemController
                     config, modes)   │      (glyph image + "%" title)
                                      ▼
                    MenuBuilder ──► NSMenu (table-driven, §5/§6)
                                      │ click
                                      ▼
                    ActionRunner ──runs (async)──► ~/.battery-commander/dispatch.sh <action>
                                      └─► on exit: StatusProvider.refresh()
```

Components (each maps 1:1 to a source file; names are design-level):

1. **StatusItemController** — owns the `NSStatusItem`, the 10 s timer,
   and menu presentation. Only component that touches AppKit UI objects;
   all UI updates on the main queue.
2. **StatusProvider** — runs `bc-status` off the main thread, parses its
   `Key: value` output (split on the first `:`, trim, strip units;
   unknown keys ignored; missing keys = absent, not zero). Returns a
   `StateSnapshot`. Keeps the last good snapshot for the failure rules
   in §9. Also reads the small state files the plugin reads today
   (config, `.sleep_mode`, `.power_mode`/active-mode marker,
   `.overnight_summary`) from the state dir.
3. **HeaderState** — a pure function: snapshot → (glyph, colour, title
   text, mode line). Ports the *decision table* of `display_state.sh`;
   the script itself stays in place for the plugin during coexistence.
4. **MenuBuilder** — builds the `NSMenu` from a static item table
   (title, submenu, action name, dynamic-label hook, checkmark hook,
   enabled hook) that mirrors §5. Rebuild on each refresh tick is
   acceptable at this menu size (~45 items); targeted updates are an
  optimisation only if a tick ever becomes visible.
5. **ActionRunner** — runs `dispatch.sh <action>` asynchronously
   (dispatch may open dialogs that wait for minutes — the UI must never
   block). Disables the clicked item until the action exits, then
   triggers a refresh. Exit codes are logged; user-facing errors remain
   dispatch's job (it already notifies), exactly as under SwiftBar.

Data contract notes:
- `bc-status` is read-only and side-effect free; the app adds no new
  writes anywhere. The only processes the app starts are `bc-status`
  and `dispatch.sh`, with the same arguments SwiftBar uses today.
- Paths are resolved from `$HOME` at runtime (no hardcoded
  `/Users/Yousef`), same rule the W5 powerwatch rewrite already follows.

---

## 5. Menu mapping (plugin → app, 1:1)

Source of truth: the 2026-11-11 menu audit (post-dedup map) cross-checked
against the installed plugin's action list on 2026-11-12. Every row is a
menu item in the app with the same title and the same dispatch action.
At build time this table is locked against `dispatch.sh`'s case statement
(any action renamed there renames the row here — the app hardcodes no
behaviour, only names).

### 5.1 Header (not clickable)
| Element | Source |
|---|---|
| Glyph + % in the menu bar itself | HeaderState (§7) |
| Overnight summary line (disabled item at menu top) | `$DASH/.overnight_summary` file, written by morning_report.sh — e.g. "Overnight: Last night (Nov 10 -> Nov 11): 85% -> 60% (-25%, 1.6%/h)" |

### 5.2 Items

| Menu (section / item) | dispatch action |
|---|---|
| **Power Mode ▸** Fast Sleep | `power_mode_fast` |
| Power Mode ▸ Balanced | `power_mode_balanced` |
| Power Mode ▸ Always Awake | `power_mode_awake` |
| Power Mode ▸ Deep Only | `power_mode_deep` |
| Power Mode ▸ Custom… | `power_mode_custom` |
| **Sleep Mode ▸** Normal | `sleep_mode_default` |
| Sleep Mode ▸ Presentation | `sleep_mode_presentation` |
| Sleep Mode ▸ Stay Awake (Lid Closed) | `sleep_mode_download` |
| — group label (disabled): "Hibernate timing — after the Mac sleeps" | — |
| Sleep Mode ▸ Travel | `sleep_mode_travel` |
| Sleep Mode ▸ Long Day | `sleep_mode_long` |
| Sleep Mode ▸ Prepare for Sleep | `arm_sleep` |
| Stop Charging Now | `stop_now` |
| Charge to 100% | `charge_full` |
| Force Reset | `force_reset` |
| Reset to Defaults | `reset_defaults` |
| **Charge Limits ▸** Custom Limit… | `limit_custom` |
| Charge Limits ▸ Remove Hold (return to 86%/85%) *(dynamic)* | `remove_limit_hold` |
| Charge Limits ▸ Disable All Limits | `disable_limit` |
| **Smart Discharge ▸** Start Smart Discharge… | `smart_discharge` |
| Smart Discharge ▸ Stop Discharge | `kill_discharge` |
| Start Calibration… *(honest stub, same as today)* | `calibrate` |
| Show Full Status… | `details` |
| **Reports ▸** Sleep & Battery Report | `sleep_report` |
| Reports ▸ Overnight Report | `overnight_report` |
| Reports ▸ Save Report to File | `sleep_report_save` |
| Reports ▸ Open Reports Folder | `open_reports` |
| **Power Saver ▸** Enable / Disable Power Saver *(one toggle item, dynamic title)* | `power_saver_on` / `power_saver_off` |
| Power Saver ▸ Show Full Report | `power_saver_report` |
| **Auto Cleanup ▸** Run Cleanup Now | `pre_sleep_now` |
| Auto Cleanup ▸ Restore Services | `post_wake_now` |
| Auto Cleanup ▸ Enable / Disable Auto Cleanup *(dynamic)* | `auto_cleanup_toggle` |
| **Developer Tools ▸** Project Health Check | `project_health` |
| Developer Tools ▸ Conflict Detection | `conflict_check` |
| Developer Tools ▸ Predictive Analysis | `predictive` |
| Developer Tools ▸ Process Monitor | `process_monitor` |
| **Logs ▸** AI Diagnostic Bundle | `logs_ai_bundle` |
| Logs ▸ Actions Log | `logs_actions` |
| Logs ▸ Sailing History | `logs_sailing` |
| Logs ▸ Arm Log | `logs_arm` |
| Logs ▸ Daemon Logs | `logs_daemon` |
| Logs ▸ Open Battery Commander (BC) Logs *(opens state dir)* | *(open `$DASH`, as today)* |
| Stop ALL Services | `shutdown` |
| Launch at Login *(dynamic ✓)* | `login_toggle` |
| About Battery Commander (BC)… | `about` |
| Refresh Now | *(app-internal: re-run StatusProvider + rebuild menu — replaces SwiftBar's built-in refresh)* |

(Submenu groupings follow the audit's final arrangement; where the plugin
shows a flat list with separators, the app keeps the same order and the
same separators. Conditional items keep their conditions — e.g. "Stop
Discharge" appears only while a discharge session is active, exactly as
the plugin decides today, driven by the same state files.)

### 5.3 Documented deviations (the only intentional ones)
1. **"Open Battery Commander.app" (`open_app`) is omitted.** In the app,
   the item is meaningless — the user is already inside the app. It stays
   in the plugin during coexistence.
2. **"Refresh Now"** becomes app-internal (SwiftBar's built-in refresh
   has no meaning outside SwiftBar); same title, same position, same
   user-visible effect.
3. A **Quit** item appears at the menu bottom (native convention). Per
   FR-007 (as amended 2026-11-13) Quit performs the full tool shutdown:
   limit release + enforcement stop, then the UI exits. The plugin has
   no quit item because SwiftBar owns the process.

---

## 6. Dynamic elements

All dynamic behaviour comes from the same sources the plugin reads today;
nothing new is computed.

| Element | Rule |
|---|---|
| Header % + glyph | From `bc-status` via HeaderState, every tick (§7) |
| Overnight summary line | Text of `$DASH/.overnight_summary`; hidden if the file is absent/empty |
| Remove Hold label | "Remove Hold (return to {UPPER}%/{LOWER}%)" from the live config (86/85 today) |
| Power Mode checkmark | ✓ on the item matching the active power mode state |
| Sleep Mode checkmark | ✓ on the item matching `$DASH/.sleep_mode` |
| Power Saver item | Title flips Enable/Disable with `.power_saver` state, as today |
| Auto Cleanup item | Title flips Enable/Disable, as today |
| Launch at Login | ✓ present iff "BatteryCommander" is a login item (the audit-fixed check — match the real item name, no space) |
| Hold/session items | "Stop Discharge" and similar appear only in their session states, mirroring the plugin's state-file checks |
| About text | Same dynamic text as dispatch's `about` (live limit values, "Smart Discharge / Calibration: arrive in later phases — not in v1") |

---

## 7. Icon state machine (header)

Ports `display_state.sh`'s decision rules. Inputs: `ExternalConnected`,
`IsCharging`, `BCLM`, `Capacity`, config limits, sailing state.
**Hold is authoritative from BCLM = 10** (not inferred from %).

| State | Condition (simplified) | Glyph | Colour |
|---|---|---|---|
| Hold on AC | ExternalConnected, BCLM = 10 | 🔌 | White |
| Charging on AC | ExternalConnected, charging (BCLM = 100, IsCharging) | ⚡ | Grey |
| Discharging (sailing window) | On battery, inside the sailing band | 🔋 | `#8A9AAB` |
| On battery, other modes | On battery, not discharging-band | 🔴 (battery glyph) | `#E8A0A0` |
| Degraded (no data) | §9 failure states | Logo glyph, dimmed | Grey |

Rendering decisions:
- The status item shows the glyph as an image plus the % as its title
  text — the same information as the plugin header ("🔌 86%").
- **Coloured images, not template images.** Template images are tinted
  by the system and would destroy the state colours above. The app
  pre-renders each state glyph in its state colour (drawn at render
  size, @1x/@2x) — no dependence on status-bar tint APIs, and it works
  identically on light and dark menu bars. Both appearances are in the
  test matrix (§12).
- **Asset production:** derive the menu-bar glyphs from the existing
  logo (`Battery Commander.icns`, md5 `bf88d95d…`, in repo
  `assets/icons/` + state dir) using the established sips/iconutil-only
  pipeline (no ImageMagick, per project rule). The detailed logo will
  not survive at 18 px, so the production step simplifies it to a bold
  silhouette; the per-state emoji-style glyphs above remain the primary
  state language, matching today's UI. (Which leads the menu bar is
  open question Q1, §14.)

---

## 8. Coexistence and migration

### 8.1 Relationship to the launcher applet — MERGE
Today `/Applications/BatteryCommander.app` is a launcher applet
(AppleScript + `BatteryCommander-launcher.sh`) whose job is login-time
housekeeping; it is the "BatteryCommander" login item. The native app
**replaces the bundle's contents at the same path** and absorbs those
duties (FR-006):

- Same path: `/Applications/BatteryCommander.app`.
- Same bundle identifier for v1: `com.batterycommander.launcher` —
  keeps the existing login item and any system associations valid with
  zero re-registration. (A cleaner id is a packaging-stage decision.)
- The launcher script itself is retired only at cutover (§8.2 stage C)
  and kept in the repo; before that, the app and the applet never run
  their housekeeping at the same time (the applet is not launched while
  the app is being tested — test sessions are manual and supervised).

### 8.2 Stages (each stage is its own approval, per project rules)
- **Stage A — bench:** app built and run manually in supervised
  sessions; SwiftBar plugin remains the live UI. Two battery icons
  visible during sessions; expected and temporary.
- **Stage B — soak (48 h minimum):** app runs continuously (login item
  still points at the same bundle path, now the native app); plugin
  still installed for instant comparison and fallback. Parity checks
  per §12 run during this stage.
- **Stage C — cutover:** plugin file `~/SwiftBar/battery-commander.10s.sh`
  is moved to its bc-build backup (recoverable, same treatment as the
  old plugin backup). SwiftBar itself is untouched (it may host other
  plugins; removing it is Yousef's separate call). The launcher script
  copy inside the old bundle is superseded by the app.
- **Rollback (any stage):** quit the app, restore the plugin file from
  its backup, done. The backend never changed, so rollback is a UI-only
  operation with zero battery-state risk.

### 8.3 First run
- Resolve the state dir (`~/.battery-commander/`, `BC_DASH` override).
- Run `bc-status` once; render header + menu from real data (or enter a
  §9 degraded state — never block on a dialog).
- Perform the absorbed launcher housekeeping (FR-006).
- No first-run wizard, no prompts, no settings window in v1.

---

## 9. Failure behaviour

| Failure | Visible behaviour |
|---|---|
| `bc-status` missing or exits non-zero | Status item: dimmed logo glyph + `--%`. Menu: one disabled line "Battery Commander: status unavailable", plus working About / Open Logs / Refresh / Quit. Retry every tick. |
| `bc-status` output unparsable once | Keep last good snapshot; no visual change (no flicker). |
| Unparsable twice in a row | Degraded state as above. |
| `dispatch.sh` missing | Status display keeps working; action items disabled with a disabled note line at the menu top. |
| State dir missing | Degraded state; the app does NOT create directories and does NOT fall back to the old dir (FR-009). |
| An action exits non-zero | dispatch already notifies the user (same as today); the app logs the exit and refreshes. The app shows no extra error UI in v1. |
| App itself crashes | Nothing else is affected: enforcer daemon, watchdog, and agents are independent processes. Relaunch is manual or at next login (no crash-restart agent in v1 — deliberate scope limit). |

---

## 10. What does NOT change

- `dispatch.sh` and every helper in `~/.battery-commander/` / repo `src/`.
- `bc-status` (binary and output format) and `display_state.sh` (stays
  for the plugin during coexistence; the app ports its rules, §7).
- `bc-limit`, the `com.batterycommander.bclimit` daemon, BCLM
  enforcement, and Phase C (independent of this design; the app is a UI
  and neither helps nor blocks the enforcer swap).
- bc-watchdog, powerwatch, all 16 `com.batterycommander.*` agents.
- The state dir `~/.battery-commander/` — same files, same formats.
- Config format and values (86/85, SAILING=false), sudoers, pmset
  settings.
- The morning report system (the app only displays its summary line).

---

## 11. Build plan (for the build phase, when approved)

Repo layout: `src/app/` (Swift sources), `src/app/build-app-native.sh`
(bundle assembly, extending `build-app.sh`'s proven pattern),
`src/app/Info.plist`, `src/app/assets/` (menu-bar glyphs).

1. **Spike (de-risk first):** minimal status item ("BC 1%") compiled
   with CLT `swiftc`, hand-assembled bundle, ad-hoc signed; verify it
   launches on this Mac, shows in the menu bar, survives a logout/login.
   If this fails beyond ~a day of friction → fallback (b), §2.4.
2. **Status pipeline:** StatusProvider + parser against real `bc-status`
   output; HeaderState port with the §7 table; header rendering.
3. **Menu:** MenuBuilder + the full §5 table; dynamic hooks (§6);
   ActionRunner.
4. **Launcher merge:** housekeeping sequence (FR-006) with a behaviour
   checklist diffed against the current launcher script.
5. **Bundle + install:** assemble `BatteryCommander.app`, verify bundle
   (identifier, LSUIElement, icon), install to /Applications at stage B
   (that install step needs its own go-ahead, as before).
6. **Cutover** per §8.2 stage C (separate approval).

Toolchain constraints honoured by the build: no xcodebuild, no IB,
deployment target 10.15, x86_64, ad-hoc signing for local test builds
(real signing is §13).

---

## 12. Test plan

All tests are UI-level; none touches the SMC, the daemon, or battery
state beyond normal use. Destructive actions (`shutdown`) are verified
by inspection only, exactly as in the menu audit.

1. **Menu diff:** dump the plugin's rendered menu (SwiftBar text) and
   the app's menu tree side by side; diff must show ONLY the §5.3
   deviations.
2. **State parity matrix** — app header vs plugin header, same minute:
   hold on AC (available now) · charging on AC (during a natural
   charge-up) · discharging on battery (natural use) · battery other
   modes · sailing window. Glyph, colour, %, and mode line must agree
   every tick sampled.
3. **Action spot-checks:** every safe action clicked in the app and
   confirmed to have run the same dispatch action (actions.log) with
   the same user-visible result as from the plugin. Dialog actions
   (Custom Limit) checked for dialog appearance + cancel safety.
4. **Dynamic labels:** change nothing, observe: overnight line appears
   in the morning; Remove Hold label matches config; checkmarks track
   a power/sleep mode change made from the plugin (cross-UI state
   consistency — both UIs read the same state files).
5. **Appearance:** light + dark menu bar; @1x/@2x rendering; long %
   strings (100%) do not clip.
6. **Failure drills** (against a sandboxed copy of the state dir via
   `BC_DASH`, NEVER the live one): rename `bc-status`, corrupt its
   output, remove `dispatch.sh` → §9 states appear, app never crashes.
7. **Soak:** 48 h continuous run during stage B: no crash in Console,
   footprint within NFR-001, no missed-tick drift vs the plugin.
8. **Rollback drill:** perform §8.2 rollback once, confirm the plugin
   UI returns exactly as before.

---

## 13. Packaging notes (for the later DMG stage — noted, not solved)

- Bundle layout (target):
  `BatteryCommander.app/Contents/{MacOS/BatteryCommander, Resources/
  (icns, glyphs), Info.plist}`. The app bundles NO scripts: it calls
  the state-dir backend by absolute `$HOME`-based path, so the DMG
  story for the backend (installer vs bundle-embedded backend) is a
  packaging-stage decision that this design deliberately does not
  pre-empt.
- Signing placeholders: Developer ID Application certificate, hardened
  runtime, and notarization will be required for distribution.
  `notarytool` needs full Xcode on a newer build host; the Catalina-era
  `altool` path is deprecated. Local/test builds stay ad-hoc signed.
- Universal binary (arm64 + x86_64) likewise needs a newer build host;
  v1 from this machine is x86_64 (Rosetta 2 covers Apple Silicon).
- Versioning: app version starts at 1.0, tracked independently of the
  backend scripts, both reported in the About dialog at packaging time.

---

## 14. Open questions for Yousef (preference-level only)

1. **Menu-bar icon:** keep today's language — state glyph + % (e.g.
   "🔌 86%"), which is readable at a glance — or lead with the BC logo
   glyph + %? (Design assumes glyph + %; the logo is detailed and
   nearly unreadable at 18 px, but it is your brand.)
2. **Soak arrangement:** during the 48 h soak there will be two battery
   icons (app + plugin). Acceptable as-is, or do you want the plugin
   hidden from day one of the soak (faster cutover, less side-by-side
   safety)?
3. **Quit behaviour — ANSWERED by Yousef, 2026-11-13:** NOT a pure UI
   exit. Closing the app must close the tool completely: release the
   charge limit and let the Mac follow stock system behaviour. FR-007
   amended accordingly (see §3).

---

## 15. Risks

- **CLT-only Swift friction** — mitigated by the step-1 spike and the
  ObjC fallback (§2.4); worst case costs the spike's time, not the
  design.
- **Render-logic drift** between `display_state.sh` (plugin) and the
  app's HeaderState port during coexistence — mitigated by the §12
  parity matrix and by retiring the plugin at cutover (one source of
  truth afterwards: the app's table, with the script archived).
- **Menu-table drift** if dispatch actions are renamed later — the app
  table is data, reviewed against dispatch at build time (§5); a
  renamed action degrades to one dead item, not a crash (ActionRunner
  logs the exit).
- **Scope creep** ("while you're at it, add…") — the non-goals in §1
  are the guardrail; new items go to later phases, as with the rest of
  the project.
