# Battery Commander (BC) — Charge Phase Design

- **Status:** DESIGN ONLY — not built, not approved for build. Awaiting Yousef's approval (design-before-build rule; the charge phase needs its own separate approval, and its supervised test needs a further separate approval on a named day).
- **Date:** 2026-11-13
- **Scope of this document:** the design of BC's charge capability beyond the already-proven charge-to-limit path. No code is specified to implementation level; no behaviour of the running system changes because of this document.
- **Related:** `discharge-design.md` (the sibling phase — this design mirrors its contract style), `limit-writer-design.md` (bc-limit), `wrapper-design.md` (W1–W6), `comprehensive-audit-note.md` (finding C2 + the second-signal hard rule), `discharge-build-note.md` (what the discharge phase actually shipped).
- **Clean-room note:** this design is derived only from BC's own architecture and BC's own measurements. The one fact taken from reverse engineering is that the old tool exposed a `charge` CLI command; its daemon-side semantics were never traced (the same evidentiary status as `enable_charging`'s exact value), and nothing about its internals is used or copied.

---

## 1. Purpose and scope

### 1.1 What "charge" already is in BC — and what this phase adds

Charging to the configured limit is **not** part of this phase's build. It is bc-limit's normal rule (resume below the lower limit, hold at the upper), and it was **proven live on 2026-11-13**: a natural leg charged 79 % → 86 % on BCLM=100 and ended with a read-back-verified hold write at the limit (§2.1). That path is finished and this design does not touch it.

This phase is about the one charge behaviour that goes *beyond* the standing limit: **Charge to 100%** — the user asking, once, for a full battery despite a configured limit of 86/85. Today that menu item works by brute force: dispatch rewrites the enforced configuration to 100/99 and leaves it there (§2.2). The phase turns that blunt config change into a **charge session**: a bounded, monitored, logged episode with a defined end — after which the user's own configured limit is restored automatically.

A **charge session**: a bounded episode in which the enforced limit is temporarily raised to a target (100 % in v1's default) so the battery can charge past the configured upper limit, supervised by bc-watchdog, and closed by restoring the exact configuration that existed before the session started.

### 1.2 What this phase ADDS beyond the proven path (the precise delta)

1. **One-shot semantics with automatic restore.** Today, Charge to 100% *strands* the user: the configuration stays 100/99 indefinitely, and the battery lives at 100 % — the exact condition the tool exists to prevent — until the user happens to set a limit again. A session remembers the prior configuration and restores it on completion or on any abort.
2. **Supervision.** Confirmation before completion is declared, a session timeout, unplug/APG/sleep behaviour, and abort paths — none of which exist today (today there is only a flag file that the watchdog tidies up at 100 %).
3. **An episode record.** Start (with the prior configuration), progress, completion, aborts and the restore are logged and scoreable, like discharge episodes. Today a charge-to-100 leaves no episode record at all.
4. **A named post-charge state.** After a completed session the battery necessarily sits *above* the restored limit (e.g. ~100 % against 86/85). Today that overhang is accidental and indistinguishable from an anomaly; this design names it, logs it, and defines how the overshoot machinery must treat it (§5.5).
5. **Optionally, a chosen target** (charge to 90 % for a trip, not only 100 %) — same machinery, decided by Q2 (§11).

### 1.3 What charge is NOT

- **Not a change to bc-limit.** The enforcer's rules, writes, gauge deferral, APG suppression and discharge-session contract are untouched. The charge session works entirely through the configuration bc-limit already enforces (§3).
- **Not a fast-charge or charge-rate feature.** BC does not control charge current; the SMC/adapter does.
- **Not a discharge trigger.** A session never starts, implies, or schedules a discharge — including to "fix" the post-charge overhang (§6, rule 11).
- **Not sailing.** Sessions take precedence over the sailing tracker exactly as discharge sessions do; with `SAILING=false` (today's configuration) this is a contract note, not a behaviour.

### 1.4 In scope / out of scope

In scope: charge-session lifecycle, the config-override + restore contract, supervision and aborts, menu wiring of the existing Charge to 100% item, notifications, logging, test plan.
Out of scope: any bc-limit change; calibration's charge leg parameters (calibration will reuse this session machinery under its own design, as it reuses discharge's); scheduled/recurring charging (the old tool's `schedule` concept — dropped from the wrapper design in W0–W6 and not revived here); any new menu button (see §7 — one label question is flagged, no button is invented).

---

## 2. Evidence this design is built on

### 2.1 The plain charge-to-limit path is proven live (2026-11-13)

From the bc-limit daemon log, the evening a discharge episode ended at 79 %:

- 22:48:46–22:51:46 — `state: … pct=84%→86% BCLM=100 charging=1 external=1`, decisions "nothing to do (BCLM=100 already correct)": the resume state persisted correctly across the whole leg.
- 22:51:46 — `WRITE: BCLM=10 (pct=86%)` followed by `WRITE OK: BCLM=10 verified by read-back`.
- 22:52:46 onward — `pct=86% BCLM=10 charging=0`, stable hold. The decimal gauge reading drifted to 86.7 % afterwards with zero current — gauge estimation, not energy (§2.4).

Conclusion: resume, charge, hold-at-limit and hold-stability all work under the current enforcer with no session machinery at all. **Any charge-session design that modifies bc-limit is solving a problem that does not exist.**

### 2.2 Audit of today's Charge to 100% (the behaviour being replaced)

Verified from the shipped sources on 2026-11-13:

- The menu item is labelled **"Charge to 100% & Hold"** and calls `dispatch.sh` action `charge_full`.
- `charge_full` writes `.charge_target` = `100`, sets `.active_mode` = `charge_full`, forces `SAILING=false / SAIL_GAP=1`, and calls `bc_apply_limit 100 99` — which validates, then **rewrites `LAST_UPPER/LAST_LOWER` in the configuration file to 100/99 and saves it**. There is no record of the previous values anywhere in this path.
- The watchdog's `section_charge_target` clears `.charge_target` when the canonical % reaches 100 and flips `.active_mode` to `hold`. **Nothing, anywhere, restores 86/85.** Grep for a restore path in the watchdog and display logic returns nothing.
- `.charge_target` is a display/intent flag, not a session: the launcher also writes it at login (with the configured upper) when the battery is below the lower limit, purely so the plugin header can show a target.

So today's semantics are honestly labelled ("& Hold") but are a trap in practice: one tap before a trip silently retires the user's charge limit until they notice. Parity note: the old wrapper drove the old tool the same way (`limit 100 99`), so this *is* the historical user-visible behaviour; whether BC keeps it is a genuine product decision, put to Yousef as Q1 (§11) rather than assumed.

### 2.3 The old tool's `charge` command (parity boundary)

Reverse engineering established that `charge` existed as a CLI command handler alongside `limit`, `discharge` and `calibrate`, and that charging control itself is the daemon toggling BCLM via `enable_charging` / `disable_charging`. The `charge` handler's own semantics (one-shot vs persistent, target handling) were **not** traced. This design therefore claims parity only at the level BC can honestly claim: *the user can order a charge to full on demand, past the limit, and the tool manages it* — the same level at which the discharge design claimed parity. BC's session semantics are BC's own design decision, flagged as Q1.

### 2.4 Standing facts that constrain the design

1. **Gauge behaviour at the top of charge.** The canonical % is the floored ioreg value bc-limit acts on. It reaches 100 while the decimal estimate is still ~99.x, and after a hold write the decimal estimate can drift *up* by 1–2 points with zero current (86.7 % displayed against a floored 86 % on 2026-11-13; 88.7 % displayed against a held 86 % earlier the same day). Completion must therefore be defined on the canonical reading with confirmation ticks (§5.4), never on a single decimal reading.
2. **Real charging happens during sleep.** Proven (81 % → 90 % over ~1.3 h asleep, 2026-10): BCLM persists through sleep and the enforcer sleeps, so a battery that was charging when the lid closed keeps charging to the *configured* ceiling. During a charge session the configured ceiling is the session target (≤ 100), which is intrinsically safe — this asymmetry with discharge drives the different sleep rule in §5.3.
3. **APG suppression is live and asymmetric.** bc-limit suppresses only the *resume* write while `.apg_paused` exists (a discharge session suppresses resume the same way); hold writes are never suppressed. A charge session must expect its charge to be *delayed* by APG and treat that as normal (§5.2), never as a fault to work around.
4. **bc-limit defers writes on suspected gauge jumps.** A ≥ 5-point single-interval change defers any decided write one cycle. Near a session's end this can delay the hold write by one tick after a jumpy reading; harmless, and completion counting (§5.4) uses the same canonical source so the two never disagree about the %.
5. **One actor per function.** bc-limit is the only BCLM writer; the watchdog is the only session supervisor; dispatch is the only session starter. The discharge phase's loop-prevention structure carries over unchanged.

Standing project rules that also bind this design: buttons keep their names and shape unless Yousef decides otherwise; stability > consistency > flexibility > features; tests are natural, on named days, never forced.

---

## 3. Candidate mechanisms, compared

| | (a) Status quo — persistent limit change | (b) Config-override session + restore (recommended) | (c) bc-limit session contract (mirror of discharge) |
|---|---|---|---|
| How it works | `charge_full` rewrites the config to 100/99; the watchdog tidies flags at 100 %. | dispatch records the prior config in a session file, applies TARGET/(TARGET−1) through the existing validated `bc_apply_limit`; the watchdog supervises and restores the prior config at the end. bc-limit only ever enforces the config. | A `.charge_session` file that bc-limit itself honours by treating TARGET as the effective upper while the file is valid. |
| Enforcer change | None. | **None.** | Real: a second, file-based limit source inside the root daemon, interacting with the APG gate, the gauge deferral and the discharge-session suppression. |
| Restore guarantee | None — stranding is the design. | Watchdog restores on completion, abort, timeout, staleness and cancel; the session file itself carries the prior values, so any later actor (incl. the login reapply path) can restore. | Restore = file removal; but a crashed monitor leaves the enforcer honouring a phantom limit until the staleness bound — the failure lives inside the safety-critical component. |
| Failure direction | Fails permissive (limit silently gone). | Fails permissive *and loud*: worst case the config stays at 100/99 (today's behaviour) with a log + notification demanding attention. Never fails toward suppressing charging. | Fails inside the enforcer; a bug risks the proven limit path itself (§2.1). |
| Fit with the proven architecture | It is what ships today. | Reuses the discharge phase's exact supervision shape (file contract, watchdog monitor, aborts, episode log) with the one honest difference the mechanism requires (§4.1). | Superficially symmetric, but the symmetry is false: discharge needed the enforcer because it *suppresses* a write; charge needs the ceiling moved, which the config already does. |

**Recommendation: (b).** It adds no risk to the proven enforcer, reuses the discharge phase's supervision machinery and test patterns, and its worst failure is today's behaviour plus an alarm. Option (a) remains available to Yousef as a product choice via Q1 — if he prefers "& Hold" to stay the meaning of the button, this phase shrinks to supervision + logging around the persistent change, and §5.5/§6 are re-scoped accordingly.

---

## 4. Architecture and interaction contract

### 4.1 Components and ownership

- **bc-limit (root daemon) is unchanged and remains the only writer of BCLM.** During a session it simply enforces a configuration that happens to say 100/99 (or TARGET/(TARGET−1)). It does not know sessions exist — with one deliberate exception: its existing discharge-session and APG suppressions keep working exactly as today, against whatever the current config is.
- **bc-watchdog gains a charge-session monitor layer**, sibling to the discharge monitor: confirmation, progress, completion, aborts, restore, logging. It never writes BCLM. It restores configuration only through dispatch's validated `bc_apply_limit` path (invoked as a helper), never by editing the config file directly.
- **dispatch.sh starts and cancels sessions** via the existing `charge_full` action (§7). Starting = write the session file (atomically) + apply the session limit. Cancelling = restore + remove the file.
- **No new daemon, agent, or menu file.** The monitor consumes the same canonical bc-status readings as the discharge monitor (one % truth for the whole tool).

The one asymmetry with discharge, stated plainly: a discharge session's contract lives in a file *bc-limit reads*, because discharge must suppress an enforcer write. A charge session's contract lives in a file *the watchdog reads*, because charge must move the enforcer's config and later move it back. The supervision shape — file, monitor, aborts, log, scoring — is identical.

### 4.2 The session file (the whole contract)

`~/.battery-commander/.charge_session`, `KEY=value`, written atomically (temp + rename) by dispatch at start:

```
TARGET=100           # integer %, the session ceiling
PREV_UPPER=86        # configuration to restore at the end
PREV_LOWER=85
STARTED=1763054400   # epoch seconds, set once at creation
STARTER=dispatch     # who created it (for logs)
```

- The watchdog is the file's owner after creation: it validates it every tick (TARGET integer in (PREV_UPPER, 100]; PREV values pass the same validation `bc_apply_limit` applies; STARTED sane and not older than `CHARGE_MAX_MINUTES`).
- An invalid or stale file is **not** ignored (contrast discharge, where ignoring is safe): it triggers the restore path (§5.5) using whatever PREV values parse, or — if none parse — a loud log + notification, because a session file that cannot be understood means the config may be a session config nobody can account for.
- Mutual exclusion: a charge session and a discharge session never coexist (§6, rule 5). Starting charge ends any discharge session first (the existing `sd_session_invalidate` path — a user charge intent already supersedes a discharge session today); starting discharge likewise ends a charge session (restore first, then the discharge start proceeds).

### 4.3 Configuration (proposed keys, defaults in parentheses)

- `CHARGE_MAX_MINUTES` (360) — hard session lifetime; also the staleness bound. Sized for a deep charge on this machine (79 % → 86 % took ~13 min at the top of the range; a 20 % → 100 % charge is a few hours), not for an all-day hold at the target.
- `CHARGE_UNPLUG_TIMEOUT_MIN` (60) — max continuous time on battery mid-session before the session ends as incomplete (restore applies; restoring on battery is harmless — §5.2).
- `CHARGE_CONFIRM_TICKS` (2) — consecutive confirming ticks for completion (mirrors `DISCHARGE_CONFIRM_TICKS`).
- `CHARGE_RESTORE_ALERT_TICKS` (3) — consecutive failed restore attempts before the failure is escalated to a notification (the restore itself retries every tick regardless; §9).

### 4.4 Logging

A dedicated `~/.battery-commander/charge.log` (added to cleanup_logs rotation like `discharge.log`). Every transition is logged with tick data: %, BCLM, ExternalConnected, IsCharging, Amperage, CurrentCapacity, APG state, the live config, and the reason string. These logs are the raw material for episode scoring in §8 — a session that cannot be scored from its log is treated as a failed test, not a passed one.

---

## 5. State machine and flow

### 5.0 States

```
IDLE ──start──▶ ARMED ──charging confirmed──▶ ACTIVE ──target confirmed──▶ RESTORING ──▶ IDLE (episode: completed)
                  │                              │
                  │ entry fails                  ├─ unplug > timeout / max age ──▶ RESTORING ──▶ IDLE (episode: incomplete)
                  ▼                              ├─ abort condition ─────────────▶ RESTORING ──▶ IDLE (episode: aborted)
               (refused, logged)                 └─ user cancel / superseded ────▶ RESTORING* ─▶ IDLE
```

\* RESTORING is skipped in exactly one case: **superseded** — when another actor has already changed the config deliberately (§5.5). Restoring over a user's newer choice would be a bug, not a recovery.

- **IDLE** — no session file; the config is the user's standing limit.
- **ARMED** — session file written and session limit applied; the monitor waits to see charging actually begin (or the battery already at/above target).
- **ACTIVE** — charging toward TARGET (or legitimately waiting: on battery, or APG-delayed — sub-states tracked by the monitor, §5.2).
- **RESTORING** — the monitor applies PREV_UPPER/PREV_LOWER via `bc_apply_limit` and verifies the config reads back; the session file is removed only after the restore verifies (§5.4).

### 5.1 Entry conditions (all must hold)

1. No session of either kind active (a start request during a *charge* session is a cancel request — §7; during a *discharge* session it supersedes it, §4.2).
2. The enforcer path is healthy enough to move the config: `bc_apply_limit`'s own preconditions (a battery % reading exists, BCLM is readable) — a start that cannot apply its limit fails cleanly with no session file left behind.
3. `TARGET` valid: integer, `PREV_UPPER < TARGET ≤ 100` (a target at or below the configured upper is refused as *already covered by your limit* — the session would be a no-op wearing a costume).
4. `PCT < TARGET` at entry (a start already at/above target completes immediately as a no-op episode, logged — symmetric with discharge §5.2).
5. Not inside the post-wake window (120 s after a full wake — the monitor takes no session decision on unsettled readings).
6. APG state does **not** block entry (contrast discharge): APG delays charging, it does not make charging wrong; the session simply waits (§5.2). Battery temperature at/above the watchdog's critical threshold *does* block entry — starting a charge into an already-critical thermal state is refused and logged.

### 5.2 While ACTIVE

- **On AC, charging:** the normal case. The monitor records %/capacity per tick; a single-tick |ΔPCT| ≥ 5 % is ignored for all decisions that tick (gauge symmetry with the rest of the tool).
- **On AC, not charging, below the session lower (TARGET−1):** either the charge is APG-delayed (`.apg_paused` present — expected, logged as waiting-on-APG, no fault) or something is wrong; if neither APG nor a recent gauge deferral explains it for 15 continuous minutes, the session aborts with reason `no-charge-progress` and restores. (bc-limit's own decisions are in its log; the monitor correlates, it does not second-guess tick by tick.)
- **On battery (unplugged at entry, or unplugged mid-session):** the session **waits** — the mirror image of a discharge park. Nothing the tool does can charge without AC. Waiting time counts toward `CHARGE_UNPLUG_TIMEOUT_MIN` (continuous) and the session's maximum lifetime. Replugging resumes the session where it left off; a single unplug/replug is normal life, and there is no AC-flip concept on the charge side (flips endanger discharge because they fake power-source signals to a *draining* decision; here the only decision they can delay is a restore, which is safe at any time).
- **At/above the session lower but below TARGET on AC:** the taper zone — charging current falls naturally near full. Progress is judged by % and capacity trend over minutes, not by Amperage on any single tick.

### 5.3 Sleep and wake

- **Charge sessions persist across sleep** — the deliberate opposite of discharge sessions, justified by the asymmetry in §2.4.2: the dangerous sleep combination for discharge was *suppressed charging + % below lower + charger attached*, which a leftover discharge file could create. A leftover charge session creates only *a ceiling of at most 100 %*, and real sleep charging (proven) simply advances the session toward its target while the Mac sleeps. There is no state a sleeping charge session can produce that the battery's own charge management does not already bound.
- Concretely: no WillSleep hook touches the session file. The powerwatch hook continues to end *discharge* sessions only.
- On wake: the post-wake window (§5.1.5) applies before any completion or abort decision; a battery that reached TARGET in sleep completes on the first confirming ticks after the window, and the restore follows immediately (§5.4).
- The staleness bound still applies across sleep: a session older than `CHARGE_MAX_MINUTES` at wake is stale and restores (§5.5) rather than completing silently days later.

### 5.4 Completion and restore

- Completion requires `PCT ≥ TARGET` on `CHARGE_CONFIRM_TICKS` consecutive canonical ticks. For `TARGET = 100` only, `IsCharging = No` at `PCT ≥ 99` on the same ticks is accepted as a confirming signal — the taper ends before the floored reading always lands, and "full" must mean the battery's own end-of-charge, not an artefact of rounding.
- On completion the monitor enters RESTORING: it calls `bc_apply_limit PREV_UPPER PREV_LOWER`, reads the config back, and only then removes the session file and logs the episode summary (start %, end %, duration, waiting time split by cause — battery/APG —, min/max temp). One completion notification (§7).
- If the restore fails verification, the session file stays, the restore retries next tick, and after `CHARGE_RESTORE_ALERT_TICKS` failures a notification fires (§9). The episode does not score as completed until the restore verifies — completion is a property of the *whole* episode, restore included.

### 5.5 The post-charge overhang (a named state)

After a completed session the battery sits above the restored upper limit (by design — that was the point of the session). The rules for this state:

- bc-limit needs nothing: `PCT ≥ UPPER` with BCLM already 10 is its ordinary hold; no write occurs and none is needed.
- The watchdog's confirmed-overshoot response (finding C2) must **not** fire on the session's own overhang: the completion record in `charge.log` attributes the state, and C2's second-signal rule independently prevents an alert on a static, non-charging reading. If a *later* genuine second signal appears (the battery demonstrably charging above the restored limit), C2 proceeds as normal — the overhang excuses a state, not a behaviour.
- BC never discharges the overhang away on its own (§1.3). It drains naturally, or the user starts a discharge session — the corrective discharge path built in the discharge phase, with its own confirmations.

### 5.6 Abort conditions (any one ends the session; all restore unless superseded)

Session age > `CHARGE_MAX_MINUTES` · on battery continuously > `CHARGE_UNPLUG_TIMEOUT_MIN` (ends as *incomplete*) · `no-charge-progress` (§5.2) · battery temperature at/above the watchdog's critical threshold · battery data unreadable on 2 consecutive ticks · user cancel · config changed by another actor mid-session → **superseded** (no restore, §5.5 of the flow — the new config stands) · discharge start (§4.2). Every abort logs its reason; none imposes a cooldown (a charge session is not a loop risk, and a user who was just refused a charge may legitimately retry at once).

---

## 6. Safety rules (numbered, testable)

1. **Single writer.** Only bc-limit ever writes BCLM (or any SMC key). The charge monitor, dispatch's session path and the plugin write only the session file and — through `bc_apply_limit` — the config. *Test:* code audit of the built components + runtime: every BCLM write in the daemon log originates from bc-limit, including during sessions.
2. **Config is the only limit truth.** No component enforces, caches or reconstructs a limit from anywhere but the config file; the session's TARGET takes effect *only* by becoming the config, through the validated `bc_apply_limit` path. *Test:* sandbox start shows the config at TARGET/(TARGET−1) with PREV values intact in the session file; a hand-corrupted config mid-session is detected as a supersede, not "corrected" back to the session values.
3. **Restore is unconditional.** Completion, every abort, timeout, staleness and user cancel all pass through RESTORING with the recorded PREV values; the session file is removed only after the restore verifies by config read-back. *Test:* for each abort trigger in §5.6, a sandbox run ends with the config byte-identical to its pre-session content.
4. **Supersede beats restore.** If the config at restore time differs from *both* the session values and the PREV values, another actor changed it deliberately: the session ends as superseded and the newer config is left untouched. *Test:* mid-session limit change to 90/89 survives the session's end untouched, with a superseded line in `charge.log`.
5. **Mutual exclusion.** At most one session (charge or discharge) exists at any moment; starting one kind ends the other first, with the ending logged by both monitors. *Test:* start charge during an active discharge and vice versa; exactly one session file exists at every tick, and the ended session's log shows the supersede reason.
6. **APG is a delay, never a fault and never overridden.** No component attempts to charge around `.apg_paused`; bc-limit's resume suppression is expected behaviour during a session; APG alone never aborts a session (the session clock, including `CHARGE_MAX_MINUTES`, is the only time bound). *Test:* with `.apg_paused` present, a session stays ACTIVE with zero BCLM writes and waiting-on-APG log lines, and completes normally once the flag clears.
7. **Completion needs confirmation.** `PCT ≥ TARGET` on `CHARGE_CONFIRM_TICKS` consecutive canonical ticks (plus, for TARGET=100, the taper signal of §5.4); a single tick with |ΔPCT| ≥ 5 % is ignored for completion — an upward gauge jump must not fake "full" any more than a downward one may fake a discharge target. *Test:* stub sequences jumping to 100 for one tick produce no completion; two stable ticks complete and restore.
8. **Target bounds.** `TARGET` is an integer in (configured UPPER, 100]; start is refused (with the reason shown to the user) outside that range, and entry at `PCT ≥ TARGET` is a logged no-op, never an error state. *Test:* target requests of 86 (= UPPER), 101, and non-numeric input are all refused at validation; a start at PCT = TARGET completes as a no-op episode.
9. **Sleep posture.** A session file surviving sleep is valid state, not corruption: no hook removes it, no actor treats wake-with-session as an error; the post-wake window gates all decisions, and the staleness bound is the only sleep-related ending. The discharge sleep rule is untouched. *Test:* simulated sleep/wake cycle mid-session (state-file + clock manipulation in the sandbox; the real lid-close case is exercised in T3) — session resumes, completes, restores.
10. **Bounded lifetime, independently enforced.** A session never exceeds `CHARGE_MAX_MINUTES`; the monitor checks staleness every tick, and the login reapply path (`dispatch.sh reapply_limit`, already run by the launcher) restores PREV from any stale session file it finds before reapplying — so even a dead monitor *and* a dead watchdog cannot strand the session config past the next login. *Test:* a forged session file with an old STARTED is restored by the monitor path and, with the monitor disabled, by the reapply path.
11. **Charge never discharges.** No charge-session path — completion, abort, restore, overhang — starts, schedules or implies a discharge. *Test:* after a completed session restores 86/85 at ~100 %, no discharge session file exists, none is created on subsequent ticks, and the discharge monitor's log shows no entry.
12. **No silent state.** Every start, refusal, wait transition, completion, abort, supersede and restore (with before/after config values) is written to `charge.log` with the tick's raw readings. If it isn't in the log, it didn't happen — and the episode scores as failed in §8.

---

## 7. Menu wiring and notifications

- **Buttons keep their names and shape** (project rule) — with one flagged exception: the existing item's label, **"Charge to 100% & Hold"**, *describes the old semantics*. If Q1 (§11) chooses one-shot sessions, the "& Hold" wording becomes false and the label needs Yousef's decision (proposal, not a unilateral change: **"Charge to 100%"**, with the status line below carrying the "restores 86/85 after" information). If Q1 keeps persistent semantics, the label stays exactly as is. No other item changes; no new top-level button is added.
- The existing `charge_full` dispatch action becomes the session control, mirroring Smart Discharge's toggle:
  - No charge session active → starts a session (§5.1). If a discharge session is active, it is ended first (§4.2) and the user is told.
  - Charge session active → the same action cancels it (restore + file removal, that tick), following the existing dispatch dialog patterns so the toggle is unambiguous.
- **Status visibility:** while a session exists, `display_state.sh` (the plugin's single decider, per W2) adds one status line — e.g. `Charging to 100% — restores 86/85` / `Charge session waiting — on battery` / `Charge session waiting — APG`. The `.charge_target` flag keeps its existing display role; the launcher's login use of it is unchanged.
- **Notifications follow the fixed BC policy** (state-based, never time-cooldown spam): at most one per session event — session refused (with reason), session completed (with the restored limit), session aborted (with reason), restore-failure escalation (§5.4). Waiting and ordinary progress are log-only. A multi-hour charge therefore produces at most two notifications in its life.

---

## 8. Test plan

No test in this section is approved by this document. Stages T1–T2 are build-time verification; T3 needs its own approval on a named day.

### T1 — Sandbox and stub tests (build time, no real battery)

Following the existing `test_bc_watchdog.sh` / `test_discharge.sh` pattern: a sandbox state dir, scripted bc-status stubs, a fake tick driver, and a sandboxed `bc_apply_limit` that records its calls. Must pass: every *Test:* clause in §6; the full state-machine walk (start → charge → complete → restore-verified; start → cancel; start → unplug-timeout; start → no-charge-progress; start → supersede; stale-file restore via both paths; APG wait → completion; wake-window gating). `bash -n` clean; bc-limit is not in the test's blast radius at all — its binary and source are untouched by the phase, which the build verifies by checksum against the pre-build state.

### T2 — Shadow mode (build time, real machine, zero effect)

The built monitor ships first with a shadow flag, as the discharge monitor did: dispatch writes `.charge_session.shadow`, **the config is never changed**, and the monitor runs its state machine against live readings, logging what it *would* do. Shadow's honest limit, stated in advance: because the config override *is* the mechanism, a shadow session to 100 % can never complete against a real 86 % limit — the battery will never get there. Shadow therefore verifies **bookkeeping and detection only**: start/cancel/stale/supersede handling, and completion detection scored against targets *below* the real limit during natural charge legs (e.g. a shadow session with TARGET=84 during an ordinary 79 % → 86 % leg must declare completion at the right ticks). **Pass criteria:** (i) shadow bookkeeping is exact across several days of normal use; (ii) shadow completion detection lands within ±1 % of target on genuine legs; (iii) zero interference — no real session file, no config write, provable from the logs. The full loop (override → charge past the limit → restore) is *only* proven in T3; this design does not pretend otherwise.

### T3 — Named-day supervised test (outline — separate approval, user present, daytime)

1. Preconditions: health check green; battery naturally at ≤ ~80 % (arrive there by normal use — the previous evening's discharge episode is a legitimate way, never a forced drain); shadow results reviewed.
2. Episode 1 (the full loop): start Charge to 100% on AC. Verify: config flips to 100/99 with PREV 86/85 recorded; charge proceeds past 86 without a hold write; completion on two confirmed ticks at 100 (or the §5.4 taper signal); restore to 86/85 verified within 2 ticks of completion; the overhang state is stable (BCLM=10, no charging, no overshoot alert, no discharge starts); exactly one completion notification.
3. Drills (same session slot, after Episode 1's restore): start again and **cancel mid-charge** from the menu (verify same-tick restore); start again and **unplug mid-charge** (verify waiting state; replug; verify resumption); if time and Yousef's patience allow, **sleep drill**: close the lid mid-charge for ~15 min, wake, verify no decision inside the post-wake window and normal completion/restore afterwards.
4. Pass/fail is scored from the logs against §6's rules, not from impressions. Any rule failure stops the phase; fixes return to design before any retest.

### Episode scoring (applies to T2, T3, and all later real use)

An episode scores **pass** only if its log shows: a validated start with PREV recorded, no decision taken on a ≥ 5 % single tick, no BCLM write by any component other than bc-limit, target reached within ±1 % (or a correctly-reasoned abort/end), and a verified restore to the exact pre-session config (or a correctly-reasoned supersede). Anything else is a **fail** to be reviewed before the next episode.

---

## 9. Failure modes and fail-safe posture

- **Watchdog dies mid-session:** the config stays at the session values — i.e. the system degrades to *today's* Charge to 100% behaviour, never to anything worse. Recovery layers, in order: the watchdog's own next run (staleness check every tick); the login `reapply_limit` path (§6, rule 10); the user's own limit actions (any of them supersedes the session, §5.5). A notification is not possible from a dead watchdog — which is why the morning report should surface any session file older than `CHARGE_MAX_MINUTES` it ever finds, as a pattern note.
- **Restore cannot verify:** `bc_apply_limit` refuses to write without a battery reading and a readable BCLM. If readings are down, restore retries every tick and escalates after `CHARGE_RESTORE_ALERT_TICKS` (§5.4). The interim state (config at 100/99) is the permissive direction: the user can always charge; nothing is ever stranded *unable* to charge by a charge session. This asymmetry with discharge (whose fail-safe is hold) is deliberate: each phase fails toward its own safe side.
- **Clock jumps / STARTED in the future:** a session file with `STARTED` ahead of now is invalid → the restore path runs immediately using its PREV values (§4.2).
- **User edits the config file by hand mid-session:** indistinguishable from a deliberate limit action → supersede (§5.5). Simplicity beats cleverness, exactly as in the discharge design.
- **bc-limit not running:** sessions move the config, and only the enforcer gives a config meaning. If the daemon is down, charging follows raw system behaviour regardless of any config; the health check already treats a dead enforcer as a headline fault independent of this phase. Session start does not add its own daemon check (dispatch's `bc_apply_limit` preconditions — readable BCLM — are the practical gate).

---

## 10. Build outline (for the later build approval — not part of this design's approval)

- **C1:** charge-session monitor layer in bc-watchdog + the §4.2 file contract + shadow flag; `charge.log` added to cleanup rotation; T1 sandbox suite green.
- **C2:** dispatch `charge_full` reworked to the session toggle (start/cancel/supersede, dialog patterns unchanged); restore paths (completion/abort/timeout/stale) wired through `bc_apply_limit`; the `reapply_limit` stale-session reconciliation (§6, rule 10).
- **C3:** plugin status line via `display_state.sh`; notifications per §7; the menu label change **only if** Q1's answer requires it.
- **C4:** shadow period (T2) → report → T3 named-day test under separate approval → phase review.

Dependencies: the **discharge phase complete** (it is — built and live-tested 2026-11-13, including the monitor-fix follow-up) and **Phase C complete** (it is — BC's daemon has enforced the limit since 2026-11-13). C1's sandbox work has no live dependency. No step in C1–C4 touches bc-limit; the build verifies that by checksum.

---

## 11. Open questions for Yousef (preference-level only)

1. **Charge to 100%: one-shot or persistent?** Should the existing item become a session that charges to 100 % and then **restores your 86/85 automatically** (this design's recommendation — a charge is an errand; the limit is your standing choice, and today's behaviour silently retires it), or stay as it is today — a persistent switch to 100/99 ("& Hold") that you later undo yourself? *Recommendation: one-shot with restore.* This also decides the menu label (§7).
2. **Only 100 %, or a chosen target?** Should the session accept a target (e.g. 90 % for a trip — faster, less time at the top) through the same dialog pattern Smart Discharge uses, defaulting to 100? *Recommendation: chosen target, default 100* — the machinery is identical once sessions exist, and 100-only would make the feature useless for its most common real errand. If you prefer v1 minimal, 100-only ships first and targets arrive later with no redesign.
3. **Sessions across sleep:** this design lets a charge session span sleep and finish on wake (safe because the session ceiling is at most 100 % — §5.3), unlike discharge sessions, which die at sleep. *Recommendation: keep the asymmetry* — but if you prefer one uniform rule ("no session of any kind survives sleep") for simplicity, the charge session can end-at-sleep with restore instead, at the cost of an interrupted charge after every lid-close.

---

*End of design. Next step if approved: build per §10 (C1 first), under a separate build approval. Nothing in this document authorizes code, an install, or a battery test.*
