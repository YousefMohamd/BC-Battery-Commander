# Calibrate-Phase BUILD — Note (2026-11-14)

Status: **BUILD COMPLETE, deployed INERT. No calibration run was started.**
Approved by Yousef 2026-11-14 18:54 EET ("ابدأ بناء مرحلة المعايرة"). The live
run is a separate later approval. Design: `calibrate-design.md`. Build/deploy
discipline follows `discharge-build-note.md`. Deploy finished 2026-11-14
~19:32 EET after a brief tunnel outage (502→530 at 19:29–19:30, recovered;
nothing was left half-deployed — the binary swap and all file copies had
already confirmed before the drop, and every md5 was verified after).

## What was built

1. **bc-limit v1.3-calibrate** (`battopt-project/bc-build/bc-limit-v1.3.c`,
   md5 `71fac1d9…`): the ONLY delta from v1.2 is the calibrate session
   contract (below). Routine user|corrective behaviour byte-identical.
2. **Run supervisor** — a new layer in `bc-watchdog.sh` beside the discharge
   monitor (`section_calibration_supervisor`, called immediately after the
   monitor in both the normal and the snapshot-fail paths). Owns
   `~/.battery-commander/.calibration_run` (heartbeat every tick), walks
   L0→L1→L1R→L2→L3→L4→L5, and funnels every abort/cancel/failure into the
   one safe state (session removed → posture restored+verified → config
   restored → run file removed → one notification with the reason).
3. **Monitor extension** (same file): MODE=calibrate sessions are validated
   with the same run cross-check as bc-limit v1.3; the armed/active floor
   checks use the run's ABS_FLOOR for calibrate sessions (routine sessions
   keep DISCHARGE_FLOOR_ABS); routine sessions are refused while a run is
   live (rule 10); PARK=1 calibrate sessions move straight to the
   active-parked state and are exempt from the routine park timeout (the
   supervisor owns the L3 timer).
4. **Auto-profile by battery health** (dispatch `calibration_profile`,
   below).
5. **Dispatch + plugin wiring**: `calibrate` is a real start/cancel toggle
   (Smart Discharge pattern); new `calibrate_resume` action (marker only —
   the supervisor re-checks every resume gate); internal
   `calibration_apply_limit` (the single bc_apply_limit primitive; the
   supervisor's only config path) and `calibration_posture_on/off`
   (battery-scope `pmset sleep` 0 with the previous value recorded and the
   restore verified by re-reading); Smart Discharge refuses over a
   calibration session; `kill_calibrate` = remove session now + cancel
   marker. Plugin: the "Not in v1 yet" text is gone (audit R3) — the
   section shows Start / Resume (at a checkpoint) / Cancel / Force Stop,
   and display_state.sh emits a CALIBRATION_STATUS line (leg-aware:
   "Calibrating: draining to 10%", "Calibration paused at N% — tap Resume
   Calibration", "Calibration: plug in — resting at 10%", …).
6. **Companions**: pre_sleep_cleanup writes the RUN_CHECKPOINT line to
   calibration.log when a calibrate segment dies at WillSleep;
   cleanup_logs rotates calibration.log; project_health gained a
   CALIBRATION section (run active/stale, posture active).

## bc-limit v1.3 contract (the only enforcer delta)

A `MODE=calibrate` session is valid only if ALL hold: session carries
`RUN=<id>`; a `.calibration_run` file exists in the same directory with an
equal `RUN_ID`; its `HEARTBEAT` is a strict integer ≤ 600 s old and not
> 60 s in the future (CALIBRATION_RUN_STALE_MIN=10); its `ABS_FLOOR` is a
strict integer inside the hard clamp [8, 20]; `TARGET ∈ [ABS_FLOOR, 99]`;
plus the unchanged session rules (STARTED strict, ≤ DISCHARGE_MAX_MINUTES
old). Any failure → the session is invalid exactly like any bad session
(normal rules; v1.2 behaviour). The clamp means a forged run file can
never authorize a drain below the design emergency bound of 8%.

## Auto-profile as implemented (Yousef's direction, 2026-11-14)

Read at run start from bc-status: health = FullChargeCapacity /
DesignCapacity, plus CycleCount. Written into the run file + calibration
log (RUN_CREATED line) and shown in the start dialog.

| Band | Condition | Floor | Emergency abort | Supervision line |
|---|---|---|---|---|
| high | health ≥ 80% (and cycles ≤ 1000) | 10% | 8% | none |
| mid | health 60–80% (and cycles ≤ 1000) | 10% | 8% | 30% |
| low | health < 60% **or** cycles > 1000 | 15% | 12% | 35% |

Rests (all bands): top rest 60 min, low rest 30 min, close-out rest
30 min. This Mac: 5209/6900 = 75.5%, 568 cycles → **mid** (floor 10,
emergency 8, supervision 30). Unreadable health data → start refused
(never calibrate blind).

## State-machine safety argument

- **Single writer**: only bc-limit writes BCLM; the supervisor writes
  files and delegates config to dispatch's bc_apply_limit and posture to
  dispatch's pmset actions (both verify by re-reading).
- **Two-signal endpoints only**: full = pct=100 on 2 consecutive
  non-gauge ticks AND charge termination observed (IsCharging=No on AC,
  or Amperage 0); floor = pct ≤ FLOOR on 2 consecutive non-gauge ticks
  AND pack voltage ≤ 10.9 V. A completion tick folds its own reading
  into the floor record before classification. If the gauge claims the
  floor but voltage disagrees, the leg continues to the emergency bound
  in a fresh segment; at the bound without voltage confirmation the run
  aborts (honest failure, safe state) instead of anchoring a false floor.
- **Sleep = checkpoints, never survival**: segments are removed at
  WillSleep by pre_sleep_cleanup (a path independent of the supervisor);
  resume requires 120 s post-wake + APG green + pct ≥ FLOOR+15 + a fresh
  explicit user tap; a wake reading ≤ FLOOR aborts the run as failed.
  L4 (recharge) is the one leg allowed to cross sleep, and its
  completion is evaluated before its time bound.
- **The forbidden combination** (% below lower + charger attached +
  asleep + charge suppressed) is structurally unreachable:
  (1) charge suppression exists only while a session file exists;
  (2) L2 segments are issued only on battery (EXT=No) — a segment can
  never be created in the plugged-in state; (3) any session is deleted
  at WillSleep before sleep completes, so a sleeping Mac never holds a
  suppression authority — and even if that deletion failed, bc-limit's
  own bounds (session ≤ 240 min, run heartbeat ≤ 10 min) expire the
  suppression on their own; (4) the only plugged-in suppressed state is
  the deliberate floor park (awake, supervised, L3-bounded at 2 h wall),
  and parking that crosses a sleep resolves on wake to normal
  enforcement with no user action. The worst residual case is the
  design's accepted one: the Mac sits at the floor on AC for one sleep —
  the same physical state as the designed L3 rest, never below
  ABS_FLOOR, never silent (checkpoint + notifications), never
  indefinite.
- **Fail-safe**: corrupt run file = no run (deleted + logged; config
  untouched because the base is unknowable; any calibrate session
  removed). Two consecutive unreadable battery ticks abort the run.
  Supervisor death is bounded by the bc-limit/monitor staleness checks;
  on the watchdog's return the run either resumes within its bounds or
  aborts to the safe state (both proven in T1 A6/A8).
- **Rule 14**: the supervisor watches EXPECT_U/L every tick; a deliberate
  mid-run limit change ends the run and the user's value is never
  stomped (A10).

## Tests (all sandbox; live config md5 guarded)

- `test_bc_limit_calibrate.sh` (new): **15/15** — routine regression
  subset R1–R4 against the v1.3 binary + calibrate K1–K11 (valid run
  honoured; stale heartbeat, forged RUN, TARGET below ABS_FLOOR, missing
  run file, garbage run file, future heartbeat, forged ABS_FLOOR=1,
  missing RUN line, TARGET == ABS_FLOOR inclusive, stale session
  STARTED — all degrade to "no session"). Zero-warning compile required.
- `test_calibration.sh` (new): **98/98** —
  Part A (watchdog sandbox, fake clock): A1 full happy path L0→L5 with
  monitor-driven segments, park, report; A2 L1 bound abort; A3 L2
  AC-flip abort; A4 L3 bound abort; A5 L4 APG abort; A6 stale heartbeat
  revived; A7 sleep checkpoint + all three resume gates (wake window,
  pct < FLOOR+15, then success); A8 stale segment after supervisor death
  → safe abort; A9 corrupt run file; A10 config supersede; A11 two
  unreadable ticks abort; A12 rule-10 refusal; A13 forged session vs
  stale run heartbeat refused by the monitor; A14 gauge-floor
  unconfirmed → continuation at ABS_FLOOR → floor reached; A15 L4
  completion before bound.
  Part B (dispatch sandbox): B1 auto-profile bands 85/75/55/cycles-1200;
  B2 start refused over a session; B3 start refused on stale watchdog;
  B4 cancel marker; B5 resume marker only at a checkpoint; B6 posture
  on/off round-trip with verified restore; B7 Smart Discharge guard;
  B8 apply-limit primitive. Live-config md5 asserted unchanged.
- Regressions (final code): `test_discharge.sh` **16/16**,
  `test_bc_watchdog.sh` **PASS**, `test_charge_persistence.sh` **20/20**,
  `test_bc_limit_discharge.sh` (v1.2 matrix vs archived v1.2 source)
  **11/11**.

## Deploy (2026-11-14 ~19:31 EET)

- Daemon binary: `battopt-project/bc-build/bc-limit` → v1.3, md5
  `c9ddf76a…`; backup `bc-limit.pre-calibrate-20261114` = v1.2 binary,
  md5 `8455134b…`. Reload: `sudo -n launchctl kickstart -k
  system/com.batterycommander.bclimit`. First ticks verified in
  bc-limit-daemon.log: `bc-limit 1.3-calibrate starting (dry_run=0)`
  19:31:49; state ticks `upper=86 lower=85 pct=86% BCLM=10 charging=0
  external=1` (normal hold).
- Scripts (repo == deployed md5, chmod +x verified on every file;
  backups `<file>.pre-calibratebuild-20261114` in
  `~/.battery-commander/backups/`, plugin backup likewise — NOTHING left
  in ~/SwiftBar except the plugin):
  bc-watchdog.sh `9e0e14d8…`, dispatch.sh `766cbb9a…`,
  pre_sleep_cleanup.sh `3cfeaf1a…`, cleanup_logs.sh `fd8e22da…`,
  project_health.sh `1208c07f…`, display_state.sh `e860a483…`,
  plugin battery-commander.10s.sh `1c1ce14c…`.
- Post-deploy proofs: plugin headless render shows the real Calibration
  section ("Start Calibration", no "Not in v1 yet") and the live daemon
  line (86% · BCLM=10 · holding); watchdog heartbeat 47 s old; config
  86/85; battery-scope sleep still 18 min (posture untouched); health
  check gained "✅ PASS: No calibration run active" (summary 16 PASS /
  1 FAIL / 2 WARN — the FAIL is `womp` = 1, Yousef's own Wake-on-Network
  toggle from 2026-11-13; the health expectation is stale, not a deploy
  defect; WARNs are load during the test runs + the known swap).
- **INERT**: no `.calibration_run`, no `.discharge_session`, no
  calibration.log in the state dir; no run started; no SMC writes beyond
  the daemon's normal 86/85 enforcement.

## Observations (not fixed — outside this build's scope)

1. **Monitor gauge-defer freeze (pre-existing)**: the discharge
   monitor's DS_LAST_PCT freezes on a ≥5-point tick, so a genuine
   one-time gauge re-anchor of ≥5 points mid-session defers every
   later tick of that session (it ends by max-age; the next segment
   starts clean). Production drain is ~1%/tick, so this needs a real
   re-anchor event; the supervisor's continuation chaining absorbs it
   for calibration. Worth a future monitor fix (age the frozen value).
2. Segment-level monitor notifications during a run say "Discharge
   complete/aborted…" (the monitor's wording); the supervisor's own
   run-level notifications carry the calibration meaning.
3. Health-check `womp` expectation (0) vs Yousef's deliberate setting
   (1) — a one-line expectation decision for a later cleanup.

## Live-run day checklist (for Yousef — separate approval)

Your part is ~20 minutes of attention across one long day. Nothing
restarts, nothing closes — browser and apps stay open throughout.

1. **Morning, plugged in**: tap **Calibration → Start Calibration**.
   The dialog shows the auto-profile for your battery (mid band:
   floor 10%, emergency stop 8%, supervision line 30%) and your
   current limit (restored automatically at the end). Confirm.
2. It charges to 100% and rests 1 h on AC. Leave it plugged in.
3. When the menu says **"Calibration: unplug to drain to 10%"**,
   unplug and work normally. The drain leg rides your normal use
   (≈4–6 h). Anti-sleep is on for this leg only (display may sleep;
   the Mac itself won't).
4. **~5 taps total**: if you sleep the Mac or a pause checkpoint
   appears (heat/load), tap **Resume Calibration** after waking —
   it re-checks safety before continuing. If a segment pauses for
   heat/load, let it cool and tap Resume.
5. **Stay nearby below 30%**, and **do not close the lid during the
   low leg** (below ~25%): the end of the drain needs you present.
6. At the floor it asks you to **plug in**. Plug in and leave it:
   30 min low rest, then the final recharge to 100% (this leg MAY
   cross lid-closed sleep), 30 min rest, and it restores **86/85**
   and writes the run report by itself.
7. Cancel anytime from the same menu — it lands in the safe state
   (your limit + power settings restored) within a minute.
