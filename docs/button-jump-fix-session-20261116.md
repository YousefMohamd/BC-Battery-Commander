# Button/Jump Repair Session — 2026-11-16

Approved by Yousef 2026-11-16 13:33 EET ("كمل شغلك"). Scope: find
why the buttons produced no physical effect above the limit and
what the gauge "jump" (القفزة) does to enforcement; rebuild the
original tool's on-AC discharge on Battery Commander's own base;
ship the 2026-11-12 gauge-safety design first. All four steps
completed and live-proven the same day.

## Step 1 — RE triage: the on-AC discharge mechanism (HIGH CONFIDENCE)

The original binary no longer exists on this Mac; a copy was
obtained from the upstream public release for analysis only
(never installed, never run). The build that ran on this Mac is
**v1.2.7** (md5 `846926d4602e62ac6fd1d037ee0294bd`, 734,744 B):
its symbol addresses match the 2026-11-07 RE function table
exactly (`Center::discharge` 0x100037460,
`Center::disable_charging` 0x100037970, `Center::smc_write`
0x1000368b0). The current upstream latest (v1.2.12) has shifted
addresses and was NOT used for the mechanism read. Artifacts +
full disassembly: Mac `battopt-project/bc-build/re-work/`.

**The mechanism is NOT an SMC key write.** On the Intel path,
`Center::discharge(bool)` opens the **AppleSmartBatteryManager**
IOService and calls **IOConnectCallMethod(selector=0,
scalarInput[0]=bool, inputCnt=1)** — 1 engages discharge mode,
0 clears it. Call chain: CLI `Action::discharge` → daemon
`Batt::opDischarge` → `Batt::enable_discharging` (calls
`Center::disable_charging` FIRST — BCLM=10 — then
`Center::enable_discharging` → Intel branch → `discharge(1)` +
100 ms settle). Stop is the mirror (`discharge(0)`). Selector 1
is the separate `chargeInhibit` — do not confuse them.

Read-back: `Center::smc_discharging()` reads SMC key **ACEN**
(0x4143454E); discharging ⟺ ACEN == 0. ACEN appears exactly 4
times in the disassembly, all as smc_read arguments — the
original tool **never writes ACEN**; the manager call moves it.
The daemon polls `smc_discharging()` and re-asserts the engage
if it reads false.

**BATP/CHGC are effects, not causes:** no smc_write with those
constants exists in the discharge path. Their 2026-11-08
movement (BATP 0→1, CHGC 98→102) is downstream of the manager
dropping the adapter path (ExternalConnected Yes→No,
NotChargingReason=8) with BCLM=10/CHLC=2 unchanged — fully
consistent with the manager call being the only actuator. The
mining was also verified against the Mac repo + git history: no
old guardian/enforce variant does more than call the battopt
CLI; every call site is `sudo -n battopt discharge $TARGET`.

## Step 2 — bc-limit v1.5-gauge (deployed 14:10, backup `bc-limit.pre-gauge-20261116`)

Implements discharge-design.md §6 / the 2026-11-12 proposals:
- **Confirm-before-write:** the state file `.bc-limit-last-pct`
  becomes format v2 (confirmed baseline / candidate / last
  CurrentCapacity mAh; v1 files still parse). A ≥5-point move
  vs the confirmed baseline records a CANDIDATE and defers any
  BCLM write; the level confirms when a later tick reads within
  2 points of the candidate (`GAUGE CONFIRMED`), and is
  abandoned when the reading relaxes back within 5 of baseline
  (`GAUGE JUMP CLEARED`). A still-moving level never confirms.
- **Second-signal gate on HOLD writes:** an overshoot
  (pct > upper+2) may drive a hold write only with IsCharging,
  Amperage > 0, or CurrentCapacity rising vs the previous tick;
  otherwise `HOLD DEFERRED` (at zero current with flat capacity
  the write has no physical effect anyway; real energy flow
  always produces the evidence).
- v1.4's APG reason gate and the discharge-session suppression
  are byte-identical in behaviour.

Source md5 `3bb6d7a87435aeab1b696f9f862fe2e2`; deployed binary
`28e76f4bed3b047cbca4e5f9741901fc`. New persistent suite
`test_bc_limit_gauge.sh`: PASS=7/SKIP=1 while charging (G5b
opportunistic), PASS=6/SKIP=2 at the hold (G5a joins the skips —
it needs a charging state; both halves of the gate were
exercised across the two states).

## Step 3 — bc-limit v1.6-ac + watchdog wiring (deployed 14:13–14:27)

**Actuator (in bc-limit, the only actor — discharge-design §6):**
`set_discharge_mode()` re-implements the identified call shape
clean-room from the public IOKit API (IOServiceMatching
"AppleSmartBatteryManager" → IOServiceOpen →
IOConnectCallMethod selector 0, one scalar in, one out). It
engages ONLY when ALL hold: a valid session exists; mode is
user or corrective (NEVER calibrate — calibration drains
naturally); pct > session target; BCLM already reads the hold
value (charging inhibited first, exactly like the original);
the gauge level is confirmed (v1.5); no THERMAL APG pause (a
load-only pause does not block a user command — v1.4 reason
semantics, product rule 2026-11-15); the session has been seen
on ≥2 ticks; for a corrective overshoot premise, the v1.5
second signal (a user session needs none — the command is the
signal); and the adapter is attached or the mode already on
(adoption). While engaged, ACEN is read back every tick: a
180 s engage grace, then bounded re-assert (2, like the
original's re-assert loop), then disengage-abort. The mode is
cleared the tick any condition stops holding, and an ORPHAN
rule (ACEN=0, no live session, no engage state) always clears
it — discharge mode can never outlive its session, including
across sleep (sessions die pre-sleep; the orphan rule catches
residue). A marker file `.bc-limit-acengage` (state dir,
STARTED+SINCE) tells the watchdog monitor the session is
AC-draining. Engage/disengage state: `.bc-limit-ac-state`
(daemon exe dir). Dry-run performs no call and logs WOULD
ENGAGE / WOULD DISENGAGE.

Final source md5 `f0600db3ae3403392c37cb39d973a9b4`; deployed
binary `b97ef61f5436d470e81aa5996f8244c9` (backups:
`bc-limit.pre-ac-20261116` = v1.5, `bc-limit.pre-acgate-20261116`
= the first v1.6 build, before the thermal-gate refinement).
New persistent suite `test_bc_limit_ac.sh`: **PASS=12 FAIL=0
SKIP=1** (A9 orphan is opportunistic — ACEN reads 1 at rest).

**Watchdog (deployed md5 `ac3166df154d41632e5ce063cd42bc6e`,
both copies; backups `.pre-ac-20261116`, `.pre-acfix2-20261116`):**
- The monitor reads the marker per tick (STARTED match):
  `DS_AC_ENGAGED`, persisted `AC_WAS`/`AC_EVER`. The §5.3
  AC-flip watch EXEMPTS flips while engaged or on the tick
  after (`SESSION_AC_FLIP_EXPECTED`, flips not counted, no
  abort, no cooldown) — the engage/disengage flips are
  expected, per §6.
- **Guardian correction is real now:** `_guardian_start_corrective`
  creates a MODE=corrective session (target = configured UPPER,
  `.active_mode=discharge` so the ladder/drift layers defer —
  a mid-session config reapply would flip the config byte form
  and the monitor would read it as a supersede). Called from
  LAYER2's first overshoot detection (not-charging case; a
  charging overshoot stays the ladder's domain) and from the
  ladder COUNT≥8 gate (replacing "v1 hold-and-wait"). Blocked
  by: existing session, shadow mode, AC-flip cooldown,
  UPPER=100. Corrective entries keep the second-signal gate in
  BOTH the monitor and bc-limit — a bare gauge drift still
  cannot start a drain.
- **Two fixes from the live experiment (round 2):**
  (F1) `DS_AC_EVER` — a session that AC-drained ends parked ON
  AC at/below target by construction; the pre-actuator
  completion counter only ran unparked, so it could never
  complete. Completion now counts parked when AC_EVER=1.
  (F2) LAYER3's drift reapply skips while a real session file
  exists (the byte-form supersede hazard above; sessions
  routinely run below LOWER, where LAYER3 expects BCLM=100).
- `test_bc_watchdog.sh` updated for the new contract (Phase A:
  the COUNT-8 gate starts the session, ladder pauses at 8;
  new Phase A2: cooldown-blocked re-creation → ladder resumes →
  CRITICAL cap machinery verified unchanged; B–F shifted):
  **PASS** (all phases). Suite md5 `f84f7f935cb11df31cbc071788635feb`.

**Display + dispatch text:** display_state (both copies, md5
`63a80dd4380153abe16f3e68bbac8790`) renders a marker-matched
session as "Discharge to N% — draining on AC (discharge mode)"
(the app executes display_state.sh as its sole decider, so
parity is structural — no Swift change). Dispatch's Smart
Discharge dialog intro no longer claims sessions park on AC
(both copies, md5 `98db478c85caf43c5fb5ec2ba00e2cf3`).

**Discharge matrix hygiene:** test_bc_limit_discharge.sh cases
4/5 reset the exe-dir actuator state (fresh-daemon context;
no-op for the pinned v1.3 source). Canonical md5
`f7b7bc455dca68e72c339ad3496e12d3`, backup
`.pre-ac-20261116`.

### Minimal live experiment (14:17–14:25, target 84 via dispatch)

```
[2026-11-16 14:17:03] [REAL] SESSION_START_REQUESTED target=84 cur=86 ext=Yes starter=dispatch
[2026-11-16 14:18:00] [REAL] SESSION_ARMED mode=user target=84 started=1794831423 starter=dispatch pct=86 bclm=10 ext=Yes chg=No amp=0 cap=4273 ncr=14 apg=yellow temp=30.76
[2026-11-16 14:18:24] DISCHARGE MODE ENGAGED: manager call ok (target=84 pct=86% session_started=1794831423)
[2026-11-16 14:19:02] [REAL] SESSION_ACTIVE mode=user target=84 session=1794831423 pct=86 bclm=10 ext=No chg=No amp=18446744073709549395 cap=4270 ncr=8 apg=yellow temp=30.79
[2026-11-16 14:21:24] DISCHARGE MODE DISENGAGED: target reached (pct=84% target=84)
[2026-11-16 14:22:06] [REAL] SESSION_AC_FLIP_EXPECTED ext=Yes session=1794831423 pct=83 bclm=10 ext=Yes chg=No amp=18446744073709550966 cap=4133 ncr=14 apg=yellow temp=30.87
```
ioreg at engage: ExternalConnected=No, Amperage≈−2221 mA,
IsCharging=No, NCR=8 — the 2026-11-08 signature exactly. The
restore flip took ~40 s to appear in ioreg (the engage flip
similarly lagged the call). The drain momentum carried pct to
83 during the restore lag (1 point past target — inherent to
the mechanism). The session then sat parked-at-target (the F1
bug, found here): it was ended cleanly via the dispatch cancel
toggle at 14:24:54; EPISODE recorded (depth 3); 14:25:24
`WRITE OK: BCLM=100 verified by read-back` and the battery
charged back to the 86 hold. F1/F2 were fixed, suite-verified,
and deployed before the proof; the proof's session completed
on its own (below).

## Step 4 — regression + live proof

Regression on the final deployed code: bc-limit matrices on
the v1.6 source — calibrate 15/15, discharge 11/11, apg 9/9;
gauge suite (v1.5) green in both live states; ac suite 12/12
(+1 opportunistic skip); test_discharge 36/36; watchdog suite
PASS; charge persistence 51/51; calibration 98/98; sentinel
41/41; sidecar/dispatch 15/15; tracker equivalence PASS;
bc-verify VERIFIED exit 0; verify-install 12/12; project
health HEALTHY; plugin↔app parity PASS (146 canonical lines
identical, fresh renders).

### LIVE PROOF — Custom Limit 80/79 on AC, then restore 86/85

Via the real dispatch path (`limit_custom`, osascript stub),
battery at the 86 hold, cable attached throughout:

```
[2026-11-16 14:35:49] [REAL] SESSION_START_REQUESTED target=80 cur=86 ext=Yes starter=dispatch origin=limit-intent
[2026-11-16 14:36:18] [REAL] SESSION_ARMED mode=user target=80 started=1794832549 starter=dispatch pct=86 bclm=10 ext=Yes chg=No amp=0 cap=4274 ncr=14 apg=green temp=30.76
[2026-11-16 14:37:26] DISCHARGE MODE ENGAGED: manager call ok (target=80 pct=86% session_started=1794832549)
[2026-11-16 14:39:21] [REAL] SESSION_ACTIVE mode=user target=80 session=1794832549 pct=85 bclm=10 ext=No chg=No amp=18446744073709548979 cap=4219 ncr=8 apg=green temp=30.76
DISCHARGE_STATUS=Discharge to 80% — draining on AC (discharge mode)
[2026-11-16 14:44:26] DISCHARGE MODE DISENGAGED: target reached (pct=80% target=80)
[2026-11-16 14:45:25] [REAL] SESSION_AC_FLIP_EXPECTED ext=Yes session=1794832549 pct=80 bclm=10 ext=Yes chg=No amp=18446744073709549144 cap=3990 ncr=8 apg=green temp=30.80
[2026-11-16 14:46:25] [REAL] SESSION_COMPLETE target=80 session=1794832549 pct=80 bclm=10 ext=Yes chg=No amp=18446744073709551573 cap=3989 ncr=14 apg=green temp=30.80
[2026-11-16 14:46:25] [REAL] EPISODE id=1794832549 result=completed reason=target-reached start_pct=86 end_pct=80 depth_pct=6 duration_s=636 parked_s=60
```
Restore (same path, 86/85): config rewritten 86/85;
`[2026-11-16 14:47:28] WRITE OK: BCLM=100 verified by read-back`
— charging back, and
`[2026-11-16 14:57:29] WRITE OK: BCLM=10 verified by read-back`
at pct=86%: the hold re-engaged. **Final state (14:57):**
config 86/85 (md5 `69c6c438…`, canonical form), bc-limit
v1.6-ac holding (pct=86, BCLM=10, charging=0, external=1), APG
green, no session, no engage marker, watchdog + sentinel
healthy. The full cycle Yousef asked for — an above-limit
state on AC returning to the limit while plugged in, then
restored — is proven end to end on the real dispatch path.

## Notes / residuals

- The manager call's effect lags ~40 s in ioreg both ways;
  ACEN (SMC-side) leads. The 180 s engage grace in bc-limit
  covers it.
- One point of drain momentum past the target is possible
  during the restore lag (seen: 84→83 in the experiment; the
  proof landed exactly on 80).
- A9 (orphan clear) remains suite-opportunistic; the orphan
  rule itself is the same code path as the disengage branch
  proven live twice.
- Stage C note: the FR-007 DRAFT patch now rebases onto
  v1.6-ac and becomes v1.7 (see the stage-c-readiness
  addendum).

## Addendum — engagement-latency + icon-classification fixes (approved 2026-11-16 15:10)

Yousef tested Smart Discharge at 15:06 (target 82): it engaged
at 15:07:30 and drained correctly, but (A) press→engage took
77 s of menu silence, and (B) during the drain the menu-bar
symbol was the red circle instead of the battery. His session
completed untouched before any deploy: SESSION_COMPLETE
15:12:54, target reached (end_pct 81 — the known 1-point drain
momentum), EPISODE completed/target-reached.

### Fix A — bc-limit v1.6.1-ac (deployed 15:32; binary `7ec16c8d097f04a72feb4150bb29d34d`; backup `bc-limit.pre-aclat-20261116` = v1.6 `b97ef61f…`)

For USER sessions the 2-sighting rule is replaced by a
two-component confirmation: bc-limit reads the watchdog
monitor's `.discharge_state` and engages on its FIRST tick
once the monitor has armed the session (PHASE=armed|active,
SESSION_STARTED equal to the session's STARTED). A user
session the monitor has not armed never engages (new log
line: `DISCHARGE MODE WAITING: user session not yet armed by
the monitor`). CORRECTIVE sessions keep the 2-sighting rule;
every other v1.6 gate is unchanged. Source
`bc-limit-v1.6.1.c` (md5 `8c331494161ab998a909c3d60589b522`),
clang zero warnings.

Live proof (Smart Discharge via the real dispatch path,
target 83, cable attached throughout):

```
[2026-11-16 15:35:24] [REAL] SESSION_START_REQUESTED target=83 cur=86 ext=Yes starter=dispatch
[2026-11-16 15:35:42] DISCHARGE MODE WAITING: user session not yet armed by the monitor (no engage)
[2026-11-16 15:36:15] [REAL] SESSION_ARMED mode=user target=83 started=1794836124 starter=dispatch pct=86 bclm=10 ext=Yes chg=No amp=0 cap=4298 ncr=14 apg=red temp=30.72
[2026-11-16 15:36:42] DISCHARGE MODE ENGAGED: manager call ok (target=83 pct=86% session_started=1794836124)
[2026-11-16 15:39:44] DISCHARGE MODE DISENGAGED: target reached (pct=83% target=83)
[2026-11-16 15:41:22] [REAL] SESSION_COMPLETE target=83 session=1794836124 pct=83 bclm=10 ext=Yes chg=No amp=18446744073709551550 cap=4128 ncr=14 apg=red temp=30.88
[2026-11-16 15:41:45] WRITE OK: BCLM=100 verified by read-back   (charge-back)
[2026-11-16 15:46:46] WRITE OK: BCLM=10 verified by read-back    (hold re-engaged at 86%)
```

ENGAGED is the first daemon tick after ARMED. Press→engaged
78 s = 51 s monitor arming cycle + 27 s to the next daemon
tick; the daemon no longer adds a sighting tick of its own
once both components have confirmed (under v1.6 the same
press pattern cost up to ~2 daemon ticks after arming in the
worst phase alignment). APG read red (load) at arming —
bypassed per the product rule, temp 30.72 °C.

### Fix B — icon classification (display_state `f8ba2fedd8c2180907ee049d2663e05c`, plugin `86c718e5ee53da3dc51550182ae52780`, StatusProvider.swift `f1a784703f93698f8e5579f05a2e17a8` — app source only)

Per Yousef's correction (15:14) the icon set is a state map
and did not change: 🔌 = on charger (not charging), ⚡ =
charging, 🔴 = genuine battery use, 🔋 = the tool's discharge
mode. The defect was classification: the manager's adapter
flip (ExternalConnected=No) made a draining session render as
plain battery use. display_state.sh (the sole decider) now
classifies a live session as draining — 🔋, colour #8A9AAB —
when the engage marker's STARTED matches the session's (AC
mode), or when EXT=No and the monitor's state for this
session is armed/active (on-battery drain). An armed session
parked on AC keeps 🔌; battery use with no session keeps 🔴.
The plugin and app decider-absent fallbacks gained the
marker check. Fixture renders (stubbed ioreg, before →
after): ac-drain 🔴 → 🔋, battery-drain 🔴 → 🔋,
plain-battery 🔴 → 🔴, parked-ac 🔌 → 🔌, hold-ac 🔌 → 🔌.
Live render during the proof drain — plugin title:
`🔋 87% | size=14 color=#8A9AAB`; display_state direct:
`ICON=🔋`, `DISCHARGE_STATUS=Discharge to 83% — draining on
AC (discharge mode)`. The bench app build with the patched
StatusProvider compiles clean (bundle verified, 1.6 MB); the
installed app was NOT rebuilt — Stage C owns that.

### Regression (final deployed code)

ac suite **14 PASS / 0 FAIL / 1 SKIP** (A9 opportunistic;
the A6b second-signal seed is re-armed between ticks — tick
1 consumes it by recording the live capacity; the first
battery run also caught A6a engaging on a genuine residual
second signal seconds after the charge-back hold write —
the gate working as designed, re-run at a settled hold:
PASS). Matrices on the v1.6.1 source: calibrate 15/15,
discharge 11/11, apg 9/9. Gauge suite 6 PASS / 2 SKIP
(state-opportunistic halves, as at v1.5). Discharge monitor
36/36; watchdog PASS; charge persistence 51/51; calibration
98/98; sentinel 41/41 (re-run post-deploy: PASS); sidecar
15/15; tracker equivalence PASS; bc-verify VERIFIED exit 0;
verify-install 12/12; project health HEALTHY (17 PASS /
0 FAIL); plugin↔app parity PASS (146 canonical lines, fresh
renders).

**Final state (15:47):** config 86/85 (canonical md5),
bc-limit v1.6.1-ac holding (pct=86, BCLM=10, charging=0,
external=1), no session, no engage marker, watchdog +
sentinel healthy, soak undisturbed (one daemon kickstart;
app/plugin files updated in place, login item untouched,
applet PID 21524 untouched, no commit). FR-007 still
rebases onto the live daemon at Stage C and becomes v1.7.
