# Standalone App — STAGE B (FR-006 Merge + Gated Install + Soak Start) Note — 2026-11-14

Approved by Yousef 2026-11-14 20:57 EET ("ابدأ المرحلة B والسوك 48 ساعة").
Governed by `standalone-app-design.md` §8.1/§8.2/§11 step 4–5 and
`app-stage-a-note.md`. Stage C (plugin retirement + amended FR-007
Quit) is NOT part of this stage and was not done.

## Headline

**Stage B complete up to a verified soak start.** The launcher
applet's housekeeping is merged into the native app (FR-006), the app
is installed at `/Applications/BatteryCommander.app` (same path, same
bundle id — the existing login item resolves to it unchanged), it
launched and performed the full launcher sequence live, menu parity
vs the plugin holds at **146/146**, and the **48 h soak started
2026-11-14 21:10:27 EET, ending 2026-11-16 21:10:27 EET** with both
BC UIs running. Live system after the swap: gauge 90–91 % (drift,
BCLM=10), config 86/85, daemon/watchdog/sentinel healthy.

One deviation from the ideal path, with evidence and reasoning in §4:
the old applet *process* could not be terminated (the File API run
policy blocks process termination, and a graceful quit would fire
the applet's legacy shutdown handler), so it was left idling — inert,
lock-free, and gone at the next logout.

## 1. FR-006 merge — behaviour checklist

Source enumerated line-by-line: `src/app/BatteryCommander-launcher.sh`
(275 lines) + `src/app/BatteryCommander.applescript` (run/idle/quit).
Implemented as a new file `src/app/Housekeeping.swift` (a `LaunchSequence`
port that writes the *same* lines to the same `actions.log` in the
same format), wired once per launch from `AppDelegate` on a
background queue.

| # | Launcher behaviour (script line) | Disposition | App equivalent / evidence |
|---|---|---|---|
| 1 | `mkdir -p` state dir + SwiftBar dir (L25) | **Adapted** | App never creates the state dir (design §9/FR-009: missing state dir = degraded state). SwiftBar dir still created if missing. |
| 2 | `log()` → actions.log, `[HH:MM:SS] Battery Commander (BC):` (L27) | Merged verbatim | `hkLog` — identical format; live proof §3. |
| 3 | `notify()` terminal-notifier → osascript → log-only (L31) | Merged verbatim | `hkNotify`, same paths, same `-appIcon`/`-group`, always logs `NOTIFY:`. |
| 4 | `read_config` KEY=value parse, never sourced, defaults 86/85/false/1 (L46) | Merged verbatim | `readConfig` (allow-list keys, split on first `=`). |
| 5 | `valid_limit` digits 15–100 (L64) | Merged verbatim | `validLimit` via the existing `digitsToInt`. |
| 6 | `daemon_loaded` = `launchctl list` user domain (L72) | Merged verbatim | Read-only `launchctl list`; nothing is ever loaded (launcher rule kept). |
| 7 | Enforcer freshness = daemon-log mtime < 180 s (L82) | Merged verbatim | `enforcerRunning` via `fileAgeSeconds`. |
| 8 | `read_bclm` via bc-status (L92) | Merged verbatim | `readBCLM` (bc-status `BCLM:` line, 2nd field). |
| 9 | Launch lock `.launch.lock.dir` + pid, stale takeover, EXIT-trap release (L100) | Merged | Same lock dir/pid semantics; released at sequence end (= the trap). Live lock held by another process → sequence logs the same line and the duplicate app instance exits (script exited 0 and the applet idled invisibly; a second menu icon would be wrong). |
| 10 | `=== LAUNCH START ===` / `=== LAUNCH COMPLETE in Ns ===` (L120/L273) | Merged verbatim | Live proof §3: "in 5s". |
| 11 | Step 1: clear `.user_shutdown`/`.disabled`/`.paused` (L124) | Merged | Files only — the script's `rm -f` could not remove the `disabled/` directory either. |
| 12 | Step 2: restore plugin from `disabled/` → ~/SwiftBar, chmod 755 (L127) | Merged verbatim | `battery-commander.*.sh` glob, move + 0o755 + same log line. (Nothing was in `disabled/` at soak start — no-op, as at every recent login.) |
| 13 | Step 3: enforcer check; fresh + tail-20 ERROR scan; WARN + notify (L136) | Merged verbatim | Same strings. Live: "enforcer … is running (daemon log fresh)". |
| 14 | Step 4: powerwatch loaded check (L150) | Merged verbatim | Live: "powerwatch … is loaded". |
| 15 | Step 5: watchdog loaded check (L157) | Merged verbatim | Live: "watchdog … is loaded". |
| 16 | Step 6: config + `.last_session_mode`, limits validated (invalid → 86/85; lower ≥ upper → lower = upper−1) (L164) | Merged verbatim | Live: "config limits: 86/85 (authoritative); last_session mode: idle". |
| 17 | Step 7a: reconciler % from ioreg Current/MaxCapacity (L178) | Merged verbatim | Same integer math; live PCT=91. |
| 18 | Step 7b: `dispatch.sh reapply_limit` (L191) | Merged verbatim | Live: dispatch's own lines interleave ("bc_apply_limit: config written 86/85") + "reapplied configured limit 86/85 via dispatch". |
| 19 | Step 7c: % branches → `.charge_target` / `.active_mode` (hold / charge_full) (L198) | Merged verbatim | Live: ≥ lower branch → "holding (no discharge)". |
| 20 | Step 7d: sleep 2, BCLM read-back verify + mismatch WARN/notify (L224) | Merged verbatim | Live: "BCLM read-back: 10 …", no mismatch. |
| 21 | Step 7e: post-shutdown overshoot (pct > upper) → assert `idle` for the watchdog (L243) | Merged verbatim | **Fired live**: gauge 91 > 86 → "asserting idle for watchdog"; `.active_mode` = `idle` after launch (watchdog owns the overshoot call; its own log shows it managing the 90 % overshoot with the APG pause). |
| 22 | Step 7f: sleep 2, `touch` plugin file (L250) | Merged verbatim | mtime refresh via FileManager attributes. |
| 23 | Step 8: launch SwiftBar if absent; missing → WARN + notify (L254) | Merged verbatim | SwiftBar was running (PID 33341) — no-op, no log line, exactly like the script. |
| 24 | Step 9: plugin presence verify; missing → WARN + notify (L265) | Merged verbatim | Live: "plugin battery-commander.10s.sh present in /Users/Yousef/SwiftBar". |
| 25 | Applet `on idle` → return 60 | **Obsolete** | Applet-runtime artifact. The native app is a real NSApplication with its own 10 s refresh timer (design §8.1 merge). |
| 26 | Applet `on quit` → `dispatch shutdown --force`, delay 5 | **Deferred to Stage C** | FR-007 territory: the amended FR-007 (Yousef, 2026-11-13) redefines Quit as the daemon closed-flag release at cutover (design §8.2 stage C, §11 step 6). Stage B Quit remains a plain exit, per this stage's approved scope. Not dropped — tracked for Stage C. |

The launcher's standing rules are preserved in the port: no battopt
binary, no sudo, no `launchctl` load, no trial-renew helpers, config
parsed as data, canonical defaults.

### Build + parity after the merge

- Sources changed: **new** `Housekeeping.swift`; `AppDelegate.swift`
  (Stage B header + one `Housekeeping.runOnce` call at launch);
  `build-app-native.sh` (SOURCES += Housekeeping.swift; comments).
  `main.swift`, `Shell.swift`, `StatusProvider.swift`, `MenuModel.swift`
  untouched — `--dump-menu` still performs **no** housekeeping (it is a
  read-only test surface; housekeeping lives in the app lifecycle).
- Clean build via `build-app-native.sh`: **zero errors, zero warnings**
  (one warning — an unmutated `var upper` — was fixed and rebuilt
  before install). Log: `battopt-project/bc-build/app-stage-b/build.log`.
- Parity re-run on the merged build (fresh plugin render vs bench
  `--dump-menu`, Stage A comparator): **PASS — 146 canonical lines
  identical**, same 3 documented §5.3 deviations only. Repeated after
  install from the installed copy: **PASS — 146/146**.

## 2. Gated install — evidence

- **Backups first** (both verified against the live bundle before the
  swap; applet executable md5 `f759464310a38f24d225f7bd94d48709` in all
  three places; repo backup `diff -r`-identical to the live bundle):
  - Repo: `app/BatteryCommander-applet-backup-20261114.app`
  - State dir: `~/.battery-commander/backups/BatteryCommander-applet-backup-20261114.app`
  - Swap parking copy: `/tmp/BatteryCommander-applet-live-20261114.app`
    (the exact bundle that was live, moved aside — a third copy).
- **Swap**: `mv` the applet bundle to the parking path, then `ditto`
  the bench build to `/Applications/BatteryCommander.app`. At no point
  was the path left without a verified restorable copy.
- **Installed bundle verification**:
  - `diff -r` vs the bench build: **identical** (no leftovers — the
    bundle was created fresh by ditto, not merged).
  - Executable md5 `5739955e16cd06ab9c41aff09e3e5b38` = bench build.
  - `codesign --verify`: "valid on disk / satisfies its Designated
    Requirement" (ad-hoc signature, as designed for local builds).
  - Info.plist: `CFBundleIdentifier = com.batterycommander.launcher`,
    `LSUIElement = true`; executable is Mach-O 64-bit x86_64.
- **Login item**: untouched and not recreated. Verified by System
  Events before and after: a login item resolves to
  `/Applications/BatteryCommander.app` — same path, same bundle id, so
  it starts the native app from the next login with zero
  re-registration (design §8.1).

## 3. Launch + first-hour proof

- Launch: 2026-11-14 **21:10:27 EET** (direct executable launch from
  the installed path — the Stage A-proven pattern; the login item
  takes over this role at the next login).
- Process: PID 12066, `/Applications/BatteryCommander.app/Contents/MacOS/BatteryCommander`.
- First correct header **≤ 4 s**: bench log 21:10:31 `status: 🔌 91%
  mode=hold` (the gauge's current reading — see the drift note in the
  soak log; plugin reads the same value from the same source).
- Housekeeping (FR-006) live, actions.log 21:10:31–21:10:37:
  `=== LAUNCH START ===` → enforcer running → powerwatch loaded →
  watchdog loaded → config 86/85 → reapplied via dispatch →
  reconciler holding → BCLM read-back 10 → overshoot idle assertion →
  plugin present → `=== LAUNCH COMPLETE in 5s ===`. Lock dir released;
  `.charge_target` absent; no shutdown/paused flags appeared —
  **no shutdown side effects**.
- Cadence: status ticks every 10 s in the app log
  (21:10:31/42/51, 21:11:02, … 21:18:21/31/41 …).
- Footprint: RSS 21.9 MB at 1 min → 26.7 MB at 8 min → 32.5 MB at
  10 min → **31.3 MB at 20 min** — a warm-up climb that flattened and
  turned down (allocator behaviour, not a linear leak), settling
  right around the ~30 MB NFR-001 guideline; 0.0 % CPU between ticks
  throughout. Soak item 6 keeps it under observation.
- Crash reports: **none** for the bundle in
  `~/Library/Logs/DiagnosticReports` (baseline was also none).
- Both UIs by process evidence: SwiftBar PID 33341 (plugin md5
  unchanged `b286e9ccb886c900e6356a9fb74c0526`, fresh render used for
  parity) + native app PID 12066.
- Backend after install: daemon tick "nothing to do: pct=90%
  BCLM=10"; watchdog heartbeat fresh (APG green/yellow with load —
  normal); sentinel `com.batterycommander.watchdogsentinel` loaded;
  config still 86/85.

## 4. Deviation: the old applet process is still alive (inert)

The applet is a stay-open process (PID 21524, running since
2026-11-13). Retiring it gracefully is impossible inside this stage's
rules — its `on quit` handler runs the legacy `dispatch shutdown
--force` — and terminating it via the File API is **blocked by the
run safety policy** (HTTP 403 "Dangerous command blocked"), which per
project rules is a stop, not something to route around. It was
therefore left running from its parked bundle. Evidence it is inert:
0.0 % CPU / ~3.4 MB since Nov 13; its only behaviours were launch
(housekeeping — now the app's) and quit (never fired); it holds no
lock (`.launch.lock.dir` was free for the app's launch) and touches
nothing on its 60 s idle. It disappears at the next logout/restart
and can never relaunch (no login item points at its parked path);
from the next login, only the native app starts. **Do not script-quit
it** (an Apple-Event quit fires the legacy shutdown handler);
quitting it from Activity Monitor (a signal) is safe if ever desired,
and Stage C closes this out regardless.

## 5. Open items / soak watch

- **Footprint trend** — characterised in the first hour: climbed to a
  ~32.5 MB peak at ~10 min, then flattened/declined (31.3 MB at
  20 min) — warm-up, not a leak. Soak observation item 6 keeps a
  daily eye on it; a sustained linear climb across the soak would
  become a Stage C fix candidate (the tick path is Stage A's,
  unchanged by the merge).
- Interactive menu clicking remains Yousef's-eyes-only (soak list #1).
- Stage C remains: plugin-file retirement + FR-007 Quit + the stray
  applet process's final close-out.

## 6. Files

- Mac repo: `src/app/Housekeeping.swift` (new), `src/app/AppDelegate.swift`,
  `src/app/build-app-native.sh`; evidence in
  `battopt-project/bc-build/app-stage-b/` (build.log, plugin-render.txt,
  app-dump.txt, plugin-render2.txt, app-dump-installed.txt,
  installed-run.log).
- Soak log: `~/workspace/bc-build/app-soak-log.md` + Mac repo copy in
  `battopt-project/bc-build/`.
- This note: `~/workspace/bc-build/app-stage-b-note.md` + Mac repo copy.
