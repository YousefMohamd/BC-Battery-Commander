# Battery Commander (BC) — Plan Review & Rebuilt Plan

Date: 2026-11-12 (reviewed ~16:13 EET)
Basis: `01-PROJECT.md` (§5 problems, §13 open checklist), goal file
`goal_d9a476fabf71`, MEMORY.md, and a live read on 2026-11-12 16:13 EET.
Rule applied throughout: live readings win over older file facts.

---

## 1. Independence status — the headline

**Independent today:** the whole user-facing stack — SwiftBar plugin,
dispatch.sh, ~28 helpers, bc-watchdog, powerwatch, the launcher app,
all 16 `com.batterycommander.*` agents, the state dir
`~/.battery-commander/`, the pmset-only sudoers file, branding/logo.
Zero `com.battopt.*` agents are loaded. No licence/trial code exists
in the BC stack.

**NOT independent yet — one single dependency:** charge-limit
*enforcement* still runs on the old closed-source battopt daemon
(PID 88736, running since Sun 09:00). Verified live 2026-11-12 16:13:
battery 87.1%, holding, `IsCharging=No` — enforced by that daemon.

Aggravating fact (audit finding C1): the daemon's binary directory
`/Library/Application Support/battopt/` is DELETED. The process lives
in memory only; `/usr/local/bin/battopt` is a symlink to a deleted
target. If the daemon dies or the Mac restarts, nothing enforces the
limit until the BC daemon is loaded. **Do not restart the Mac before
Phase C.**

**The BC replacement is ready:** `bc-limit-phase-c` (v1.0-phase-c,
69,400 B, md5 38ee0a6cf09aebfd481d2e1f0a10e0a0) — built clean,
dry-run tested incl. the gauge-jump deferral; daemon plist installed
at `/Library/LaunchDaemons/com.batterycommander.bclimit.plist`,
NOT loaded; exact swap commands written in `phase-c-plan.md` §4.
Note: the plist invokes `bc-build/bc-limit`, so the new binary must
be placed at that path during the swap (old binary already backed up
as `bc-limit.pre-phase-c-20261112`).

**Conclusion: independence is one gated session away.** Everything
except the Phase C swap itself is done. Phase C needs Yousef present,
in daytime, a few hours — his sudo, his approval. It does NOT depend
on tonight's sleep test.

---

## 2. What is DONE (with evidence)

- Phases 0–2: tools (Spec Kit, Rust, Craft Anything), project files
  absorbed, read-only verification — git/MD5s match the handoff.
- Knowledge base: SMC reader V6 (431 keys), natural observation
  (closed 2026-11-09), Deep reverse engineering (limit enforced in
  software by toggling BCLM 10/100; the % is never written to SMC),
  Mac compatibility research (runtime probing, no model table),
  full audit + limit-writer design v2 (approved 2026-11-08),
  wrapper design (40 tasks, 6 decisions approved 2026-11-09),
  comprehensive audit 2026-11-11 (~100 fixes; health PASS 17/0/2).
- Enforcer: bc-limit Phase A (dry-run) passed; Phase B root write
  proven by Yousef's sudo test (read-back verified); Phase C binary
  with gauge-jump deferral built + dry-run tested 2026-11-12;
  LaunchDaemon plist built + installed (not loaded).
- Wrapper W0–W6: dispatch rewritten around `bc_apply_limit` (never
  writes BCLM, never calls battopt), new plugin, single watchdog
  replacing 4 old scripts, helpers rebuilt, launcher + powerwatch
  rebuilt, log hygiene.
- Deployment: state dir migrated to `~/.battery-commander/`
  (25 files, md5-verified), plugin + 21–28 state files deployed,
  activation done (old agents unloaded, new ones loaded), app
  installed at /Applications/BatteryCommander.app with the new dark
  logo, login item switched, 13 agents renamed to
  `com.batterycommander.*` (+ real bug fixes), adaptive-governor
  retired, sudoers replaced (pmset-only), /usr/local/bin battopt-*
  helpers removed, dead files removed, old state dir kept as an
  inert backup (Yousef's decision, marked).
- Quality passes: menu audit (duplicates removed, 5 broken buttons
  fixed), notification-spam fix (state-based, not time-based),
  logo/brand fix ("Battery Commander (BC)", dynamic About), morning
  overnight report (menu line + full report + 8 AM notification).
- Sleep drain — diagnosis: S1 night 2026-11-11→12 measured
  (815 mAh, ~1.4 %/h, ~0.9 W, real energy — gauge artifact refuted
  for the overnight drain). Root cause #1 identified by log
  evidence: Find My beacon (bluetoothd BlueAvengers) requesting
  maintenance wakes every ~15 min for the first ~2 h despite
  Bluetooth being off and all inputs unplugged (~+2.5–3 %/night).
  Bluetooth connections, USB, headphones, Time Machine, Spotlight,
  and BC itself all eliminated as causes.
- Gauge jumps: characterized (gas-gauge re-estimation, not energy);
  protections built — watchdog deferral + bc-limit gauge deferral.

## 3. Original §13 checklist — reconciled

- Trial enforcement after restart → MOOT: BC has no trial code;
  the question dies with Phase C.
- Status prototype → DONE (2026-11-07, passed).
- Natural observation closure → DONE (2026-11-09).
- TB0T / B0AV voltage validations → still open, opportunistic,
  low priority (watch-only).
- Limit-writer design → DONE (v2, built, A/B passed).
- Kernel panic recurrence → no recurrence since 2026-11-07;
  separate GPU/framebuffer issue; watch-only, do not chase.
- Fan → separate mechanical issue; watch-only.
- 3-day checklist → superseded by the 2026-11-10 deployment and
  Yousef's live testing since (hold ✓, About/logo ✓).
- Formal v2 night 2 → replaced by S1 (done) + S3 test (tonight).
- DMG → still pending (Stage 9). Push → LAST (Stage 10).
- Calibration / SMC reset → calibrate is Stage 5; SMC reset is
  NOT planned (not needed by any current evidence).

## 4. What is LEFT — and what it depends on

### 4a. NOT blocked on tonight's sleep test (the main line)

1. **Phase C execution** — swap enforcement to the BC daemon
   (place new binary, unload old daemon, load BC daemon), hold
   verification 30–60 min, full charge cycle test (natural
   discharge to ~80–83 %, charge back, verify hold at 86 %),
   retire the old daemon plist + stale root powerwatch plist
   (Yousef sudo). Gate: Yousef's approval + daytime presence.
   THIS is the independence step.
2. **App rebuild** — repo launcher fixes (md5 f30d3e5f…) are not
   in the installed app yet; rebuild + reinstall + relaunch.
   Bundle with the Phase C session (needs a launcher restart).
3. **Hardening decisions** (from the comprehensive audit):
   M2 DASH fallback (retire/gate), M5 Reset-to-Defaults canonical
   values (86/85, SAILING=false, SAIL_GAP=1), M6 bc-limit honoring
   `.apg_paused` (design + approval), M8 one canonical % source,
   C2 overshoot notification, m9 confirm the 50 % limit floor,
   delete dead test_enforce_watchdog.sh. Small, code-level; each
   decision is Yousef's, the work is mine.
4. **`.bak` purge** — 17 dispatch.sh backups cross 30 days on
   Nov 13–14; approved already; run then (two-gate script).
5. **Discharge phase** — design (Spec Kit) → build a controlled
   discharge on top of bc-limit (requires the LAYER2 second-signal
   rule before any forced discharge) → natural test. Separate
   approval per project rules.
6. **Charge phase** — formalize + verify charge-to-full behavior
   (partly exists via limit 100/99); test.
7. **Calibrate phase** — full discharge→charge automation;
   separate approval; long machine cycle.
8. **Standalone menu-bar app** — Yousef's stage 3: native app,
   menu-bar icon only, same buttons/shape, improved UI. Design
   (Spec Kit) → approval → build → test. Assets ready.
9. **Final re-test + delivery report** — full pass over menu,
   buttons, hold, cycle, reports, agents; written report.
10. **Local commit** — the tree carries all W1–W6 + audit work
    uncommitted (branch ahead 54, not pushed). Gate: approval.
11. **DMG** — package the app + components.
12. **GitHub + push/publish** — LAST, only after all the above.

### 4b. Blocked on tonight's test (the only such item)

- **Sleep-drain closure:** tonight (2026-11-12→13) runs the S3
  test — Offline Finding OFF, Find My Mac ON, everything else
  identical to S1. Tomorrow: read the log (15-min wakes gone?),
  compare drain vs S1 (~15.6 % baseline; expected ~12–13 %;
  upside case: floor drops if the beacon alarms were blocking
  autopoweroff). Then Yousef decides: keep Offline Finding off,
  or restore it and accept ~1.4 %/h on battery nights. Either way
  the finding gets documented and the thread closes. NOTHING else
  in the plan waits on this.

### 4c. Watch-only (no scheduled work)

- Kernel panic recurrence; fan behavior; TB0T/B0AV validations.

---

## 5. Completion accounting

Frame kept consistent with the 2026-11-11 estimate (70 %); updated
only for work verified since (Phase C prep build + sleep diagnosis).

| Workstream | Weight | Done | Left |
|---|---|---|---|
| Foundations, access, verification (Phases 0–2) | 6 | 6 | 0 |
| Research, RE, designs, audits | 15 | 15 | 0 |
| Enforcer build (bc-limit A/B, daemon, phase-c binary) | 10 | 10 | 0 |
| Wrapper W0–W6, migration, activation, cleanup | 24 | 24 | 0 |
| Current UI, branding, reports, menu/notification fixes | 8 | 7 | 1 |
| **Phase C execution + retire old daemon** | **9** | **2** | **7** |
| Discharge / charge / calibrate phases | 8 | 1 | 7 |
| Standalone menu-bar app | 6 | 0 | 6 |
| Sleep drain (diagnosis + fix) | 6 | 4 | 2 |
| Hardening decisions leftovers | 2 | 0 | 2 |
| Final re-test + delivery report | 3 | 0 | 3 |
| Local commit + DMG + GitHub publish | 3 | 0 | 3 |
| **Total** | **100** | **69** | **31** |

The table is the accounting: **69 % done / 31 % left — call it
~70 %.** This deliberately matches the 2026-11-11 estimate (70 %):
since then, Phase C prep and the sleep diagnosis were completed,
but the recount also itemizes honestly what the quick frame had
folded away (app rebuild, hardening decisions, re-test,
packaging). The honest one-liner: everything except execution
steps is done — what remains is doing, testing, and packaging,
not figuring out.

Remaining 31 %, by item: Phase C execution 7 · discharge/charge/
calibrate 7 · standalone app 6 · sleep-drain closure 2 · hardening
decisions 2 · app rebuild (UI tail) 1 · final re-test + report 3 ·
commit + DMG + publish 3.

## 6. Rebuilt forward plan (stages, in order)

- **Stage 1 — Phase C day** (independence): swap + hold verify +
  full cycle + retire old plists. Needs Yousef, daytime, ~half a
  day of wall-clock (the cycle runs on natural use). Gate: approval.
- **Stage 2 — Post-Phase C consolidation** (~1 day): app rebuild,
  hardening decisions applied, `.bak` purge (Nov 13–14 window).
- **Stage 3 — Discharge phase** (~2–3 days): design → build →
  natural test. Gate: design approval.
- **Stage 4 — Charge phase** (~1 day): formalize + test.
- **Stage 5 — Calibrate phase** (~1–2 days + a long cycle):
  build → supervised cycle. Gate: approval.
- **Stage 6 — Standalone menu-bar app** (~4–5 days): Spec Kit
  design → approval → build → side-by-side test vs SwiftBar UI.
- **Stage 7 — Sleep-drain closure** (parallel, ~0.5 day): analyze
  tonight's test → Yousef's decision → document. Runs alongside
  Stages 1–2, blocks nothing.
- **Stage 8 — Final re-test + delivery report** (~1–2 days).
- **Stage 9 — Local commit + DMG** (~1 day). Gate: approval.
- **Stage 10 — GitHub + publish** (~0.5–1 day). LAST. Gate:
  approval.

## 7. Time estimate

- My working time remaining: **~12–16 working days** of actual
  work across Stages 1–10 (builds, tests, reports, packaging).
- Calendar time: **~3 weeks** (range 2–4), because the critical
  path is gated on Yousef's availability, not on my work:
  one daytime session for Phase C, one named night per battery
  test, and per-phase approvals. Two to three shared sessions a
  week lands the project at the short end; one session a week
  stretches it toward a month.
- Critical path: Phase C → discharge/charge/calibrate →
  standalone app → final re-test → DMG → publish.
- The sleep-drain thread is parallel and never on the critical
  path.

## 8. Standing risks / rules (unchanged)

- Do NOT restart the Mac before Phase C (enforcer is memory-only).
- No SMC write, sudo, install, or test without its own approval;
  Yousef runs every sudo step himself.
- No purchase, ever. Push is last. Backups before replacements.
- Test gate: battery/sleep tests only on named, approved nights.
