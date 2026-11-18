# Battery Commander (BC) — Discharge Phase Design

- **Status:** DESIGN ONLY — not built, not approved for build. Awaiting Yousef's approval (design-before-build rule; the discharge phase needs its own separate approval, and its supervised test needs a further separate approval on a named day).
- **Date:** 2026-11-12
- **Scope of this document:** the design of BC's discharge capability. No code is specified to implementation level; no behaviour of the running system changes because of this document.
- **Related:** `limit-writer-design.md` (bc-limit v2), `phase-c-plan.md` (enforcer swap), `wrapper-design.md` (W1–W6), `comprehensive-audit-note.md` (finding C2 + the second-signal hard rule), `plan-rebuilt-2026-11-12.md` (Stage 3).
- **Clean-room note:** this design is derived only from BC's own architecture and BC's own measurements. The one fact taken from reverse engineering is that the old tool exposed a `discharge` CLI command; nothing about its internals is used or copied.

---

## 1. Purpose and scope

### 1.1 What "discharge" means in BC

A **discharge session**: a bounded, monitored episode in which BC lets the battery drain from its current level down to a defined **target**, while suppressing charging, and then hands control back to the normal limit enforcement (bc-limit hold/resume).

It exists for two purposes:

1. **Limit-enforcement assist (overshoot correction).** When the battery sits *above* the configured upper limit on AC — a real, observed condition (e.g. sleep charging, or a settled gauge reading above the limit) — holding alone can only wait. A discharge session is the corrective path down to the upper limit. This is the discharge-side answer to audit finding C2 (today, a confirmed overshoot notifies nobody and corrects nothing).
2. **Building block for calibration.** The future calibrate phase needs a controlled discharge leg with a target, a floor, aborts, and logging. It will reuse this session machinery with its own target/floor parameters under its own separate design and approval, instead of inventing a second mechanism.

### 1.2 What discharge is NOT

- **Not a way to drain on AC by force.** BC will not manipulate the adapter path (see §3 — that mechanism is designed out, because it is the proven loop generator).
- **Not a stress/load tool.** No induced CPU/GPU load in v1 (see §3).
- **Not automatic in v1.** Sessions are started by an explicit user action (the existing Smart Discharge menu action). Automatic start on overshoot is a future decision (§11, Q1).
- **Not a gauge fix.** Discharge cannot repair gas-gauge re-estimation ("gauge jumps"). It acts only on *confirmed* readings (§6, rule 2).
- **Not a replacement for hold.** When a session ends, bc-limit's normal hold/resume rules own the battery again.

### 1.3 In scope / out of scope

In scope: session lifecycle, ownership contract with bc-limit and bc-watchdog, safety rules, menu wiring, notifications, logging, test plan.
Out of scope: calibration's own parameters (deeper floor, full-cycle sequencing), any assisted-load mechanism, automatic session start, changes to bc-limit's normal (non-session) rules.

---

## 2. Evidence this design is built on

Three proven facts from BC's own investigation constrain everything below:

1. **Gauge jumps are real and large.** +7 to +12 % in ≤ 60 s with zero current (2026-10-30; 2026-11-11 ×2, incl. 86 %→93 % at 19:00 with `Amperage=0`, `IsCharging=No`). Any single % reading may be noise. **Hard rule (comprehensive audit):** before any forced-discharge mechanism acts on an overshoot (`PCT > UPPER+2`), the reading must be confirmed by a second signal — `IsCharging=Yes`, `Amperage>0`, or `CurrentCapacity` rising across two ticks. bc-limit v1.0-phase-c already implements the sibling rule for writes (a ≥ 5 %/tick change defers the write one cycle); this design applies the same discipline to discharge.
2. **The old stack's discharge loop must be designed out.** Proven sequence: charge overshoot → guardian discharge → SMC `ExternalConnected` flips Yes→No although the cable is attached (11–50 s after discharge start) → discharge aborts → hold → SMC returns to AC → limit reapplied → % falls below lower → charge → overshoot again. Two independent actors reacting to the same flip is what made it a loop. BC's design therefore has exactly one discharge actor, one BCLM writer, and an explicit AC-flip abort with cooldown (§6, rule 5).
3. **Thermal/load guard already exists.** bc-watchdog classifies APG state and touches `~/.battery-commander/.apg_paused` when the machine is hot or heavily loaded. Any discharge behaviour must honour that flag; it is never a reason to start or continue draining.

Standing project rules that also bind this design: never drain critically low; **never combine % below lower + attached charger + sleep**; stability > consistency > flexibility > features; tests are natural, on named days, never forced.

---

## 3. Candidate mechanisms, compared

| | (a) Release-and-drain (natural) | (b) Assisted drain (induced load) | (c) Hybrid (recommended) |
|---|---|---|---|
| How energy leaves | Charging is suppressed; the user's normal system load drains the battery while on battery. On AC it cannot drain — it can only hold. | A controlled artificial load (CPU/GPU burn) is added to drain faster. | Natural drain is the only energy-removal mechanism in v1; behaviour differs by context (on battery = active session; on AC = park + inform). Assisted load is an explicitly deferred extension point, off the table for v1. |
| Works on AC? | No (holds only). | **No** — the 85 W adapter supplies the load; the battery does not drain. (Draining on AC at all requires forcing the battery to power the system, i.e. the adapter-off path — see below.) | Same physical truth, handled honestly: on AC the session parks and the user is told draining resumes on battery. |
| AC-flip loop risk | None — the adapter path is never touched. | None from the load itself, but it does not solve the on-AC problem either. | None — adapter forcing is designed out. |
| Thermal / fan | None added. | Directly fights the APG guard; heat, fan noise (~3900 RPM mechanical issue is separate but load makes it audible), component wear. | None added in v1. |
| Fit with project rules | Full — this is "natural use" by construction. | Poor — it is a forced mechanism; the project forbids forced battery tests and favours natural episodes. | Full for v1; keeps the door open without shipping the risk. |
| Speed | Slow (user's real load; hours). Acceptable: overshoot correction is not urgent, and calibration legs are overnight-scale anyway. | Faster on battery, useless on AC. | Same as (a). |

**The adapter-off path is rejected explicitly, not silently.** The old tool demonstrably could drain on AC, and the only mechanism consistent with the evidence is making the battery power the system while cabled (that is what the `ExternalConnected` Yes→No flip was). That path produced the loop, fights the "never combine % below lower + charger + sleep" rule's spirit, and depends on SMC behaviour BC has not characterised on this machine. It is out of v1 and out of this design; revisiting it would need its own design, its own evidence, and Yousef's explicit approval.

**Recommendation: (c) hybrid, natural-drain only.** It is the only option consistent with all three proven facts in §2, it needs no new SMC behaviour, and the session machinery (target, floor, aborts, logging) is exactly what calibration will reuse.

---

## 4. Architecture and interaction contract

### 4.1 Components and ownership

- **bc-limit (root daemon) remains the ONLY writer of BCLM.** The discharge feature adds no second writer — this is the structural fix for the old loop.
- **bc-watchdog gains a discharge-session monitor layer.** The watchdog already ticks every 60 s, already reads bc-status, already owns the APG classification and the post-wake delay, and already never writes BCLM. It is the natural single owner of session supervision: confirmation ticks, progress, aborts, completion, logging.
- **dispatch.sh starts and cancels sessions** (it is what the menu calls). Starting = writing the session file (atomically, like other BC state writes). Cancelling = removing it.
- **powerwatch's existing WillSleep hook ends sessions before sleep** (§5.4). No new daemon, no new LaunchAgent, no new SMC reader: the monitor consumes the same bc-status output as everything else (which also keeps one canonical % source — the value bc-limit acts on, floor semantics).

### 4.2 The session file (the whole contract)

`~/.battery-commander/.discharge_session`, `KEY=value`, written atomically (temp + rename):

```
MODE=user            # user | corrective
TARGET=85            # integer %, within the bounds of §5.2
STARTED=1762963200   # epoch seconds, set once at creation
STARTER=dispatch     # who created it (for logs)
```

- **bc-limit's side of the contract** (the only bc-limit change this design requires): each tick, bc-limit checks for a *valid* session file — parses, `TARGET` an integer in [20, 99], `STARTED` no older than `DISCHARGE_MAX_MINUTES` (§4.3). While a valid session is honoured:
  - bc-limit **never writes BCLM=100** (charging stays suppressed), and
  - if `PCT > TARGET`, desired BCLM is 10 (write on change only, with the existing read-back verification and max-one-write-per-invocation rules unchanged).
  - bc-limit never creates, edits, or deletes the session file, and never ends a session; if the file is invalid or stale it is simply ignored (fail-safe: normal rules apply, so a crashed monitor can never suppress charging for longer than `DISCHARGE_MAX_MINUTES`, and in practice the watchdog removes stale files first).
- **Watchdog's side:** owns everything else — confirmation (§5.1), monitoring, completion (removing the file after the target is confirmed reached), aborts (removing the file + cooldown state), parked tracking, and all discharge logging.
- **Sailing:** if sailing mode were enabled, an active session takes precedence; the sailing tracker sees the session file and stays out (one line in its contract, no behaviour change while `SAILING=false` as configured today).

### 4.3 Configuration (proposed keys, defaults in parentheses)

Runtime state lives in the session file; tunables live with the other BC tunables. All have safe defaults and none needs to exist for the feature to work:

- `DISCHARGE_MAX_MINUTES` (240) — hard session lifetime, parked time included; also bc-limit's staleness bound.
- `DISCHARGE_PARK_TIMEOUT_MIN` (30) — max continuous time parked on AC before the session ends as incomplete.
- `DISCHARGE_FLIP_COOLDOWN_MIN` (30) — no new session after an AC-flip abort.
- `DISCHARGE_FLOOR_ABS` (20) — absolute floor % for this phase (target validation + emergency abort).
- `DISCHARGE_CONFIRM_TICKS` (2) — consecutive confirming ticks for entry and completion.

### 4.4 Logging

A dedicated `~/.battery-commander/discharge.log` (added to cleanup_logs rotation like the other BC logs). Every transition is logged with tick data: `%`, `BCLM`, `ExternalConnected`, `IsCharging`, `Amperage`, `CurrentCapacity`, APG state, and the reason string. These logs are the raw material for the episode scoring in §8 — a session that cannot be scored from its log is treated as a failed test, not a passed one.

---

## 5. State machine and flow

### 5.0 States

```
IDLE ──start──▶ ARMED ──confirmed──▶ ACTIVE ──target confirmed──▶ (complete) ──▶ IDLE
                  │                     │
                  │ entry fails         ├─ parked on AC > timeout ─▶ (ended, incomplete) ──▶ IDLE
                  ▼                     ├─ abort condition ────────▶ ABORTED ──▶ COOLDOWN (flip aborts only) ──▶ IDLE
               (refused, logged)        └─ user cancel ────────────▶ (cancelled) ──▶ IDLE
```

- **IDLE** — no session file.
- **ARMED** — session file exists; the monitor is collecting confirmation ticks (§5.1). bc-limit already honours the file (charging suppressed — safe direction while deciding).
- **ACTIVE** — draining (on battery) or **parked** (AC attached: no drain, no charge; a sub-state tracked by the monitor, not a separate contract). 
- **ABORTED / COOLDOWN** — session file removed, reason logged; after an AC-flip abort, new sessions are refused for `DISCHARGE_FLIP_COOLDOWN_MIN`.

### 5.1 Entry conditions (all must hold)

1. No session already active (one at a time; a start request during a session is a cancel request — §7).
2. APG not paused (`.apg_paused` absent) and battery temperature below the watchdog's existing critical threshold.
3. Not inside the post-wake window (120 s after a full wake — the watchdog's existing discharge-only delay) and no session was ended by sleep within that window.
4. **Confirmation (the second-signal rule):** `PCT > TARGET` on `DISCHARGE_CONFIRM_TICKS` consecutive ticks, **and**, whenever the claim is an overshoot (`PCT > UPPER + 2`), at least one second signal across those ticks: `IsCharging = Yes`, or `Amperage > 0`, or `CurrentCapacity` strictly rising tick-over-tick.
   - Worked example — the 2026-11-11 19:00 jump (86 %→93 %, `Amperage = 0`, `IsCharging = No`, flat capacity): entry is **refused**. Correct: that was gauge noise, and the reading later relaxed on its own.
   - Worked example — genuine sleep-charge overshoot (battery charged while asleep to a settled 91 % against an 86 % limit, capacity stable/high, charging had demonstrably occurred): entry is **granted** once the % is stable across two ticks with a second signal present.
5. If confirmation fails within 5 ticks, the session is refused: file removed, reason logged, one notification (§7). No partial state remains.

### 5.2 Target selection

- **Corrective mode** (overshoot assist): `TARGET = UPPER` (86 today). Fixed by the design, not user-editable.
- **User mode** (Smart Discharge): `TARGET` defaults to the configured **lower** limit (85 today) — see §11 Q2; the dispatch action may accept an explicit target.
- **Bounds (validated at start, both modes):** `DISCHARGE_FLOOR_ABS` (20) ≤ `TARGET` ≤ 99, and `TARGET < PCT` at entry (a session that starts already at/below target completes immediately as a no-op, logged).
- Calibration will request its own targets later under its own design; this phase's floor is deliberately conservative and is **not** calibration's floor.

### 5.3 While ACTIVE

- On battery: the battery drains under the user's real load. The monitor records %/capacity each tick; a single-tick |ΔPCT| ≥ 5 % is ignored for all decisions that tick (gauge deferral symmetry with bc-limit).
- On AC (attached at entry, or attached mid-session): the session **parks**. Nothing drains and — because bc-limit honours the session — nothing charges. Parked time counts toward both `DISCHARGE_PARK_TIMEOUT_MIN` (continuous) and the session's maximum lifetime.
- **AC-flip watch:** the monitor counts `ExternalConnected` transitions. ≥ 2 transitions within any 5-minute window, or the proven signature (a flip within 60 s of session start, twice), aborts the session with the flip cooldown (§6, rule 5). A single plug/unplug by the user is normal life, not a flip loop: one transition only parks/unparks.
- **APG:** if `.apg_paused` appears, the session suspends (treated as parked regardless of power source). If it persists 15 continuous minutes, the session aborts with reason `apg`.

### 5.4 Sleep and wake

- **Sessions never survive sleep.** The existing powerwatch WillSleep hook removes the session file before sleep completes and logs `ended-by-sleep`. This is also what makes the standing rule structural rather than advisory: with the file gone before sleep, there is no state in which charge stays suppressed while the Mac sleeps with `% < lower` and the charger attached — bc-limit's normal resume rule applies from its next tick.
- On wake, nothing resumes automatically. A user who wants to continue starts a fresh session (subject to the post-wake window, §5.1.3).

### 5.5 Completion and hand-back

- Completion requires `PCT ≤ TARGET` on `DISCHARGE_CONFIRM_TICKS` consecutive ticks (downward gauge noise must not fake completion either).
- On completion the monitor removes the session file, logs the episode summary (start %, end %, duration, parked time, min/max temp), and notifies once (§7).
- From the next bc-limit tick, normal rules own the battery: at the upper limit that means hold (BCLM stays 10); below the lower it means charging resumes. No special hand-back write exists or is needed — the hand-back *is* the removal of the file.

### 5.6 Abort conditions (any one ends the session immediately)

`ExternalConnected` flip loop (§5.3) · APG pause > 15 min · battery temperature at/above the watchdog's critical threshold · `PCT ≤ DISCHARGE_FLOOR_ABS` · session age > `DISCHARGE_MAX_MINUTES` · parked continuously > `DISCHARGE_PARK_TIMEOUT_MIN` (ends as *incomplete*, not *aborted*) · sleep (§5.4) · user cancel · battery data unreadable on 2 consecutive ticks. Every abort logs its reason; only the flip abort imposes a cooldown.

---

## 6. Safety rules (numbered, testable)

1. **Single writer.** Only bc-limit ever writes BCLM (or any SMC key). The session monitor, dispatch, and the plugin never write SMC. *Test:* code audit of the built components + runtime — every BCLM write in the daemon log originates from bc-limit.
2. **Second-signal entry.** No session reaches ACTIVE on a % reading alone; overshoot claims require the §5.1.4 second signal across two consecutive ticks. *Test:* replay of the 2026-11-11 19:00 episode data must refuse entry; a scripted stub with rising `CurrentCapacity` must grant it.
3. **Gauge symmetry.** A |ΔPCT| ≥ 5 % single tick is ignored for entry, progress, and completion decisions alike. *Test:* stub sequences with an injected ±7 % tick produce no transition.
4. **APG is absolute.** No start while `.apg_paused` exists; suspension while it appears; abort after 15 continuous minutes. *Test:* touch the flag mid-session in a sandbox run; verify suspension, then abort timing.
5. **AC-flip abort + cooldown, no auto-retry.** ≥ 2 `ExternalConnected` transitions in 5 min (or the §5.3 signature) aborts the session and blocks new sessions for `DISCHARGE_FLIP_COOLDOWN_MIN`. A flip-aborted session is never restarted by any component; only a fresh user action after the cooldown can start again. *Test:* scripted flip sequence aborts once, logs once, and a start attempt inside the cooldown is refused.
6. **Floors.** Targets are validated to [`DISCHARGE_FLOOR_ABS`, 99]; a session aborts the tick `PCT ≤ DISCHARGE_FLOOR_ABS`, whatever the target. This phase never discharges toward a critically low battery. *Test:* start requests with target 10 are refused at validation; a stub dropping PCT to 20 mid-session aborts that tick.
7. **Sleep rule.** Sessions end before sleep (WillSleep hook removes the file); no auto-resume on wake; no start within 120 s after wake. The combination % below lower + charger attached + sleep + suppressed charging must be unreachable. *Test:* with a session active and PCT < lower on AC, trigger sleep in the supervised test and verify the file is gone before the sleep completes and charging behaviour after wake is bc-limit-normal.
8. **Bounded lifetime.** A session (incl. parked time) never exceeds `DISCHARGE_MAX_MINUTES`; bc-limit independently stops honouring any older session file, so even a dead monitor cannot suppress charging indefinitely. *Test:* a forged session file with an old `STARTED` is ignored by bc-limit and removed by the monitor.
9. **User cancel always wins.** Cancel is immediate, needs no confirmation tick, and imposes no cooldown. *Test:* cancel during ARMED and during ACTIVE both end the session that tick.
10. **One session, one actor.** At most one session exists; the watchdog monitor is its only supervisor; sailing (if ever enabled) yields to it. *Test:* concurrent start attempts resolve to exactly one session file with one STARTER.
11. **Fail-safe on bad data.** Unreadable battery data on 2 consecutive ticks aborts the session; a corrupt or partial session file is treated as *no session* by bc-limit and deleted-and-logged by the monitor. No component retries in a tight loop; all decisions happen on the existing 60 s ticks. *Test:* truncated/garbage session files in a sandbox state dir produce normal bc-limit behaviour plus one monitor log line.
12. **No silent state.** Every start, refusal, park, resume, completion, and abort is written to `discharge.log` with the tick's raw readings. If it isn't in the log, it didn't happen — and the episode scores as failed in §8.

---

## 7. Menu wiring and notifications

- **Buttons keep their names and shape** (project rule). The existing **Smart Discharge** action (`dispatch.sh`, action `smart_discharge`) becomes the session control:
  - No session active → starts a user-mode session (§5.1–5.2). If the Mac is on AC, the start is accepted and parked, and the user is told plainly: draining happens on battery; unplug to drain, or the session ends after the park timeout.
  - Session active → the same action cancels it (the dialog makes the toggle unambiguous, following the existing dispatch dialog patterns). No new top-level button is added.
- **Status visibility:** while a session exists, `display_state.sh` (the plugin's single decider, per W2) adds one status line — e.g. `Discharging to 85% — on battery` / `Discharge parked — on AC` — and the header icon logic is unchanged. No new plugin file, no new agent.
- **Notifications follow the fixed BC policy** (state-based, never time-cooldown spam): at most one per session event — session refused (with reason), session completed, session aborted (with reason). Park/unpark and ordinary progress are log-only. A long discharge therefore produces at most two notifications in its life.

---

## 8. Test plan

No test in this section is approved by this document. Stages T1–T2 are build-time verification; T3 needs its own approval on a named day.

### T1 — Sandbox and stub tests (build time, no real battery)

Following the existing `test_bc_watchdog.sh` pattern: a sandbox state dir, scripted bc-status stubs, and a fake tick driver. Must pass: every *Test:* clause in §6; the full state-machine walk (start → confirm → drain → complete; start → park → timeout; start → flip → abort → cooldown refusal; sleep-hook removal; stale/corrupt file handling). `bash -n` clean; bc-limit's non-session behaviour byte-for-byte unaffected when no session file exists.

### T2 — Shadow mode (build time, real machine, zero effect)

The built monitor ships first with a shadow flag: it runs the full state machine against live readings and logs what it *would* do, but writes no session file bc-limit would honour (shadow sessions live in a separate shadow state file). Run shadow during normal use for several days, then score the shadow log against reality. **Pass criteria:** (i) shadow refuses the next natural gauge jump (no second signal), exactly as it must refuse the recorded 2026-11-11 19:00 pattern; (ii) shadow never starts during an APG-paused window; (iii) shadow's would-be completions land within ±1 % of target on genuine drains; (iv) zero shadow interference with the running system (it has no write path to prove it with — log review confirms no session file was ever created).

### T3 — Named-day supervised test (outline — separate approval, user present, daytime)

1. Preconditions: health check green; battery charged naturally to ≥ 92 % on AC (no forcing — charge with a raised temporary limit only if Yousef sets it himself); shadow results reviewed.
2. Episode 1 (corrective): unplug, start a session with target = upper (86). Observe the drain under normal use; verify two-tick completion at 86 ± 1, the episode summary in `discharge.log`, and exactly one completion notification.
3. Hand-back: plug in; verify bc-limit holds at the limit (BCLM 10, not charging) with no session file present.
4. Episode 2 (user mode + drills): start a session with target = lower (85) on battery; mid-episode, cancel from the menu (verify same-tick end, no cooldown); start again; mid-episode, plug in (verify park, no charge, no flip abort on a single transition); unplug (verify drain resumes); let it complete.
5. Sleep drill: with a session active, PCT below lower, AC attached — close the lid; verify the session file is gone before sleep and post-wake behaviour is normal (§6 rule 7).
6. Pass/fail is scored from the logs against §6's rules, not from impressions. Any rule failure stops the phase; fixes return to design before any retest.

### Episode scoring (applies to T2, T3, and all later real use)

An episode scores **pass** only if its log shows: two-tick confirmed entry (with second signal where required), no decision taken on a ≥ 5 % single tick, no BCLM write by any component other than bc-limit, target reached within ±1 % (or a correctly-reasoned abort/end), and a clean hand-back. Anything else is a **fail** to be reviewed before the next episode — this is the verification system the phase will be judged by in normal use, not just in tests.

---

## 9. Failure modes and fail-safe posture

- **Watchdog dies mid-session:** bc-limit honours the file only until `DISCHARGE_MAX_MINUTES` from `STARTED`, then normal rules resume (charging can be delayed by at most that bound, and only while % > target — the safe direction throughout is *hold*, never *forced charge* or *forced drain*).
- **bc-limit not yet loaded (pre-Phase C reality):** the discharge phase simply cannot run — sessions require the BC enforcer. **This phase builds only after Phase C is complete**; until then the menu action keeps today's behaviour (set limit + natural drain, honestly labelled).
- **Clock jumps / STARTED in the future:** a session file with `STARTED` ahead of now is invalid → ignored by bc-limit, removed by the monitor (rule 11's corrupt-file path).
- **User edits config mid-session (limit change):** targets were fixed at entry; a limit change ends the session (monitor detects config mtime change and ends it as *superseded*, logged, no notification beyond the limit change's own). Simplicity beats cleverness here.
- **Repeated flip aborts across days:** each is logged with full readings; two flip aborts in any 7 days should surface in the morning report as a pattern worth investigating (charger/cable health), not something the tool works around.

---

## 10. Build outline (for the later build approval — not part of this design's approval)

- **D1:** session monitor layer in bc-watchdog + shadow flag; T1 sandbox suite green.
- **D2:** bc-limit session honour (the §4.2 contract — small, single-function change; re-run the Phase C dry-run suite plus session cases); dispatch start/cancel; WillSleep hook wired (verify the hook fires for lid-close and AC sleep during D2, before relying on it).
- **D3:** plugin status line + Smart Discharge toggle behaviour; notifications per §7; cleanup_logs rotation gains `discharge.log`.
- **D4:** shadow period (T2) → report → T3 named-day test under separate approval → phase review.

Dependency: **Phase C complete** (BC daemon loaded and verified) before D2. D1's sandbox work has no live dependency.

---

## 11. Open questions for Yousef (preference-level only)

1. **Overshoot response:** when a confirmed overshoot is found on AC, should BC only *notify* (this design's v1), or should the notification/menu also offer a one-tap "start discharge" (still manual, just closer)? Automatic start is not proposed either way.
2. **Smart Discharge default target:** the configured **lower** limit (85 % today — drains to the bottom of your band) or the **upper** limit (86 % — drains only the overshoot)? This design defaults to lower; the button's meaning is your call.
3. **Assisted drain:** is an induced-load drain permanently off the table, or should it stay as a possible future opt-in experiment (default off, separately designed) for long on-battery drains? v1 ships without it regardless — this only decides whether the door stays open in the roadmap.

---

*End of design. Next step if approved: build per §10 (D1 first), under a separate build approval. Nothing in this document authorizes code, an install, or a battery test.*
