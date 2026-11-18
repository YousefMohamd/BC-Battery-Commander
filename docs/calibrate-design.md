# Battery Commander (BC) — Calibrate Phase Design

- **Status:** DESIGN ONLY — not built, not approved for build. Awaiting Yousef's approval (design-before-build rule; the calibrate phase needs its own separate approval, and its supervised live run needs a further separate approval on a named day).
- **Date:** 2026-11-13
- **Scope of this document:** the design of BC's calibration capability — a supervised, multi-leg full cycle that re-teaches the battery's gas gauge its true endpoints. No code is specified to implementation level; no behaviour of the running system changes because of this document.
- **Related:** `discharge-design.md` (the session contract this design extends), `limit-writer-design.md` (bc-limit), `phase-c-plan.md` (enforcer swap — complete 2026-11-13), `wrapper-design.md` (W1–W6; calibrate is a menu stub today), `plan-rebuilt-2026-11-12.md` (Stage 5), `natural-verification-design.md` (episode scoring; a "calibrate day" is one of its episode types).
- **Clean-room note:** this design is derived from BC's own architecture, BC's own measurements, and the standard gas-gauge calibration procedure. From reverse engineering, only the old tool's *interface* facts are used: it exposed a `calibrate` CLI command (and `calibrate stop`), started detached by the wrapper, reported a calibration enabled/disabled flag in status, and was treated by the wrapper as a long-running session mode. Its internal legs and end conditions were **not** traced, and nothing about them is assumed or copied below — every leg, endpoint, and bound in this document is BC's own design decision, stated with its reasoning.

---

## 1. Purpose and scope

### 1.1 What "calibrate" means in BC

A **calibration run**: a bounded, checkpointed procedure that walks the battery through one full, verified cycle —

```
verified full charge → rest → controlled discharge to a defined low endpoint → rest → verified full recharge → restore the normal limit
```

— so the battery's gas gauge (a TI bq20z451) can re-learn where "full" and "empty" actually are on this aged pack.

The gauge is a model, not a meter. It integrates current over time and corrects itself against voltage at the endpoints. On a pack that lives its whole life between 85 % and 86 % (BC's own limit band), the gauge almost never sees an endpoint, and its model drifts. That drift is not hypothetical on this machine; it is measured (§2). Calibration is the periodic, deliberate endpoint visit that re-anchors the model.

### 1.2 What calibration is FOR — stated honestly

- **More honest numbers.** `MaxCapacity` / Full Charge Capacity and the derived Health % should converge toward the pack's true capacity. Health may move **down** as easily as up: calibration buys honesty, not capacity. Nothing in this procedure restores a worn cell, and the design never promises an improvement in the number — only in its truthfulness.
- **Fewer gauge surprises.** The re-estimation jumps (§2) happen because the model is stale. A gauge that has recently seen both endpoints has less to correct in one step.
- **A percentage the whole system can trust.** bc-limit, the discharge monitor, the morning report, and Yousef all act on the same %. Every phase built so far inherits the gauge's error; calibration is the only phase that reduces it at the source.

### 1.3 What calibration is NOT

- **Not a battery repair or a health treatment.** One cycle on a 568-cycle pack neither heals nor meaningfully wears it (see §7, rule 6, for the stress weighing).
- **Not routine.** It is a rare, deliberate, named-day procedure — expected frequency a few times a year at most, or after events that confuse the gauge (a battery or logic-board service, a visibly wrong MaxCapacity). It is never automatic and never scheduled by the tool.
- **Not one discharge session.** The discharge phase's session is a single bounded drain. Calibration is a *sequence* of legs with checkpoints between them (§5), because a full cycle is longer than any single session may live, and longer than a Mac should be assumed to stay awake.
- **Not an SMC reset.** An SMC reset is a separate, postponed item in the project plan with its own approval; nothing here touches SMC state beyond bc-limit's normal BCLM writes.
- **Not a reason to weaken routine safety.** The discharge floor for everyday sessions stays exactly where it is. Calibration's deeper floor exists only inside a run, under §7's conditions (§3.2).

### 1.4 In scope / out of scope

In scope: the run/leg state machine, checkpoint and resume semantics, endpoint definitions, the bc-limit contract delta, supervision model and day plans, power-posture handling, safety rules, menu wiring, logging and run reporting, test plan.
Out of scope: any change to routine discharge behaviour, assisted (induced-load) draining (rejected for discharge; the rejection stands here — §4), automatic or scheduled calibration, SMC reset, and any change to bc-limit's non-session rules.

---

## 2. Evidence this design is built on

All readings are BC's own, from this machine:

1. **The gauge re-estimates, visibly and largely.** 86 %→93 % in ≤ 60 s at `Amperage=0`, `IsCharging=No` (2026-11-11 19:00); 83→90 % in 1 m 38 s (2026-10-30). On 2026-11-13 the same behaviour appeared in miniature twice in one evening: the reading settled 88.7 %→85.4 % within minutes of unplugging (a stale high estimate relaxing under load), and read 86.7 % after a charge leg that the daemon log proves stopped at exactly 86 % (a decimal estimate drifting above a verified stop). The gauge's model and the pack's reality are measurably apart.
2. **MaxCapacity drifts between readings.** 5228 mAh → 5266 mAh across the S3 night (2026-11-12→13) with no calibration event — the gauge revising its own capacity estimate by ~0.7 % overnight, unprompted. Live baseline (2026-11-13, bc-status): Design 6900 mAh, Health **76.3 %**, Cycle **568**, "Service Recommended" per the project record. A drifting FCC on an endpoint-starved gauge is the textbook precondition for calibration.
3. **Sleep drain is measured, and it prices every overnight case.** S1 (2026-11-11→12): ≈ 1.4 %/h. S3 (2026-11-12→13, zero DarkWakes): ≈ **1.24 %/h** — the machine's wake-independent floor, ≈ 13 points over a 10.5 h night. Any design step that lets the Mac sleep at a low percentage has to budget ~13 points of unsupervised drain per night (§5.4, §7 rule 7).
4. **The session machinery calibration needs is already proven live.** The discharge phase (built 2026-11-13) ran a real session the same evening: bc-limit honoured the session file, logged `discharge session: resume suppressed (target=80)` when the charger was attached mid-session, and the monitor armed, tracked, suspended, and closed the episode with full tick data in `discharge.log`. The one defect found (completion vs. APG-suspend ordering) was fixed and deployed the same night (monitor v-fix, tests 16/16). Calibration reuses this machinery; it does not invent a second one.
5. **The old tool treated calibration as a first-class long procedure.** CLI `calibrate` / `calibrate stop`; the wrapper started it detached (`nohup`), carried a `calibration` mode with its own menu icon (⚡), and its status exposed a calibration enabled/disabled flag (live baseline 2026-11-07: disabled). That is interface evidence only — but it confirms the procedure's expected shape: hours-long, stoppable at any time, visible in status.

Standing project rules that also bind this design: never drain critically low (calibration's floor debate is held openly in §7 rule 6, not smuggled past this rule); **never combine % below lower + attached charger + sleep**; stability > consistency > flexibility > features; tests are natural, on named days, never forced.

---

## 3. Relationship to the discharge phase — what extends, what relaxes

### 3.1 What calibration reuses unchanged

- **bc-limit remains the only BCLM writer.** No new writer, no new daemon.
- **The session file is still the whole bc-limit contract.** A calibration discharge leg *is* a discharge session with different parameters and a supervisor above it.
- **Natural drain only.** Energy leaves under the user's real load, on battery, exactly as in discharge. On AC a leg parks; the adapter path is never manipulated (the designed-out mechanism stays designed out).
- **The watchdog monitor's discipline:** two-tick confirmation, gauge-jump deferral (a single-tick |ΔPCT| ≥ 5 % decides nothing), APG suspension/abort, AC-flip abort with cooldown and no auto-retry, fail-safe on unreadable data, everything logged with raw tick readings.

### 3.2 What calibration relaxes — explicitly, and only inside a run

| Discharge rule (routine) | Calibration treatment | Why |
|---|---|---|
| Absolute floor `DISCHARGE_FLOOR_ABS` = 20 % (targets validated to [20, 99]) | **Target floor 10 %** for the discharge leg; emergency abort at 8 % (§7, rule 6) | The gauge's low endpoint lives below 20 %. A "calibration" that stops at 20 % never shows the gauge the bottom fifth of the pack — precisely where its model is stalest. The relaxation is one-off, supervised, and checkpointed; it is not a new routine setting. |
| Session lifetime ≤ `DISCHARGE_MAX_MINUTES` (240), staleness bound on `STARTED` | Legs are **segments**: each segment is a normal session within the 240-minute bound; a run chains segments across checkpoints (wake/user resume) up to a 72 h run bound (§5.4) | A full discharge leg of a 6900 mAh-design pack takes longer than 4 h at realistic loads. Rather than stretching one session's staleness bound (which exists so a dead monitor can't suppress charging), the run re-issues fresh sessions per segment — the fail-safe bound never moves. |
| Park timeout 30 min ends a session as incomplete | A calibration **park is a designed checkpoint state**, not a failure: parking on AC holds position safely for hours (the two-day plan's overnight state, §6) | Parking is the only state that is simultaneously no-drain, no-charge, and sleep-safe at moderate %. The run uses it deliberately instead of fighting it. |

Everything not listed here is inherited unchanged — and several rules **tighten** for calibration (§7, rules 2, 7, 13, 14).

---

## 4. Mechanism decisions

- **Full-charge legs use the existing temporary-limit mechanism.** "Charge to full" = write the temporary limit 100/99 to BC config (the same mapping the wrapper already uses for Charge to 100%) and let bc-limit enforce it. No bc-limit force-charge mode is introduced. Restoring calibration's config afterwards is a config write back to 86/85, owned by the run supervisor and verified by read-back of the config file.
- **The discharge leg is a chain of discharge sessions** with `MODE=calibrate`, issued by the run supervisor (via dispatch, the same writer as user sessions), each with `TARGET` = the calibration floor and a `RUN` field naming the run (§5.2). The monitor supervises each segment exactly as it supervises routine sessions, plus the run-level rules.
- **No assisted load.** Rejected for discharge v1 (fights the APG guard, useless on AC, against the project's natural-use doctrine); the same reasoning applies a fortiori to a leg whose whole point is a *representative* drain. The cost is elapsed time (§6 prices it honestly).
- **No new components.** The run supervisor is a layer in bc-watchdog beside the session monitor (the watchdog already owns APG classification, the WillSleep-adjacent state, and the 60 s tick). State is two files in `~/.battery-commander/`: the run file and `calibration.log`. The plugin gains one status line via `display_state.sh`, as discharge did.

---

## 5. The run: legs, files, and checkpoints

### 5.1 Overview

```
L0 Preflight ──▶ L1 Charge to verified full ──▶ L1r Rest at full ──▶ L2 Discharge leg (segments, checkpoints)
      │                    │                            │                        │
      ▼ abort              ▼ abort                      ▼ abort                  ▼ floor confirmed
   (no state)          safe state                   safe state            L3 Low rest ──▶ L4 Recharge to verified full
                                                                                 │                    │
                                                                                 ▼ abort              ▼
                                                                            safe state          L5 Close-out ──▶ run report
```

**The safe state — the destination of every abort, cancel, and failure in every leg — is one thing:** session file removed, run file closed and removed, BC config restored to the user's normal limit (86/85, unless the user themselves changed it mid-run — §7 rule 14), power posture restored (§5.5), one notification with the reason. From any point in the run, any failure lands on ordinary bc-limit enforcement of the normal limit. There is no leg whose failure leaves calibration semantics behind.

### 5.2 The run file (the contract above the session contract)

`~/.battery-commander/.calibration_run`, `KEY=value`, written atomically, owned by the watchdog run supervisor:

```
RUN_ID=1763050000        # epoch at creation; also the value sessions must carry
LEG=L2                   # current leg: L0|L1|L1R|L2|L3|L4|L5
FLOOR=10                 # the calibration floor for this run (validated, §7 rule 6)
STARTED=1763050000       # run creation epoch (72 h bound measured from here)
HEARTBEAT=1763053600     # refreshed by the supervisor every tick
BASE_MAXCAP=5266         # baseline snapshot from L0 (mAh)
BASE_HEALTH_X10=763      # baseline health ×10 (76.3)
SEGMENTS=2               # discharge segments issued so far
EXPECT_CONFIG=100/99     # the config the run itself set (supersede detection, §7 rule 14)
```

- **bc-limit's contract delta (the only bc-limit change this design requires; a v1.3):** session validation learns one new mode. Today (v1.2) a session is valid if `MODE` ∈ {user, corrective} and `TARGET` ∈ [20, 99] and `STARTED` is within `DISCHARGE_MAX_MINUTES`. v1.3 adds: a session with `MODE=calibrate` is valid only if **all** of: `TARGET` ∈ [`CALIBRATION_FLOOR_ABS`, 99] (10–99 at the recommended constants — the target may not be set below the run floor mechanism's own absolute bound), the session carries `RUN=<id>` and a run file exists with `RUN_ID` equal to it, and the run file's `HEARTBEAT` is no older than `CALIBRATION_RUN_STALE_MIN` (10). A calibrate session that fails any check is ignored exactly like any invalid session file today (normal rules apply; the monitor deletes-and-logs it). Routine modes are byte-for-byte unaffected.
- **Why the cross-check matters:** the deeper floor must be unreachable by anything except a live, supervised run. A stale, forged, or leftover calibrate session file degrades to *no session*, and the run file's heartbeat bounds a dead supervisor to minutes, not hours.
- The run supervisor — never bc-limit — creates, advances, and closes the run file, issues and ends leg sessions, applies and restores the temporary config and the power posture, and writes `calibration.log`.

### 5.3 The legs

**L0 — Preflight (checkpoint; user present; minutes).**
Health check green; no APG pause; no session active; charger known-good (a flip-abort in the last 7 days warns, per the discharge design's pattern rule). Baseline snapshot recorded in the run file and the log: %, mAh (`CurrentCapacity`, `MaxCapacity`), Health, Cycle, Voltage, temperatures, BCLM, config. The user confirms the day plan (§6) and the floor. Only then is the run file created.
*Abort:* nothing has changed yet; abort is a no-op.

**L1 — Charge to verified full (on AC; may run unattended).**
Run writes the temporary limit 100/99 (config read-back verified; `EXPECT_CONFIG` recorded). bc-limit charges. **"Full" is a two-signal endpoint** (§7, rule 2): `PCT = 100` on 2 consecutive ticks **and** charge termination observed (`IsCharging = No` with `ExternalConnected = Yes`, or `Amperage` fallen to ~0 after having been positive) — the physical charger stops; the % alone never declares full. Bound: 6 h; not reaching full aborts the run (a pack that cannot terminate a charge is a finding, not something to push through).
*Then L1r — rest at full, 60 min, still on AC, limit still 100/99 (hold at full).* Gauge learning happens at rested endpoints; skipping the rest would waste the leg. The rest is a timed supervisor state, not a session.

**L2 — Discharge leg (on battery; the deep leg; segmented, checkpointed).**
Checkpoint (user present): the user unplugs. The supervisor issues a `MODE=calibrate` session with `TARGET = FLOOR`. The segment behaves exactly like a discharge session — confirmation, gauge deferral, APG suspend/abort, flip watch — with three run-level additions:
  1. **Anti-sleep posture** is asserted for the segment (§5.5).
  2. **Progress checkpoints:** at 50 %, 30 %, and 20 % the supervisor logs a checkpoint and notifies (log-only at 50/20; a real notification at 30 — below 30 the run asks for the user to be around, §6). Crossing 20 % is where routine rules would have stopped; the log marks it as the deliberate calibration-only descent, with the run's floor restated.
  3. **Segment ends** — sleep (§5.4), APG abort, flip abort, user pause, or floor reached — close the segment; the run either advances (floor) or parks at a checkpoint awaiting resume. Resume is always a fresh segment, issued only under §5.4's conditions.
**Floor confirmation is a two-signal endpoint** (§7, rule 2): `PCT ≤ FLOOR` on 2 consecutive ticks **and** pack voltage in the low band (≤ 10.9 V — at a true ~10 % on this pack, voltage is measurably near the knee; a % reading in the low band with a healthy voltage is gauge fiction and does not end the leg — the leg continues to the emergency bound logic instead, and the discrepancy is logged as a finding).

**L3 — Low rest (checkpoint; user present at entry; 30 min).**
On floor confirmation the segment session ends; the user is notified to plug in **now** (this is the run's one genuinely time-sensitive moment). Once on AC, the supervisor immediately issues a fresh `MODE=calibrate` session with `TARGET = FLOOR` — which, at `PCT = FLOOR` on AC, parks: bc-limit's proven session behaviour suppresses the resume write, so the pack rests at the bottom endpoint, plugged in, neither draining nor charging, for 30 min. (This reuses tonight's verified `resume suppressed` mechanics verbatim; no new bc-limit state.) If the user does not plug in within 30 min of floor confirmation, the run re-notifies once and starts a drain watch: at `PCT ≤ FLOOR − 3` unplugged, the run aborts loudly (the battery is leaving the designed envelope on its own drain — the only safe advice left is *plug in*, repeated once).

**L4 — Recharge to verified full (on AC; may run unattended, may cross a night).**
The L3 session is removed; with the temporary limit still 100/99, bc-limit charges. Full is confirmed by the same two-signal endpoint as L1. Bound: 8 h. This leg may span sleep freely: enforcement pausing in sleep is harmless here because the temporary limit *is* 100 — there is nothing above full to overshoot into, and the pack's own charger terminates the charge. (This is the explicit asymmetry with L2: sleep during a *charge-to-full* leg risks nothing the design protects; sleep during the *discharge* leg is forbidden by §5.4.)

**L5 — Close-out (checkpoint; minutes; user reviews).**
Rest 30 min at full; restore config to 86/85 (read-back verified); restore power posture if any lingers; close and remove the run file. Post-run snapshot recorded (same fields as L0; Cycle will have advanced by 1). The run report (§8) is written and the user notified once. The battery now sits at 100 % under an 86 % limit: it will settle back to the band by ordinary use over the following days. The design deliberately does **not** force it down (§11, Q3).

### 5.4 Sleep — the case this design is shaped around

Sessions die at sleep; that rule is inherited without exception (the WillSleep hook ends any leg segment and the supervisor writes the run checkpoint before sleep completes). The **run** survives sleep only as a parked checkpoint in its file. Concretely:

- **Sleep during L2 is a pause, never a continuation.** The segment ends; the Mac sleeps and drains at its natural ~1.24 %/h — ordinary sleep drain, not calibration draining. **Resume is never automatic:** after wake, the supervisor offers resume and a fresh segment is issued only when (a) the post-wake window (120 s) has passed, (b) APG is clear, (c) `PCT ≥ FLOOR + 15` — the resume margin — and (d) the user confirms (a menu tap; the run's status line reads "Calibration paused at N% — resume?").
- **The resume margin is the structural guarantee.** The deepest a segment may be when sleep can occur is bounded by supervision (§6: below 30 %, the user is around; a user who sleeps the Mac mid-descent does so from a checkpoint or an explicit pause). From any plausible sleep-entry point ≥ `FLOOR + 15` = 25 %, one full night of worst-observed sleep drain (~13 points) cannot cross the 10 % floor unsupervised — and the supervisor checks on wake regardless: a wake reading below `FLOOR + 15` blocks resume, and a wake reading at/below `FLOOR` (which the margin makes a should-never-happen) aborts the run as a scored failure with an immediate plug-in notification.
- **The forbidden combination stays forbidden.** % below lower + charger attached + sleep + suppressed charging remains unreachable: at sleep, every session file is gone before sleep completes, so through any sleep bc-limit's normal rules — not a session's suppression — own the battery. In L3's specific shape (at floor, on AC, session-parked), sleep ends the session at WillSleep; on the next tick after wake bc-limit simply begins L4 early (rest shortened, deviation logged) — the failure direction is *charging sooner*, never *suppressed longer*.
- **Overnight splits park on AC, not on battery.** The two-day plan (§6) splits the run at an L2 checkpoint with the Mac plugged in: the segment parks (no drain, no charge), and sleep in that state is ordinary. Nobody leaves a calibration sitting at a low % on battery overnight — the plan never proposes it and the run's drain watch (L3 logic) argues against it everywhere.

### 5.5 Power posture during legs

- **L2 segments assert an anti-sleep posture** using BC's existing power-profile machinery (the dispatch sleep-mode actions and their pmset exit-code verification, hardened in the 2026-11-13 consolidation): system sleep off while the segment runs, display sleep allowed. Standby/hibernate settings are **not** touched. The prior profile is recorded in the run file and restored on *every* segment exit — completion, abort, cancel, sleep (the WillSleep path restores before sleeping), and supervisor-detected staleness.
- **Lid open during L2.** Clamshell sleep would end the segment; the run's status line says so while L2 is active. This is a user-discipline item the supervisor cannot enforce, so the design makes the cost of forgetting zero: closing the lid is just a checkpoint (§5.4), never a failure.
- **L1/L3/L4 assert nothing.** Charging and resting legs take the machine's normal power behaviour, including sleep (L4 explicitly, §5.3).
- **Restoration is verified, not assumed** (§7, rule 13): within 2 ticks of any segment/run exit, the supervisor re-reads the active profile; a mismatch is corrected once and logged; the health check carries a "calibration posture active" line for as long as any posture is asserted, so a stuck posture is visible in the morning, not silent.

### 5.6 Interactions summary

| Component | Delta |
|---|---|
| bc-limit | v1.3: `MODE=calibrate` session validation with run-file cross-check (§5.2). Nothing else. Non-session behaviour and routine session behaviour unchanged. |
| bc-watchdog | New run-supervisor layer beside the session monitor: legs, checkpoints, segment issue/resume, temp-config and posture ownership, heartbeat, run-level aborts. Reuses the monitor's APG/flip/gauge machinery and `discharge.log`-grade logging discipline in `calibration.log`. |
| dispatch.sh | The existing **Calibrate** action (`calibration_start` / `calibration_stop` routing, today an honest stub) becomes the run toggle: no run → preflight + start (with the floor and day plan in the confirmation dialog); run active → cancel to the safe state. `cal_stop` stays the same cancel. |
| display_state.sh / plugin | One status line while a run exists (`Calibrating — discharging, 34% (floor 10%)`, `Calibrating — paused at 41%`, `Calibrating — recharging`), reusing the existing ⚡ calibration mode/icon from the wrapper state machine. |
| powerwatch | WillSleep hook gains one line of work: when a run is in L2, write the run checkpoint (it already ends the session). |
| config | Temporary 100/99 during L1–L4 under `EXPECT_CONFIG` (§7, rule 14); restored at L5/abort. |
| health check / morning report | Two lines: "calibration run active/stale" and "calibration posture active". A completed run is summarised in the next morning report (§8). |

---

## 6. Supervision model and day plans

**Who must be present, per leg:**

| Leg | User presence | Notes |
|---|---|---|
| L0 | **Present** — confirms plan + floor | The run's only irreversible-looking decision is made here, by the user. |
| L1 + L1r | Unattended OK | Ordinary charging on AC; the run watches termination. |
| L2 above 30 % | Around (normal use is the drain) | The user *is* the load; the leg expects the Mac in use or awake-idle nearby. |
| L2 below 30 % | **Present/attentive** | Notifications at 30 and at floor; sleep = checkpoint, so inattention degrades to a pause, never a hazard. |
| L3 | **Present at entry** | The plug-in moment is time-sensitive (§5.3). |
| L4 | Unattended OK, incl. overnight | §5.3's asymmetry. |
| L5 | Reviews the report | Minutes. |

**Elapsed-time estimates (this pack, measured drain/charge behaviour):**
- L1: from 86 % ≈ 45–75 min charging + 60 min rest.
- L2: 100 → 10 % is ≈ 4,700 mAh of real drain. Under active use (the 15–25 W this machine draws working) ≈ **4–6 h**; awake-idle ≈ 9–13 h. Plan on active use.
- L3: 30 min (+ plug-in latency).
- L4: 10 → 100 % ≈ 2.5–3.5 h (CC/CV taper on an aged pack), + 30 min rest.

**One-day plan (recommended, §11 Q2):** start L0 mid-morning → L1/L1r over lunch → unplug early afternoon, L2 across the afternoon's normal work → floor around early evening → L3 → L4 into the evening/night → L5 whenever the user next sits down (the run waits at full, safely, under the temporary limit until close-out — or the supervisor auto-restores at the L4 bound; see §7, rule 8). Total elapsed ≈ 10–14 h, of which the user is *doing* something for perhaps 20 minutes.

**Two-day plan (variant):** day 1 = L0–L2 down to a ≥ 40 % checkpoint, plug in (park) overnight; day 2 = resume L2 to the floor, L3, L4, L5. The run bound (72 h) covers a long weekend; the park state is the only overnight state the plan allows below full.

---

## 7. Safety rules (numbered, testable)

Rules 1–5 and 9–12 restate the discharge rules as they apply here; rules 6–8 and 13–14 are calibration's own (6 is the stated relaxation; 7, 13, 14 tighten beyond discharge). Each carries its test clause.

1. **Single writer.** Only bc-limit ever writes BCLM (or any SMC key). The run supervisor, dispatch, and the plugin never write SMC; the supervisor's only levers are the session file, the run file, BC config, and the existing power-profile actions. *Test:* code audit + runtime — every BCLM write in the daemon log during a shadow run originates from bc-limit.
2. **Two-signal endpoints.** Neither endpoint is declared on % alone. Full = % = 100 on 2 ticks **and** observed charge termination. Floor = % ≤ FLOOR on 2 ticks **and** pack voltage ≤ 10.9 V. A claimed endpoint failing its second signal does not advance the run; the discrepancy is logged as a finding. *Test:* stubs claiming 100 % while still charging must not complete L1; stubs claiming 9 % at 11.8 V must not complete L2.
3. **Gauge symmetry.** A |ΔPCT| ≥ 5 % single tick is ignored for every run decision (progress, checkpoints, endpoints), exactly as in discharge. *Test:* injected ±7 % ticks at 99 %, 31 %, and 11 % produce no leg transition.
4. **APG is absolute.** No leg starts while `.apg_paused` exists. During L2, APG suspends segments and aborts them after 15 continuous minutes (with the 2026-11-13 completion-before-suspend ordering: a segment that has reached its floor completes rather than suspends). During L1/L4, an APG pause persisting 15 min aborts the run — a pack that cannot charge calmly is not calibrated through. *Test:* flag touched in each leg in sandbox; verify suspend/abort timings per leg.
5. **AC-flip abort + cooldown, no auto-retry.** The discharge flip rule applies inside every session segment; a flip abort closes the segment, imposes the cooldown, and parks the run at a checkpoint. The run never re-issues a segment on its own — resume is the user's. *Test:* scripted flip sequence during a sandbox segment; verify one abort, one log, refused auto-resume, manual resume after cooldown.
6. **Floors — the one relaxation, fenced.** Routine sessions keep `DISCHARGE_FLOOR_ABS` = 20, untouched. Inside a run only: `CALIBRATION_FLOOR` = **10** (the leg's target; set at L0, not user-editable below this constant's floor), `CALIBRATION_FLOOR_ABS` = **8** (a confirmed reading at/below 8 aborts the leg instantly, whatever the target — this is the emergency bound, not a target). Rationale, stated once and plainly: the gauge learns the low endpoint from the low-voltage knee region; stopping at 20 % leaves the bottom fifth unobserved and the low-end model wrong (the region where sudden drops live). Going to ~5 % or to the system's own shutdown buys marginal extra learning at real cost — an uncontrolled power cut risks data, and deep-knee cycling is the most stressful part of the discharge curve for an aged cell. 10 % sits at the knee with margin: on this pack it still leaves ≈ 470 mAh ≈ an hour of active use, and roughly 8 h of (never-planned-on) sleep drain, of headroom. The floor exists only inside a run: dispatch validates `MODE=calibrate` targets solely against an active run file, and bc-limit v1.3 ignores any calibrate session that fails §5.2's cross-check. *Test:* a calibrate session file without a run file is ignored by bc-limit and deleted-and-logged by the monitor; a run cannot be created with FLOOR < 10 by any path (dialog, config edit, forged file); a stub dropping confirmed PCT to 8 mid-leg aborts that tick and the safe state verifies.
7. **Sleep rules.** Segments end before sleep (WillSleep); the run survives only as a checkpoint; L2 resume requires the post-wake window + APG clear + `PCT ≥ FLOOR + 15` + explicit user confirmation; a wake reading ≤ FLOOR aborts the run as failed. L4 (and only L4) may cross sleep in progress. The combination % below lower + charger + sleep + suppressed charge is unreachable by construction (§5.4). *Test:* sleep drills at L2-60 %, L2-28 %, and L3 in the supervised run; verify segment file gone before sleep completes, checkpoint contents correct, resume gating on wake (including a forged low wake reading refusing resume).
8. **Bounded everything.** Legs: L1 ≤ 6 h, L1r fixed 60 min, each L2 segment ≤ 240 min (inherited), L2 total ≤ 24 h of wall time across segments, L3 ≤ 2 h, L4 ≤ 8 h, run ≤ 72 h from `STARTED`. Any bound hit = abort (or, for L4-complete-but-not-closed, auto-close-out) to the safe state. *Test:* forged timestamps in sandbox push each leg past its bound; each aborts with its reason and the safe state verifies (config 86/85, no session, no posture).
9. **User cancel always wins.** Cancel (menu, any leg, any moment) = immediate safe state, no confirmation tick, no cooldown, no questions. A cancelled run is a closed run; starting again is a new L0. *Test:* cancel in every leg in sandbox lands in the verified safe state that tick.
10. **One run, one actor.** At most one run exists; the supervisor is its only owner; a run and a routine session never coexist (a routine session active at L0 blocks the run; a run active blocks routine session starts — the discharge monitor refuses with reason `calibration`). Sailing (disabled today) yields to a run as it yields to a session. *Test:* start attempts in both directions during a sandbox run resolve to exactly one owner with the refusal logged.
11. **Fail-safe on bad data and dead components.** Unreadable battery data on 2 consecutive ticks aborts the current leg to the safe state. A corrupt run file is treated as *no run* by every reader and deleted-and-logged by the supervisor. A dead supervisor is bounded three ways: sessions go stale on their own bounds (§3.2), the run heartbeat goes stale for the health check within 10 min, and — worst case, stated honestly — if the run died while the temporary 100/99 config was in force, the Mac simply charges to full and holds there: a safe, visible, recoverable state that the health-check line "calibration run stale" surfaces the same morning. *Test:* kill the supervisor mid-L1 and mid-L2 in sandbox; verify each bound fires and no state suppresses charging beyond its design bound.
12. **No silent state.** Every leg transition, checkpoint, endpoint claim **with its two signals' raw values**, segment issue/resume/end, config and posture change, and abort is written to `calibration.log` with the tick's raw readings. If it isn't in the log, it didn't happen — and the run scores as failed in §9. *Test:* log audit is part of the T1 suite: a scripted full walk's log must reconstruct the entire run without gaps.
13. **Power posture is restored and verified.** The anti-sleep posture is asserted only inside L2 segments, recorded in the run file, restored on every exit path (complete/abort/cancel/sleep/stale), and the restoration is verified by re-reading the active profile within 2 ticks; a stuck posture is corrected once, logged, and visible via the health-check line while it lasts. Standby/hibernate settings are never touched by any leg. *Test:* exit the segment by each path in sandbox (including killing the supervisor mid-segment); the profile must equal the pre-run profile afterwards in every case.
14. **Config integrity.** While a run is active, BC config must equal the run's `EXPECT_CONFIG`. A config change the run did not make ends the run as *superseded*: if the current config is still the run's temporary value, the safe state restores 86/85; if the user has set their own new limit, the run ends and **leaves the user's config alone** — the safe state never stomps a deliberate user change. The temporary 100/99 is itself a safe resting state (§7 rule 11), so a supersede mid-charge-leg is a paperwork event, not an incident. *Test:* edit config mid-run both ways in sandbox; verify the run ends, the user's value survives where present, and 86/85 is restored where the temp value was untouched.

---

## 8. Logging and the run report

`~/.battery-commander/calibration.log` (added to cleanup_logs rotation). On close-out (or abort), the supervisor writes a summary block into the log and the next morning report carries a one-line version:

```
CALIBRATION RUN 1763050000 — completed | aborted(reason)
  baseline:  MaxCapacity 5266 mAh, Health 76.3%, Cycle 568
  endpoints: full ✓ (100%, terminated 14:02) · floor ✓ (10%, 10.6 V, 18:41)
  legs:      L1 1.9 h · L2 5.2 h (2 segments, 1 sleep checkpoint) · L3 0.6 h · L4 3.1 h
  after:     MaxCapacity — re-read next morning (the honest comparison point), Cycle 569
```

The before/after capacity comparison is deliberately deferred to the next morning's reading: the gauge digests a calibration over the following rest, and a MaxCapacity read in the first minutes after L4 would be noise dressed as a result. The verification design's calibrate-day episode scoring consumes this report.

---

## 9. Test plan

No test in this section is approved by this document. T1–T2 are build-time verification; T3 is the calibration itself and needs its named day and its own approval.

### T1 — Sandbox and stub tests (build time, no real battery)

Following the existing `test_bc_watchdog.sh` / `test_discharge.sh` pattern: sandbox state dir, scripted bc-status stubs, fake tick driver, forged files and timestamps. Must pass: every *Test:* clause in §7; the full leg walk (L0→L5) on stubs; bc-limit v1.3's validation matrix (routine modes unaffected; calibrate accepted only with a fresh, matching run file; stale/forged/run-less calibrate files ignored); the sleep-checkpoint-resume cycle; posture restore on every exit path including supervisor-kill; `bash -n` clean; and the discharge suite (16/16 at the monitor-fix baseline) still green, unchanged in behaviour for routine sessions.

### T2 — Shadow dry-run (build time, real machine, zero effect)

The built supervisor ships first in shadow: it walks the legs against live readings and logs what it *would* do, but writes no run file bc-limit would honour, applies no temporary config, and asserts no posture. Two deliberate degradations make the dry run honest: its floor is the routine 20 % (the state machine walks to *a* low endpoint and back without ever taking the real pack below routine bounds), and its "segments" are issued against the shadow state file only. Run it across at least one full natural day including a sleep. **Pass criteria:** leg transitions fire at the right readings; the shadow run survives the night as a checkpoint and offers resume correctly; zero interference with the running system (no session file, no config change, no posture change — verified by the same reads that would catch a real one).

### T3 — Named-day supervised live run (outline — separate approval, user present at checkpoints, daytime start)

1. Preconditions: T2 report reviewed; health check green; the day plan (§6) chosen; nothing else in the project needs the machine that day.
2. The run itself, per §5–§6, with the user present at L0, L2 start, the 30 % checkpoint, floor arrival + plug-in, and L5.
3. Sleep drills are **not** forced inside T3 — if a natural sleep checkpoint occurs during L2 it is scored as evidence; the §7 rule 7 drills are covered by T1 stubs and by any natural occurrence, per the project's natural-proofs doctrine.
4. Scoring, from `calibration.log` against §7: both endpoints two-signal confirmed; no decision on a ≥ 5 % tick; no BCLM write by any component but bc-limit; every exit landed in the verified safe state; posture and config restored. The next morning's MaxCapacity/Health reading is recorded as the run's outcome data — reported, not judged as pass/fail (honesty may move it either way, §1.2).
5. Any rule failure stops the phase; fixes return to design before any second attempt. There is no "retry tomorrow" by default — a failed calibration is itself the finding to understand first.

---

## 10. Build outline (for the later build approval — not part of this design's approval)

- **C1:** run supervisor in bc-watchdog (legs, checkpoints, segment issue/resume, heartbeat, run-level aborts) + shadow flag; T1 suite green. No live effect.
- **C2:** bc-limit v1.3 (the §5.2 validation delta only) — dry-run matrix extended with the calibrate cases; deployed with the established backup/verify pattern; routine behaviour proven unchanged by the existing suites.
- **C3:** dispatch Calibrate toggle + preflight dialog (floor + day plan stated), display_state status line, powerwatch checkpoint line, posture assert/restore/verify, health-check lines, cleanup_logs rotation gains `calibration.log`.
- **C4:** shadow dry-run (T2) → report → T3 named-day supervised run under separate approval → phase review.

Dependencies: discharge phase complete and Phase C certified (both done in substance 2026-11-13; formal certification verdict lands with the 2026-11-14 morning check). C1's sandbox work has no live dependency; C2 reuses the discharge build's deploy discipline.

---

## 11. Open questions for Yousef (preference-level only)

1. **The floor.** **10 %** (this design's recommendation: the knee is observed, ≈ 470 mAh of margin remains, stress is one-off and modest) — or **20 %** (routine floor; safest, but the gauge's bottom fifth stays unlearned and the run is a long discharge, not a calibration) — or **5 %** (deepest learning; the design advises against: data risk at the power-cut edge and the most stressful region of the curve, for little extra signal). The constant is set once, here, and is not a runtime choice.
2. **Day shape and supervision.** **One long day** with checkpoints (recommended: L2 rides a normal workday's load, L4 runs into the evening; you are needed for ~20 minutes total) — or the **two-day split** with an overnight AC park? And within either: is "present below 30 %" (§6) the right supervision line for the first run, or do you want to be present for the whole descent? (The design's protections make inattention degrade to a pause either way; this is about your comfort, not the pack's safety.)
3. **After the run.** Leave the pack at 100 % to settle back to the 86 % band by ordinary use over the following days (recommended: no extra cycling; the limit reasserts itself naturally as the % drifts down — and a post-calibration gauge deserves a quiet day, not another procedure) — or immediately run a corrective discharge session back to 86 % so the tool's normal picture is restored the same evening?

---

*End of design. Next step if approved: build per §10 (C1 first), under a separate build approval. Nothing in this document authorizes code, an install, a config change, or a battery cycle.*
