# Natural-Use Verification System — Design

Battery Commander (BC) · Design only — no code in this document
Date: 2026-11-12 · Status: DRAFT for Yousef's review
Doctrine (01-PROJECT.md §5): **"Natural proofs only, never forced."**

---

## 0. Purpose

Yousef's direction (2026-11-12): instead of formal test appointments
(discharge day, calibrate day, a scheduled Phase C cycle), BC should
**verify itself through normal usage**. The machine is used normally;
the system continuously captures what actually happens, groups it into
*episodes*, and judges each episode against explicit pass criteria.
Verification becomes a property of everyday use, not an event.

This replaces most — not all — formal testing:

- The Phase C full-cycle test becomes: *the first natural full cycle
  after the daemon swap is the evidence* (§7.1 defines exactly what
  that cycle must show).
- The final re-test becomes: *a clean rolling 7-day verification
  record* plus a short list of things that still need human eyes (§7.2).
- The delivery report gains a *field-confidence* summary measured on
  the real machine, not a lab bench (§7.3).

Nothing in this system ever *causes* a charge, discharge, wake, or
sleep. It only observes. Every input already exists as telemetry
(§1); the new work is episode extraction, judging, storage, and one
menu surface.

### Verdict vocabulary (used everywhere below)

| Verdict | Meaning |
|---|---|
| `PASS` | Episode met every criterion on clean data. |
| `PASS-NOTES` | Passed, with a recorded anomaly that is known/expected (e.g. legacy-daemon behaviour during the transition). |
| `UNVERIFIED` | Episode happened but its data cannot certify the criterion (gauge-contaminated, interrupted, fields missing). Never counted as a pass. |
| `FAIL` | Episode violated a criterion on clean data. |
| `OPEN` | Episode started, not yet closed. |
| `INTERRUPTED` | Episode ended by an outside event (shutdown, AC detach mid-charge, user wake). Closed without judgement on the interrupted axis. |

A pass is only ever claimed from closed episodes with sufficient
data. Absence of episodes renders as `—` (unknown), never as ✓ (§8).

### Enforcer attribution (honesty rule #1)

Every episode carries `enforcer`: `bc-limit` (the BC daemon),
`legacy` (the old battopt daemon, i.e. everything before Phase C),
or `none`. **Verdicts about BC count only `enforcer=bc-limit`
episodes.** Before Phase C the system still runs and labels
everything `legacy` — useful as a baseline, never presented as
BC verification. This rule is what stops the menu from claiming
"BC verified" while the old daemon is still the one enforcing.

---

## 1. Inputs — existing telemetry only

| Source | What it already provides | Cadence |
|---|---|---|
| `bc-watchdog.sh` heartbeat + layer logs | Per-tick `PCT, BCLM, cfg=UPPER/LOWER, NCR, EXT (ExternalConnected), IsChg, mode, APG, backend`; overshoot episodes (`.overshoot_state`, one log line per episode); gauge-jump deferral (prev-PCT tracking, ≥5 %/tick); L8 daemon-loaded check | 60 s |
| `bc-status` | Capacity %, BCLM, Backend, IsCharging, ExternalConnected, temps, Health, CycleCount, mAh (Current/Max) | on demand / per watchdog tick |
| bc-limit daemon log (`~/.battery-commander/bc-limit-daemon.log`, `limit.log`) | Every enforce decision and every BCLM write with read-back result (post-Phase C); dry-run `WOULD WRITE` lines pre-Phase C | per daemon run (60 s) |
| `morning_report.sh` | Per-night sleep analysis: sleep/wake times + %, total drain, %/h, DarkWake count + reasons, "slept normally", "BC involved", gauge-jump note; writes `reports/morning-YYYYMMDD.txt` + `.overnight_summary` | 08:00 agent |
| `pmset -g log` | Sleep/Wake/DarkWake history with charge % (mined by the morning report) | system |
| Config + state files | `~/.battery-commander/config` (86/85), `.apg_paused`, `.sleep_mode`, `.overshoot_state`, `.notify/hold_reached_session` | — |

Two known data-quality facts the design must respect:

1. **Two % roundings exist** (audit item M8): the watchdog rounds,
   dispatch floors. Episode *detection* uses the watchdog's own PCT
   series (self-consistent within an episode); episode *energy*
   (mAh deltas) uses ioreg CurrentCapacity where snapshots exist.
   Verdict thresholds below are stated against the watchdog series.
2. **The % gauge jumps** (+7…+12 % in one tick, proven 2026-10-30
   and 2026-11-11). Any criterion that a jump could fake is judged
   on uncontaminated ticks only (§2g, §3).

---

## 2. Episode model

An **episode** is a closed interval of one kind of behaviour, with a
start trigger, an end trigger, and a fixed capture set. Episodes are
detected from the watchdog's 60 s tick stream (hold/charge/discharge/
cycle/limit-change/gauge) or from the morning report (sleep) — one
writer per type, so there are no write races (§4).

Common capture fields (all types): `id` (`<type>-<start_epoch>`),
`type`, `start_ts`, `end_ts`, `enforcer`, `upper`, `lower` (config
at start), `start_pct`, `end_pct`, `gauge_events` (count),
`apg_paused_ticks`, `verdict` (filled at close), `notes[]`.

### (a) HOLD episode

- **Start:** mode becomes `hold` — BCLM=10, IsCharging=No, on AC,
  PCT ≥ upper−1.
- **End:** any of — AC detached; PCT falls to ≤ lower (hold can no
  longer be distinguished from sailing/resume); config limit
  changes; Mac sleeps (the sleep episode takes over; the hold is
  closed as `INTERRUPTED` with reason `sleep`, and a new hold opens
  on wake if conditions still hold); shutdown.
- **Captured extra:** `duration_s`, `min_pct`, `max_pct`,
  `charging_ticks` (ticks with IsCharging=Yes while BCLM=10 —
  must be 0), `bclm_always_10` (bool).
- Micro-holds < 10 min are recorded but not judged (verdict
  `UNVERIFIED`, note `micro`) — brief holds happen around plug
  events and prove nothing.

### (b) CHARGE episode

- **Start:** on AC, PCT ≤ lower, and charging observed
  (IsCharging=Yes or BCLM=100 with PCT rising across 2 ticks).
  Also opens if AC is attached while PCT ≤ lower and charging
  begins within 5 min.
- **End:** hold begins (→ closes as complete, and may pair into a
  cycle, §2d); or AC detached (→ `INTERRUPTED`); or PCT reaches
  100 (charge-to-full path, limit 100/99 or Disable Limits —
  judged against the *effective* upper in the config at start).
- **Captured extra:** `overshoot_max` (max PCT on **uncontaminated**
  ticks), `overshoot_raw_max` (including contaminated ticks, for
  the record), `duration_s`, `delta_mah` (CurrentCapacity start→end
  where available), `ext_flip` (bool — ExternalConnected went
  Yes→No while AC physically attached), `resume_write_seen` (bool —
  bc-limit daemon log shows the BCLM 10→100 write that started this
  charge, post-Phase C), `hold_write_seen` (the closing 100→10).

### (c) DISCHARGE episode

- **Start:** AC detached (EXT=No) with PCT ≥ lower−2 (a discharge
  that starts already deep is still an episode; start % is what it
  is), or PCT begins falling on battery from any level.
- **End:** AC attached; or Mac sleeps (sleep episode takes over;
  discharge closes `INTERRUPTED`/`sleep` — the overnight drain is
  judged by the sleep episode, not here); or shutdown.
- **Captured extra:** `end_pct`, `rate_pct_h` (from uncontaminated
  endpoints; if a gauge event occurs mid-episode, `rate_estimated:
  true`), `crossed_lower` (bool), `min_pct`,
  `below_lower_at_end` (bool — the precondition for a cycle).

### (d) FULL CYCLE episode

- **Definition:** a discharge episode with `end_pct ≤ lower−2`
  followed by the next charge episode that ends in hold. The cycle
  is a *composite* record referencing both child episode ids; it is
  emitted when the charge half closes.
- **Captured extra:** `discharge_id`, `charge_id`, `depth_pct`
  (discharge start − discharge end), `total_duration_s`,
  `overshoot_max` (from the charge half), `ext_flip` (either half).
- This is the Phase C evidence unit (§7.1) and the rolling
  "Last full cycle" menu fact.

### (e) SLEEP episode (one per night)

- **Source:** `morning_report.sh`, which already computes
  everything. v1 adds one machine-readable sidecar,
  `.sleep_episode` (KEY=value, same convention as bc-status),
  written next to `.overnight_summary`; the verifier consumes the
  sidecar, not the prose report.
- **Fields:** `sleep_start_ts/pct`, `wake_ts/pct`, `drain_pct`,
  `rate_pct_h`, `darkwakes`, `wake_reasons[]`, `slept_normally`
  (bool), `bc_involved` (bool), `on_ac` (bool), `external_notes[]`
  (e.g. `blueavengers-cadence` when the 15-min RTC/Maintenance
  pattern is present — an *external* cause, recorded, never a BC
  fault).
- **Two-axis verdict** (important): `verdict_bc` (did BC behave —
  almost always "not involved") and `verdict_sleep` (sleep quality
  vs the known baseline). A bad drain night fails `verdict_sleep`,
  **not** BC. The axes are never merged into one grade.

### (f) LIMIT-CHANGE episode

- **Start:** the config's `upper/lower` tuple changes between two
  watchdog ticks (the watchdog heartbeat already logs `cfg=`).
  Covers menu actions (Custom Limit, presets, Remove Hold,
  Disable Limits, Charge to 100 %) — all of them end in
  `bc_apply_limit`'s atomic config write.
- **End:** enforcement observed consistent with the new limits
  (mode/BCLM appropriate to current PCT vs the new upper/lower,
  cross-checked against the bc-limit daemon's next decision line
  post-Phase C) → close with `latency_s`; or 10 min elapse → close
  as timeout.
- **Captured extra:** `old_limits`, `new_limits`, `latency_s`,
  `source` (best-effort: the dispatch action, from actions.log
  timestamp correlation — informational only).
- **Pre-Phase C expectation:** these episodes will *time out*,
  because the legacy daemon reads the old state dir's config.
  That is the system telling the truth about the transition period:
  verdict `FAIL` with note `awaiting-phase-c`, enforcer `legacy`,
  and **notifications suppressed** (§6) — the state file shows them
  as pending-Phase C evidence, not as alarms.

### (g) GAUGE-JUMP event

- **Trigger:** |ΔPCT| ≥ 5 % between consecutive watchdog ticks
  (the same threshold bc-limit's deferral and the watchdog's
  deferral already use), with no corresponding energy flow
  (Amperage ≈ 0 / IsCharging unchanged / ΔmAh inconsistent).
- **Record:** a lightweight event line (not a full episode):
  `ts, from_pct, to_pct, delta, context` (awake/asleep-wake/
  on-AC/on-battery).
- **Effect on other episodes:** any open episode gets
  `gauge_events += 1` and is stamped **gauge-contaminated** for
  the affected criterion (§3). The event itself is never pass/fail.
- **Health signal:** > 3 events/day feeds a "gauge unreliable"
  note into the 7-day summary (§7.3) — evidence for the delivery
  report, not an alarm.

---

## 3. Pass criteria (explicit, per type)

Thresholds use the standing project constants: overshoot guard =
**upper + 2** (guardian LAYER2 / watchdog `_overshoot`); gauge
threshold = **5 %/tick**; sleep baseline = **1.2–1.7 %/h**
(2026-10-27/28 measurements, reconfirmed S1 2026-11-11: 1.4 %/h).

| Type | PASS requires (all, on uncontaminated data) | FAIL examples | UNVERIFIED when |
|---|---|---|---|
| HOLD | duration ≥ 10 min; `charging_ticks` = 0; BCLM = 10 on every tick; `max_pct` ≤ upper+2 | any charging tick during hold; BCLM flips to 100 mid-hold without a limit change | duration < 10 min; gauge event at the boundary ticks so `max_pct` is unknowable |
| CHARGE | ends in hold; `overshoot_max` ≤ upper+2; `ext_flip` = false; duration plausible (see below) | `overshoot_max` > upper+2; charge sails past upper+5 without entering hold | charge completes in < 3 min with ΔmAh ≈ 0 (gauge-suspect rise); overshoot peak exists only on contaminated ticks |
| DISCHARGE | informational by default — PASS = data complete (start/end/rate captured, no sensor gaps > 5 ticks) | — (a discharge is user behaviour; BC cannot fail it) | sensor gaps; rate only estimable due to gauge events → still PASS but `rate_estimated` noted; deep discharge < 20 % is a *note*, not a fail |
| FULL CYCLE | discharge half ends ≤ lower−2; charge half PASS; no FAIL in either half; enforcer constant across both halves | charge half FAILs; enforcer changed mid-cycle (e.g. swap day) → cycle is split at the boundary, neither half counts across it | charge half UNVERIFIED (cycle then certifies hold+completion only, **not** overshoot) |
| SLEEP (`verdict_sleep`) | slept normally (standby + maintenance DarkWakes only) **and** rate ≤ 1.7 %/h | rate > 2.5 %/h with no external note explaining it | user wake during the night (INTERRUPTED); rate 1.7–2.5 %/h → PASS-NOTES "elevated"; on-AC nights judged on hold-during-sleep instead: PASS if PCT stays ≥ upper−1 and no charging above the limit |
| SLEEP (`verdict_bc`) | `bc_involved` = no (no BC-caused wake/discharge — the morning report already determines this) | any wake or discharge attributable to a BC component | report data incomplete (pmset log rotated mid-night) |
| LIMIT-CHANGE | enforcement consistent with new limits within 10 min; latency recorded | timeout with no daemon decision line matching the new config (post-Phase C) | PCT sits strictly between new lower and upper in a state where both hold and resume are legitimate → judged on the daemon's next decision line; if none within 10 min → FAIL (post-Phase C) |
| GAUGE event | — (annotation only) | — | — |

Notes on specific criteria:

- **Charge overshoot** deliberately mirrors the guardian's +2
  guard: BC v1 never force-discharges, so an overshoot beyond +2
  means the enforcer stopped late — a real FAIL of the enforcer,
  not of the battery.
- **ExternalConnected flip:** in the legacy stack a flip
  (Yes→No 11–50 s after discharge start, NCR=8) aborted discharges
  and drove the known loop. BC has no forced discharge, so a flip
  during a *charge* episode is the watch item: pre-Phase C it is
  recorded as PASS-NOTES (known legacy behaviour); **post-Phase C,
  a flip that aborts or interrupts a charge is a FAIL**, and any
  flip at all is recorded in `notes[]` for the delivery report.
- **APG pauses:** ticks with `.apg_paused` active are counted
  (`apg_paused_ticks`) but never fail an episode — thermal
  protection is correct behaviour.
- **Sleep during hold/charge:** sleep closes the episode as
  INTERRUPTED/`sleep`; on wake a fresh episode opens. BCLM persists
  across sleep, so a hold that spans a night is *two* hold episodes
  plus a sleep episode — the 7-day rollup (§5) reports total hold
  time, so nothing is lost by the split.

> **Amendment — 2026-11-14 (approved by Yousef by delegation: "as
> long as it is technically correct and serves my purpose, adopt
> your solution").** The HOLD criterion above is refined: a hold
> episode whose `max_pct` exceeds upper+2 **fails on that ground
> only when the episode carries evidence of actual energy flow** —
> a charging tick (`charging_ticks` > 0) or any tick with
> BCLM ≠ 10 (both already FAIL the episode independently). A
> `max_pct` exceedance with zero charging evidence is fuel-gauge
> estimate drift at zero current, not an enforcement failure: the
> episode **PASSes**, with the drift recorded in `notes[]` as
> `gauge-drift` (magnitude above upper, and the timestamp at which
> the clean maximum was first reached) — never silently dropped.
> Rationale: the original rider was written for charge-overshoot;
> the 2026-11-13 bc-limit hold (17:34:54 → 22:29:55) sat at
> BCLM = 10 with zero charging ticks on all 294 ticks while the
> gauge estimate stepped +3 to 89 at zero current (19:13:23) — a
> flawless hold convicted by an estimate. Every real overshoot
> (charging present) still FAILs exactly as before. Implemented in
> `bc-episode-tracker.py` `judge_hold` (sandbox v1, 2026-11-14);
> `bc-verify.py` is unchanged.

---

## 4. Storage

All under the existing state dir. Local only — nothing in this
system transmits anything anywhere (and the File API cannot read
the state dir at all; inspection happens on the Mac itself).

```
~/.battery-commander/
  verification/
    episodes.jsonl            ← append-only, one JSON object per closed episode/event
    episodes-YYYYMMDD-HHMMSS.jsonl   ← rotated archives (max 10)
    verdicts.jsonl            ← one line per bc-verify run (daily + on-demand)
  .verification_state         ← KEY=value verdict state (plugin/app render source)
  .verification_summary       ← one-line summary (mirrors .overnight_summary pattern)
  .sleep_episode              ← morning report sidecar (input, §2e)
  .episode_open               ← watchdog's open-episode tracker state
  reports/verification-YYYYMMDD.txt  ← human-readable daily report (with the other reports)
```

**Format:** JSON Lines — one self-contained object per line, keys
as in §2. Example (charge episode):

```json
{"id":"charge-1762825200","type":"charge","enforcer":"bc-limit","start_ts":"2026-11-14T09:12:03+02:00","end_ts":"2026-11-14T10:03:41+02:00","upper":86,"lower":85,"start_pct":79,"end_pct":86,"overshoot_max":87,"overshoot_raw_max":87,"delta_mah":366,"duration_s":3098,"ext_flip":false,"resume_write_seen":true,"hold_write_seen":true,"gauge_events":0,"apg_paused_ticks":0,"verdict":"PASS","notes":[]}
```

**Rotation (consistent with cleanup_logs.sh conventions):**
`cleanup_logs.sh` already rotates every log at **100 KB** (archive
a copy, keep the tail). The episode log follows the same rule with
one adaptation: episodes are records, not a tail-able log, so at
100 KB the file is *archived whole* to a dated name and a fresh
`episodes.jsonl` starts; archives are capped at **10 files
(~1 MB total)**, oldest deleted first by the same cleanup run.
`verdicts.jsonl` rotates identically. Estimated volume: a busy day
produces ~10–25 episode lines ≈ 3–8 KB — a 100 KB file holds
roughly 2–4 weeks; the 7-day and 30-day rollups (§5, §7.3) read
across archives transparently. The human daily report is a normal
report file under `reports/`, pruned by the existing report
housekeeping.

**Writes are append-only and atomic-ish:** the watchdog appends a
line only at episode *close* (single `echo >>`, line < 1 KB —
same pattern as its existing logging); the open-episode state is
rewritten per tick via the project's atomic tmp+mv pattern (as
`.overshoot_state` and the hold-session file already do).

---

## 5. The verifier — `bc-verify`

A reader/judge only. It never touches the SMC, config, or any
agent. It reads episodes + logs, scores windows, and writes the
state/summary/report files.

### Interface (design)

```
bc-verify [--range 24h|7d|30d] [--write-state] [--report] [--json]
          [--since-phase-c]
```

- Default run (daily): scores the **last 24 h** for the verdict
  lines and the **rolling 7 days** for the rollup fields; writes
  `.verification_state`, `.verification_summary`, appends one line
  to `verdicts.jsonl`; with `--report`, also writes
  `reports/verification-YYYYMMDD.txt`.
- `--since-phase-c`: scores from the swap timestamp (recorded in
  the state file at Phase C time) and evaluates the Phase C
  verification definition (§7.1) — used during the Phase C session
  and until it certifies.
- `--json`: machine-readable verdicts to stdout (for the future
  standalone app; the app reads the same state file otherwise).
- **Exit codes:** `0` no FAIL in range · `1` at least one FAIL ·
  `2` insufficient data (no closed episodes in range). Callers
  (menu, morning flow) treat `2` as "unknown", never as success.

### State file (`.verification_state`, KEY=value like bc-status)

```
LAST_RUN=2026-11-14 08:00:12
ENFORCER=bc-limit
HOLDS_24H=3 HOLDS_PASS=3
LAST_CYCLE=2026-11-14 LAST_CYCLE_VERDICT=PASS
CYCLES_7D=2 CYCLES_PASS_7D=2
OVERSHOOT_MAX_7D=87 (limit 86, +1)
SLEEP_NIGHTS_7D=6 SLEEP_MEDIAN_PCT_H=1.3 SLEEP_BC_INVOLVED=0
LIMIT_CHANGES_7D=4 LIMIT_MAX_LATENCY_S=95
GAUGE_EVENTS_7D=2
FAILS_24H=0 FAILS_7D=1
PHASE_C=VERIFIED 2026-11-14        (or: PENDING / NOT_STARTED)
CONFIDENCE=FULL                     (FULL / PARTIAL / INSUFFICIENT — §8)
```

### Who runs it — hosting decision

**Host: the existing `com.batterycommander.morning-report` agent
(08:00 daily), as a step immediately after `morning_report.sh`.**
No new agent. Reasoning over the current 16 agents:

- The sleep episode — the only episode type that *closes* overnight
  — is final exactly when the morning report runs; a verdict
  computed before 08:00 would judge a night that hasn't ended.
- The user's morning surface already exists (08:00 notification +
  menu Overnight line); the verification summary rides the same
  moment instead of inventing a second one.
- Rejected hosts: `bc-watchdog` (60 s — verdicts would churn state
  1,440×/day and tempt time-based notification logic, the exact
  failure mode the notification policy abolished); `selfmaintenance`
  (300 s — same objection, and its job is health checks, not
  judgement); `pmsetcheck` (10:00 — settings-drift scope, and two
  hours after the user's morning moment); `log-cleanup` (03:00 —
  hygiene, and the night is still in progress).
- Episode *capture* still happens at watchdog cadence (it owns the
  tick stream and `.overshoot_state` today); only *scoring* is
  daily. On-demand scoring exists via a dispatch action
  `verify_now` (menu: "Re-run Verification") for the Phase C
  session and for Yousef's curiosity — it runs the same code path
  with `--write-state --report`.

If the Mac is asleep at 08:00, the agent fires at the next wake
(the morning report already behaves this way), so the verdict is
late, never lost — and `LAST_RUN` makes the lateness visible.

---

## 6. User surface

### Menu (SwiftBar plugin now; standalone app later reads the same files)

One header line, in the same style as the existing `Overnight:`
line, rendered from `.verification_summary`:

```
Verified: Hold ✓ · Cycle ✓ Nov 14 · Overshoot +1% (7d)
```

States it must render honestly:

```
Verified: Hold ✓ · Cycle — (none yet) · Overshoot — (7d)        ← no cycle observed yet
Verified: Hold ✓ · Cycle ⚠ Nov 13 (overshoot +4%) · Overshoot +4% (7d)
Verified: — (insufficient data — Mac was off)                    ← §8, never a fake ✓
Verified (legacy daemon): Hold ✓ · Cycle ✓ Nov 12 · …            ← pre-Phase C labelling
```

A **Verification** submenu section:

```
Verification
  Last full cycle: Nov 14 — PASS (depth 79→86, overshoot +1)
  Holds (24h): 3/3 PASS · Hold time (7d): 41.5 h
  Sleep (7d): 6 nights · median 1.3%/h · BC involved: never
  Limit changes (7d): 4 · slowest enforcement: 95 s
  Phase C: VERIFIED Nov 14  (or: PENDING — needs 1 natural cycle)
  Open Verification Report        → dispatch verification_report (opens today's report)
  Re-run Verification             → dispatch verify_now
```

### Notifications — existing policy, no new machinery

The notification policy (2026-11-11) is state-based: notify on
transitions/episodes, never on time-based cooldowns of a steady
condition. Verification plugs into it as follows:

- **FAIL episode → at most one notification, once per episode**,
  deduplicated by a marker file `.notify/verify_<episode_id>`
  (the hold-session pattern). Text carries the answer, like the
  morning summary does:
  `Verification: charge cycle Nov 13 overshot to 90% (limit 86%). See Verification Report.`
- **PASS episodes → silent.** Good news lives in the menu line and
  the 08:00 summary, never as interruptions.
- **Phase C certification → one notification, once ever**
  (marker `.notify/verify_phase_c_done`):
  `Battery Commander is verified independent: first full cycle passed (Nov 14).`
- **Suppressed:** FAILs with `enforcer=legacy` (the transition
  period would otherwise alarm daily about limit changes the old
  daemon cannot see — known, expected, and already communicated);
  UNVERIFIED/INTERRUPTED episodes; sleep `verdict_sleep` FAILs
  (they ride the existing 08:00 morning notification, which already
  reports the drain — no second alert for the same night).
- The existing daily-cap backstop in `notify_proactive_v2` still
  applies underneath, unchanged.

---

## 7. How this serves the project plan

### 7.1 Phase C — the natural cycle IS the test

Phase C's swap procedure itself is unchanged (phase-c-plan.md §4:
his sudo, daytime, unload legacy → place new binary → load BC
daemon). What changes is the *evidence standard* for calling it
done. **Phase C is VERIFIED when, after the swap timestamp,
`bc-verify --since-phase-c` finds all of the following, in order,
with `enforcer=bc-limit` throughout:**

1. **Hold proof:** one HOLD episode ≥ 30 min on AC, `verdict=PASS`
   (BCLM 10 throughout, zero charging ticks) — the BC daemon holds
   on its own.
2. **Discharge proof:** one DISCHARGE episode ending at
   ≤ lower−2 (≤ 83 %) through normal use — a real below-lower
   starting point, not a staged one.
3. **Charge proof:** the following CHARGE episode ends in hold,
   `overshoot_max` ≤ upper+2 on uncontaminated ticks,
   `ext_flip=false`, and the daemon log shows the matching write
   pair (`resume_write_seen` and `hold_write_seen`, each with
   read-back OK).
4. **Cycle formed:** the FULL CYCLE composite of (2)+(3) exists
   with verdict PASS. If the first natural cycle's charge half is
   gauge-contaminated at the peak (overshoot UNVERIFIED), Phase C
   waits for the next clean cycle — natural use produces them
   regularly; nothing is forced to hurry it.
5. **Continuity:** no watchdog L8 "daemon not loaded" lines and no
   enforcement gap between the swap and the cycle's close — the
   daemon was up the whole time.

On certification, `.verification_state` gains
`PHASE_C=VERIFIED <date>`, the menu shows it, and the one-time
notification (§6) fires. The rollback window in phase-c-plan.md §6
stays in force until this certification exists — i.e. **Phase C is
not "done" when the daemon loads; it is done when natural use has
proven it.** If no qualifying cycle has occurred within 7 days of
the swap, the state file says `PHASE_C=PENDING (no natural cycle
yet)` — a statement of fact, not a failure.

### 7.2 Final re-test — rolling 7 days replaces the checklist

The delivery re-test maps to the record as follows:

| Manual check (old plan) | Replaced by |
|---|---|
| Hold stays at the limit | 7-day holds: all PASS, total hold time |
| Charge stops at the limit | 7-day charge episodes + `OVERSHOOT_MAX_7D` |
| Limit changes take effect | Limit-change episodes + max latency (7d) |
| Sleep behaviour trend | 7 nights of sleep episodes, median %/h, BC-involved = never |
| Daemon stays loaded | L8 continuity inside episode windows |
| Gauge behaviour | Gauge-event count + contaminated-cycle handling |

Still done by human eyes (short, one session): menu rendering and
button click-through, About/branding, icon, one notification
actually appearing, login behaviour after logout/login. The system
verifies *behaviour*; it does not verify *pixels*.

### 7.3 Publish readiness — field-confidence summary

`bc-verify --range 30d --summary` (design) produces the paragraph
the delivery report quotes, computed from real episodes since
Phase C, e.g.:

> Field confidence (30 days, this machine): 9 full cycles, 9 PASS ·
> worst overshoot +1 % · 214 h in verified hold, 0 charging-during-
> hold events · 27 limit changes, slowest enforcement 95 s ·
> 29 sleep nights, median drain 1.3 %/h, BC involved in 0 wakes ·
> 6 gauge events, all episodes judged on uncontaminated ticks ·
> 1 FAIL (Nov 13, overshoot +4 %, legacy daemon — pre-Phase C).

Numbers like these — measured, dated, and including the failures —
are what "ready to publish" means for a tool other people will
trust with their batteries.

---

## 8. Failure honesty — what this cannot verify

- **Mac off / shut down:** nothing is captured. An episode open
  across a shutdown is closed `INTERRUPTED`/`power-off` at the
  next boot's first tick; the gap is a gap, labelled as such.
- **Asleep:** the watchdog does not tick in sleep (by design of
  macOS, not a BC gap). Sleep behaviour is judged only from the
  pmset log via the morning report — coarser (per-DarkWake %),
  and the sleep episode says so (`resolution: darkwake`).
- **Missing fields:** if bc-status or the daemon log is unreadable
  during an episode, the affected criterion is `UNVERIFIED`,
  never assumed. Three consecutive days of `UNVERIFIED` for the
  same criterion raise one notification (it means the *telemetry*
  is broken — a BC bug worth surfacing, once).
- **Confidence label:** the state file carries
  `CONFIDENCE=FULL|PARTIAL|INSUFFICIENT` — FULL only when the
  window contains at least one judged episode of each type the
  window claims to summarize; a quiet week with no charge episodes
  is `PARTIAL` ("no charge episodes this week — nothing to judge"),
  and the menu line shows `—` for the missing pieces.
- **The gauge itself:** the system detects jumps but cannot know
  the "true" % during one. It says `UNVERIFIED` and waits for
  clean data. It never smooths, invents, or back-fills a %.
- **Pre-Phase C data** is labelled `legacy` forever; archives are
  never re-attributed after the swap.
- **One machine:** all criteria are tuned to this MacBook Pro 9,1
  and its battery. The design does not claim the thresholds
  transfer to other models — that stays a publish-phase question
  (runtime probing doctrine), not something this system fakes.

---

## 9. Build order

**v1 — smallest useful (builds the Phase C evidence path first):**
1. Watchdog episode tracker: `.episode_open` state + close-out
   appends to `episodes.jsonl` for HOLD, CHARGE, DISCHARGE,
   CYCLE, GAUGE events (reusing the existing heartbeat fields,
   `.overshoot_state` precedent, and the ≥5 % deferral signal).
2. Morning report `.sleep_episode` sidecar (KEY=value) — the
   verifier's sleep input; sleep *verdicts* computed by bc-verify
   from it.
3. `bc-verify` daily scoring (24 h + 7 d) for the above types,
   state + summary files, exit codes; hosted as a step in the
   morning-report agent run; `verify_now` + `verification_report`
   dispatch actions.
4. Plugin header line + Verification submenu (read-only rendering
   of the state file).
5. Phase C certification logic (`--since-phase-c`, §7.1) + the
   one-time notification.

**v2 — completeness:**
6. LIMIT-CHANGE episodes end-to-end (incl. latency + the
   pre-Phase C `awaiting-phase-c` labelling and its post-Phase C
   flip to real judging).
7. Sleep episodes as JSONL records (replacing sidecar-only) +
   two-axis verdicts surfaced separately in the submenu.
8. `ext_flip` formal tracking in charge episodes; 30-day
   field-confidence summary for the delivery report.

**v3 — after the standalone app exists:**
9. The native app renders the same state file/episode data
   (no new telemetry); per-episode drill-down in the report.

Each step is code under the existing rules: built in bc-build,
deployed by the populate script, backups before replacement,
no new agents, no SMC writes, no behaviour change to enforcement
— this system observes the enforcer; it is never in its path.

---

## 10. Open questions for Yousef (preference-level, max 2)

1. **Failure notifications:** one notification per FAIL episode
   (immediate, once — my recommendation for charge/hold FAILs,
   since a missed overshoot is exactly what he'd want to know), or
   should *all* verification results — passes and fails — arrive
   only as the 08:00 morning summary + menu line, with no
   interruptions ever?
2. **Header line:** always show the compact `Verified: …` line in
   the menu header (my recommendation — the proof is visible every
   time he opens the menu, which matches how he checks the tool),
   or keep the header clean and show verification only inside the
   Verification submenu?

---

*End of design. Companion documents: `wrapper-design.md` (state-dir
and agent conventions), `notification-policy-design.md` (the policy
§6 plugs into), `overnight-report-design.md` (the morning report
this extends), `phase-c-plan.md` (the swap this provides evidence
for), `plan-rebuilt-2026-11-12.md` (where this sits in the plan).*
